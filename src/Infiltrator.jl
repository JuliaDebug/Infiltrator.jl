module Infiltrator

let README = normpath(dirname(@__DIR__), "README.md")
    include_dependency(README)
    @doc read(README, String) Infiltrator
end

using REPL, UUIDs, InteractiveUtils
using REPL.LineEdit
using Markdown

export @infiltrate, @infiltry, @exfiltrate, @withstore, safehouse, exfiltrated, infiltrate

const REPL_HOOKED = Ref{Bool}(false)
const INFILTRATION_LOCK = Ref{ReentrantLock}()

function __init__()
    ccall(:jl_generating_output, Cint, ()) == 0 && clear_store!(store)
    INFILTRATION_LOCK[] = ReentrantLock()
    if isdefined(Base, :active_repl_backend) && !isnothing(Base.active_repl_backend)
        pushfirst!(Base.active_repl_backend.ast_transforms, ast_transformer())
        REPL_HOOKED[] = true
    else
        atreplinit() do repl
            @async begin
                iter = 0
                # wait for active_repl_backend to exist
                while !isdefined(Base, :active_repl_backend) && iter < 20
                    sleep(0.05)
                    iter += 1
                end
                if isdefined(Base, :active_repl_backend)
                    pushfirst!(Base.active_repl_backend.ast_transforms, ast_transformer())
                    REPL_HOOKED[] = true
                end
            end
        end
    end
    return
end

"""
    @infiltrate
    @infiltrate condition::Bool

`@infiltrate` sets an infiltration point (or breakpoint).

When the infiltration point is hit, it will drop you into an interactive REPL session that
lets you inspect local variables and the call stack as well as execute arbitrary statements
in the context of the current functions module.

This macro also accepts an optional argument `cond` that must evaluate to a boolean,
and then this macro will serve as a "conditional breakpoint", which starts inspections only
when its condition is `true`. For example:

    @infiltrate false # does not infiltrate
"""
macro infiltrate(cond = true)
    if __module__ === Core.Compiler && !isdefined(Core.Compiler, :Dict)
        # XXX Dict isn't available in Core.Compiler, so make it available now
        Core.eval(Core.Compiler, :(using .Main: Dict))
        Core.eval(Core.Compiler, :(setindex!(x::Dict, args...) = Main.setindex!(x, args...)))
    elseif @static isdefined(Core.Compiler, :EscapeAnalysis) &&
            __module__ === Core.Compiler.EscapeAnalysis && !isdefined(Core.Compiler.EscapeAnalysis, :Dict)
        if !isdefined(Core.Compiler, :Dict)
            Core.eval(Core.Compiler, :(using .Main: Dict))
            Core.eval(Core.Compiler, :(setindex!(x::Dict, args...) = Main.setindex!(x, args...)))
        end
        Core.eval(Core.Compiler.EscapeAnalysis, :(using .Main: Dict))
        Core.eval(Core.Compiler.EscapeAnalysis, :(setindex!(x::Dict, args...) = Main.setindex!(x, args...)))
    end
    return quote
        if $(esc(cond))
            $(start_prompt)($(__module__), Base.@locals, $(String(__source__.file)), $(__source__.line))
        end
    end
end

"""
    infiltrate(mod, locals, file, line)

Function form of `@infiltrate`. Use this to conditionally infiltrate package code without
using e.g. Revise (because this version is valid during precompilation).

This would typically be used as
```julia
if isdefined(Main, :Infiltrator)
  Main.infiltrate(@__MODULE__, Base.@locals, @__FILE__, @__LINE__)
end
```
"""
infiltrate(mod, locals, file, line) = start_prompt(mod, locals, string(file), line)


"""
    @exfiltrate

Assigns all local variables into the global storage.
"""
macro exfiltrate()
    return quote
        for (k, v) in Base.@locals
            try
                Core.eval(get_store(getfield($(@__MODULE__), :store)), Expr(:(=), k, QuoteNode(v)))
            catch err
                println(stderr, "Assignment to store variable failed.")
                Base.display_error(stderr, err, catch_backtrace())
            end
        end
    end
end

"""
    @infiltry expr

Wraps expression in a try block, infiltrate if an exception is raised.
Equivalent to:

```julia
try
    expr
catch
    @infiltrate
    rethrow()
end
```

If `expr` is of the form `x = f(...)`, we take `x` out of the scope

```julia
x = try
    f(...)
catch
    @infiltrate
    rethrow()
end
```

"""
macro infiltry(expr)
    infiltrator_catch_and_rethrow = quote
        $(Infiltrator.start_prompt)($(__module__), Base.@locals, $(String(__source__.file)), $(__source__.line), ex, catch_backtrace())
        rethrow()
    end

    return if Meta.isexpr(expr, :(=))
        var = first(expr.args)
        func = last(expr.args)
        quote
            $(esc(var)) = try
                $(esc(func))
            catch ex
                $(infiltrator_catch_and_rethrow)
            end
        end
    else
        quote
            try
                $(esc(expr))
            catch ex
                $(infiltrator_catch_and_rethrow)
            end
        end
    end
end

const prompt_color = if Sys.iswindows()
    "\e[33m"
else
    "\e[38;5;166m"
end

# these are used for easier testing
const TEST_TERMINAL_REF = Ref{Any}(nothing)
const TEST_REPL_REF = Ref{Any}(nothing)
const TEST_NOSTACK = Ref{Any}(false)

"""
    toggle_async_check(enabled)

Enable or disable the check for safe REPL mode switching. May result in a non-functional REPL.
"""
toggle_async_check(enabled) = CHECK_TASK[] = enabled
const CHECK_TASK = Ref{Bool}(true)

mutable struct Session
    store::Module
    exiting::Bool
    disabled::Set
    conditions::Dict
    function Session(exiting, disabled, conditions)
        session = new()
        session.exiting = exiting
        session.disabled = disabled
        session.conditions = conditions
        return session
    end
end
function Base.show(io::IO, s::Session)
    n = length(get_store_names(s))
    print(io, "Safehouse ($(n) variable$(n == 1 ? "" : "s"))")
    return
end
function Base.show(io::IO, ::MIME"text/plain", s::Session)
    names = get_store_names(s)
    n = length(names)
    println(io, "Safehouse with $(n) stored variable$(n == 1 ? "" : "s"):")
    for (i, (var, val)) in enumerate(names)
        if i > 6
            println(io, "...")
            break
        end
        one_line_show(io, var, val)
    end
    return
end
function Base.getproperty(sp::Session, s::Symbol)
    m = get_store(sp)
    isdefined(m, s) || throw(UndefVarError(s))
    return getproperty(m, s)
end
Base.propertynames(s::Session) = keys(get_store_names(s))

const store_docstring = """
    safehouse
    exfiltrated
    Infiltrator.store

Global storage for storing values while `@infiltrate`ing or `@exfiltrate`ing.

Also see [`clear_store!`](@ref), [`set_store!`](@ref), and [`@withstore`](@ref) for
safehouse-related functionality.
"""
@doc store_docstring
const store = Session(false, Set(), Dict())
@doc store_docstring
const safehouse = store
@doc store_docstring
const exfiltrated = store

"""
    @withstore ex

Evaluates the expression `ex` in the context of the global store.

Mainly intended for interactive use, as changes to the store's state will not
propagate into the returned expression.
"""
macro withstore(ex)
    return withstore(ex)
end

function withstore(ex)
    ns = get_store_names(store)
    return Expr(
        :let,
        Expr(:block, map(x -> Expr(:(=), x...), [(k, maybe_quote(v)) for (k, v) in ns])...),
        Expr(:block, ex)
    )
end

"""
    clear_disabled!(s = safehouse)

Clear all disabled infiltration points.
"""
function clear_disabled!(s = store)
    empty!(getfield(s, :disabled))
    return nothing
end

"""
    clear_conditions!(s = safehouse)

Clear all conditional infiltration points.
"""
function clear_conditions!(s = store)
    empty!(getfield(s, :conditions))
    return nothing
end

"""
    end_session!(s = safehouse)

End this infiltration session (reverts the effect of `@exit` in the `debug>` REPL).
"""
function end_session!(s::Session = store)
    setfield!(s, :exiting, false)
    return nothing
end

function get_store(s::Session = store)
    isdefined(s, :store) && return getfield(s, :store)
    ccall(:jl_generating_output, Cint, ()) == 1 && error("Functionality provided by this package should not be used during precompilation or other compilation modes")
    error("The provided session does not have a module")
end

"""
    clear_store!(s = safehouse)

Reset the store used for global symbols.
"""
clear_store!(s::Session = store) = set_store!(s, Module())

"""
    set_store!(s = safehouse, m::Module)

Set the module backing the store `s`.
"""
set_store!(m::Module) = set_store!(store, m)
function set_store!(s::Session, m::Module)
    setfield!(s, :store, m)
    return nothing
end

function new_terminal_and_repl()
    term_env = get(ENV, "TERM", @static Sys.iswindows() ? "" : "dumb")
    term = REPL.Terminals.TTYTerminal(term_env, stdin, stdout, stderr)
    term.term_type == "dumb" && return (term, REPL.BasicREPL(term))
    repl = REPL.LineEditREPL(term, get(stdout, :color, false), true)
    repl.history_file = true
    return (term, repl)
end

"""
Return whether we should emit a warning being possibly in an `@async` context.

This may yield false negatives, but no false positives.
"""
function is_in_async_context()
    !isdefined(Base, :active_repl_backend) && return false
    backend = Base.active_repl_backend
    backend === nothing && return false
    return !backend.in_eval
end

function start_prompt(
        mod, locals, file, fileline, ex = nothing, bt = nothing;
        terminal = TEST_TERMINAL_REF[],
        repl = TEST_REPL_REF[],
        nostack = TEST_NOSTACK[]
    )
    lock(INFILTRATION_LOCK[])
    try
        getfield(store, :exiting) && return
        spot = (file, fileline)
        spot in getfield(store, :disabled) && return
        cs = getfield(store, :conditions)
        f = get(cs, spot, nothing)
        # Use invokelatest because we may have added f before returning to the REPL.
        isnothing(f) || Base.invokelatest(f, locals) || return

        if terminal === nothing || repl === nothing
            terminal, repl = new_terminal_and_repl()
        end

        io = Base.pipe_writer(terminal)

        trace = stacktrace()
        start = something(findlast(x -> x.func === Symbol("start_prompt"), trace), 0) + 2
        last = something(
            findfirst(x -> x.func === StackTraces.top_level_scope_sym, trace),
            length(trace)
        )
        trace = trace[start:last]
        bt = bt === nothing ? nothing : crop_backtrace(bt)

        if CHECK_TASK[] && is_in_async_context()
            b = IOBuffer()
            c = IOContext(b, :color => get(io, :color, false))
            printstyled(c, "ERROR: "; color = Base.error_color())
            if length(trace) > 0
                sf = trace[1]
                print(c, "Disabling the infiltration point in ")
                printstyled(c, sprint(Base.StackTraces.show_spec_linfo, sf); color = :cyan)
                print(c, " at ")
                if sf.file !== Symbol("")
                    print(c, basename(string(sf.file)), ":")
                    if sf.line >= 0
                        print(c, sf.line)
                    else
                        print(c, "?")
                    end
                else
                    print(c, "unknown")
                end
                println(c, ".")
            else
                println(c, "Disabling this infiltration point.")
            end
            printstyled(
                c, """
                Infiltrating fully asynchronous code is currently not possible. You may be trying
                to infiltrate an """; color = :light_black
            )
            printstyled(c, "@async "; color = :cyan)
            printstyled(
                c, """
                task or are using inline evaluation in VS Code or Juno.

                Infiltration points can be re-enabled with """; color = :light_black
            )
            printstyled(c, "Infiltrator.clear_disabled!() "; color = :cyan)
            printstyled(
                c, """
                and
                this check is toggled with """, color = :light_black
            )
            printstyled(c, "Infiltrator.toggle_async_check(false)", color = :cyan)
            printstyled(c, ".\n", color = :light_black)

            print(io, String(take!(b)))
            push!(getfield(store, :disabled), ((file, fileline)))
            return
        end

        if ex !== nothing
            printstyled(io, "EXCEPTION"; color = :red, bold = true)
            print(io, " while infiltrating ")
        else
            print(io, "Infiltrating ")
        end

        if Threads.nthreads() > 1
            print(io, "(on thread $(Threads.threadid())) ")
        end
        if length(trace) > 0
            if nostack
                print(io, "<unknown>")
            else
                print_verbose_stackframe(io, trace[1])
            end
        else
            print(io, "top-level frame")
        end
        println(io)
        println(io)
        debugprompt(mod, locals, trace, terminal, repl, ex, bt; nostack = nostack, file = file, fileline = fileline)
        println(io)
    finally
        unlock(INFILTRATION_LOCK[])
    end
    return
end

const HELP_TEXT = md"""
Code entered here is evaluated in the current function's scope. Changes to local variables are not
possible; global variables can only be changed with `eval`/`@eval`.

All assignments will end up in the `safehouse`.

The following commands are special cased:
  - `?`: Print this help text.
  - `@trace`: Print the current stack trace with reduced type information. For full types, see `@trace_all`.
  - `@trace_all`: Print the current stack trace with full type information.
  - `@locals`: Print local variables. `@locals x y` only prints `x` and `y`.
  - `@exception`: Print the exception that triggered the current `@infiltry` session, if any.
  - `@exfiltrate`: Save all local variables into the store. `@exfiltrate x y` saves `x` and `y`;
    this variant can also exfiltrate variables defined in the `infil>` REPL.
  - `@toggle`: Toggle infiltrating at this `@infiltrate` spot (clear all with `Infiltrator.clear_disabled!()`).
  - `@cond expr`: Infiltrate at this `@infiltrate` spot only if `expr` evaluates to true (clear all with `Infiltrator.clear_conditions!()`). Only local variables can be accessed here.
  - `@continue`: Continue to the next infiltration point or exit (shortcut: Ctrl-D).
  - `@doc symbol`: Get help for `symbol` (same as in the normal Julia REPL).
  - `@exit`: Stop infiltrating for the remainder of this session and exit.
"""

function show_help(io)
    show(io, MIME("text/plain"), HELP_TEXT)
    println(io, '\n')
    return
end

function strlimit(str, limit = 30)
    strwidth = 0
    for (i, c) in enumerate(str)
        strwidth += textwidth(c)
        strwidth >= limit && return string(first(str, i - 1), "…")
    end
    return str
end

function show_locals(io, locals, selected::AbstractSet = Set())
    if isempty(locals)
        println(io, "No local variables in this scope.\n")
        return
    end
    for (var, val) in locals
        if isempty(selected) || var in selected
            one_line_show(io, var, val)
        end
    end
    println(io)
    return
end

get_pmacro_args(mname, line) =
    Set(Symbol.(filter!(x -> x != mname, strip.(filter!(!isempty, split(line, ' '))))))

function show_locals(io, locals, sline::AbstractString)
    selected = get_pmacro_args("@locals", sline)
    show_locals(io, locals, selected)
    return
end

function exfiltrate_locals(io, evalmod, locals, sline::AbstractString)
    selected = get_pmacro_args("@exfiltrate", sline)
    locals_only = isempty(selected)

    iter = locals_only ? keys(locals) : selected
    n = length(iter)

    println(io, "Exfiltrating $(n) local variable$(n == 1 ? "" : "s") into the safehouse.\n")

    for k in iter
        if locals_only
            v = locals[k]
        else
            string(k) in ("@__MODULE__", "#@__MODULE__", "anonymous") && continue

            if !isdefined(evalmod, k)
                printstyled(io, "Warning: "; bold = true, color = :red)
                println(io, "Binding `$k` not defined in this context. Refusing to exfiltrate.")
                continue
            end

            v = getfield(evalmod, k)
        end
        try
            Core.eval(get_store(store), Expr(:(=), k, QuoteNode(v)))
        catch err
            println(io, "Assignment to store variable failed.")
            Base.display_error(io, err, catch_backtrace())
        end
    end
    return
end

function one_line_show(io::IO, var, val)
    width = max(displaysize(io)[2], 40)
    prefix = string("- ", strlimit(string(var), width ÷ 3), "::", strlimit(string(typeof(val)), width ÷ 3), " = ")
    println(io, prefix, strlimit(repr(val), max(width - textwidth(prefix), 10)))
    return
end

function is_complete(s)
    ast = Base.parse_input_line(String(take!(copy(LineEdit.buffer(s)))), depwarn = false)
    return !(isa(ast, Expr) && ast.head === :incomplete)
end

function init_transient_eval_module(mod, locals)
    modns = get_module_names(mod)

    newmod = Module()
    # assign source code module name
    modname = nameof(mod)
    if modname != :anonymous
        Core.eval(newmod, Expr(:(=), modname, mod))
    end
    # spoof @__MODULE__
    Core.eval(
        newmod, Expr(
            :macro,
            Expr(:call, Symbol("__MODULE__")),
            Expr(:block, mod)
        )
    )
    haskey(modns, Symbol("@__MODULE__")) && delete!(modns, Symbol("@__MODULE__"))
    # insert local variables into current scope
    Core.eval(newmod, Expr(:block, map(x -> Expr(:(=), x...), [(k, maybe_quote(v)) for (k, v) in locals])...))
    # insert variables in safehouse
    Core.eval(newmod, Expr(:block, map(x -> Expr(:(=), x...), [(k, maybe_quote(v)) for (k, v) in get_store_names() if !isdefined(newmod, k)])...))
    # insert all bindings from the source module that aren't already defined in the eval module
    Core.eval(newmod, Expr(:block, map(x -> Expr(:(=), x...), [(k, maybe_quote(v)) for (k, v) in modns if !isdefined(newmod, k)])...))

    return newmod
end

const PROMPT = Ref{Any}()

# Copy of `find_hist_file` for the main REPL.
find_infil_hist_file() = get(ENV, "INFILTRATOR_HISTORY", !isempty(DEPOT_PATH) ? joinpath(DEPOT_PATH[1], "logs", "infil_history.jl") : error("DEPOT_PATH is empty and ENV[\"INFILTRATOR_HISTORY\"] is not set."))

"""
Load the history from the history file found by `find_infil_hist_file()`, i.e. under `ENV["INFILTRATOR_HISTORY"]` or next to the main REPL history (typically `.julia/logs/infil_history.jl`).
Most of the code comes from the REPL stdlib (inlined in `setup_interface`).
"""
function load_history!(hp::REPL.REPLHistoryProvider, repl, cp::REPL.CompletionProvider)
    if repl.history_file
        try
            hist_path = find_infil_hist_file()
            mkpath(dirname(hist_path))
            hp.file_path = hist_path
            REPL.hist_open_file(hp)
            finalizer(cp) do cp
                close(hp.history_file)
            end
            REPL.hist_from_file(hp, hist_path)
        catch
            # use REPL.hascolor to avoid using the local variable with the same name
            print_response(repl, Pair{Any, Bool}(current_exceptions(), true), true, REPL.hascolor(repl))
            println(REPL.outstream(repl))
            @info "Disabling history file for this session"
            repl.history_file = false
        end
    end
    return
end

function debugprompt(mod, locals, trace, terminal, repl, ex, bt; nostack = false, file, fileline)
    io = Base.pipe_writer(terminal)

    evalmod = init_transient_eval_module(mod, locals)

    try
        if isassigned(PROMPT)
            panel = PROMPT[]
            panel.complete = InfiltratorCompletionProvider(mod, evalmod)
        else
            cp = InfiltratorCompletionProvider(mod, evalmod)
            panel = PROMPT[] = REPL.LineEdit.Prompt(
                "infil> ";
                prompt_prefix = prompt_color,
                prompt_suffix = Base.text_colors[:normal],
                complete = cp,
                on_enter = is_complete
            )
            panel.hist = REPL.REPLHistoryProvider(Dict{Symbol, Any}(:Infiltrator => panel))
            load_history!(panel.hist, repl, cp)
            REPL.history_reset_state(panel.hist)
        end
        search_prompt, skeymap = LineEdit.setup_search_keymap(panel.hist)
        search_prompt.complete = REPL.LatexCompletions()

        panel.on_done = (s, buf, ok) -> begin
            if !ok
                LineEdit.transition(s, :abort)
                REPL.LineEdit.reset_state(s)
                return false
            end

            line = String(take!(buf))

            if isempty(line)
                println(io)
                LineEdit.reset_state(s)
                return true
            end

            sline = strip(line)
            if sline == "?"
                show_help(io)
                LineEdit.reset_state(s)
                return true
            elseif sline in ("@trace", "@trace_all")
                types_limited = VERSION >= v"1.10" && sline == "@trace"
                print_verbose_stacktrace(io, trace, nostack ? 0 : 100, types_limited)
                LineEdit.reset_state(s)
                return true
            elseif startswith(sline, "@locals")
                show_locals(io, locals, sline)
                LineEdit.reset_state(s)
                return true
            elseif startswith(sline, "@exfiltrate")
                exfiltrate_locals(io, evalmod, locals, sline)
                LineEdit.reset_state(s)
                return true
            elseif sline == "@exception"
                if ex !== nothing && bt !== nothing
                    Base.display_error(io, ex, nostack ? bt[1:1] : bt)
                else
                    println(io, "No exception available")
                end
                println(io)
                LineEdit.reset_state(s)
                return true
            elseif sline == "@toggle"
                spot = (file, fileline)
                ds = getfield(store, :disabled)
                cs = getfield(store, :conditions)
                if spot in ds
                    delete!(ds, spot)
                    if haskey(cs, spot)
                        println(io, "Conditionally enabled infiltration at this infiltration point.\n")
                    else
                        println(io, "Enabled infiltration at this infiltration point.\n")
                    end
                else
                    push!(ds, spot)
                    println(io, "Disabled infiltration at this infiltration point.\n")
                end
                LineEdit.reset_state(s)
                return true
            elseif startswith(sline, "@cond")
                spot = (file, fileline)
                ds = getfield(store, :disabled)
                cs = getfield(store, :conditions)
                rest = lstrip(sline[6:end])

                try
                    expr = Base.parse_input_line(rest)
                    @assert expr.head == :toplevel
                    # Unwrap the :toplevel node and replace with a :block
                    expr = Expr(:block, expr.args...)
                    # Wrap the expr in a closure.
                    # We need to gensym a new name to avoid this error:
                    #    cannot declare #1#2 constant; it already has a value
                    # Pass a locals dict into the function so we access the locals at the
                    # next infiltration point rather than capturing the locals here.
                    fname = gensym(:cond)
                    locals_dict = gensym(:locals)
                    expr = quote
                        function $(fname)($locals_dict)
                            $(
                                (
                                    Expr(:(=), x, Expr(:ref, locals_dict, Expr(:call, Symbol, string(x))))
                                        for x in keys(locals)
                                )...
                            )
                            $(expr)
                        end
                        $fname
                    end
                    # Eval and save in the dict.
                    result = Core.eval(evalmod, expr)
                    cs[spot] = result
                    # Remove the spot from the disabled set.
                    delete!(ds, spot)
                    println(io, "Conditionally enabled infiltration at this infiltration point.\n")
                    LineEdit.reset_state(s)
                    return true
                catch err
                    # If we get an error, just punt to the eval code to handle the error.
                    line = rest
                end
            elseif sline == "@exit"
                setfield!(store, :exiting, true)
                if !REPL_HOOKED[]
                    printstyled(
                        io,
                        ">> Restore infiltration capabilities with `Infiltrator.end_session!()` or you will not be able to enter a new session!\n";
                        color = :red,
                        bold = true
                    )
                end
                LineEdit.transition(s, :abort)
                LineEdit.reset_state(s)
                return true
            elseif sline == "@continue"
                LineEdit.transition(s, :abort)
                LineEdit.reset_state(s)
                return true
            end
            ok = true
            result = nothing

            expr = try
                Base.parse_input_line(line)
            catch err
                if get(io, :color, false)
                    println(io, "Parsing error.")
                else
                    printstyled(io, "Parsing error.", color = Base.error_color())
                end

                LineEdit.reset_state(s)
                return false
            end

            expr = REPL.softscope(expr)

            try
                result = interpret(expr, evalmod)
            catch err
                ok = false
                result = @static if VERSION >= v"1.7"
                    Base.current_exceptions(current_task(); backtrace = true)
                else
                    Base.catch_stack()
                end
                if nostack
                    result = map(result) do (err, bt)
                        @static if VERSION >= v"1.8-"
                            return (exception = err, backtrace = crop_backtrace(bt))
                        else
                            return err, []
                        end
                    end
                else
                    result = map(result) do (err, bt)
                        @static if VERSION >= v"1.8-"
                            return (exception = err, backtrace = crop_backtrace(bt))
                        else
                            return err, crop_backtrace(bt)
                        end
                    end
                end
                if isdefined(Base, :ExceptionStack)
                    result = Base.ExceptionStack(result)
                end
            end
            if !ok || !REPL.ends_with_semicolon(line)
                print_response(repl, (result, !ok), true, true)
            end
            println(io)
            LineEdit.reset_state(s)

            return true
        end

        prefix_prompt, prefix_keymap = LineEdit.setup_prefix_keymap(panel.hist, panel)

        panel.keymap_dict = LineEdit.keymap(Dict{Any, Any}[skeymap, prefix_keymap, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults])

        REPL.run_interface(terminal, REPL.LineEdit.ModalInterface([panel, prefix_prompt, search_prompt]))
    catch e
        e isa InterruptException || rethrow(e)
    end
    return
end

get_store_names(s = store) = get_module_names(get_store(s), m -> names(m, all = true))

function get_module_names(m::Module, get_names = all_names)
    ns = get_names(m)
    out = Dict()
    for n in ns
        if isdefined(m, n) && !Base.isdeprecated(m, n) && n !== :eval && n !== :include && n !== :anonymous
            out[n] = getfield(m, n)
        end
    end
    return out
end

function print_verbose_stacktrace(io, st, limit = 100, types_limited = false)
    if isempty(st)
        println(io, "Toplevel scope\n")
        return
    end

    len = length(st)
    for (i, sf) in enumerate(st)
        if i > limit
            limit > 0 && println(io, "\n<< omitted $(len - limit) stack frames >>")
            break
        end

        print_verbose_stackframe(io, sf, i, len, types_limited)
    end
    println(io)
    return
end

function print_verbose_stackframe(io, sf::StackTraces.StackFrame, i, len, types_limited)
    num_padding = ceil(Int, log10(len))
    padding = num_padding + 3
    print(io, "[", lpad(i, num_padding), "] ")
    print_verbose_stackframe(io, sf, padding, types_limited)
    return
end

function print_verbose_stackframe(io, sf::StackTraces.StackFrame, padding = 2, types_limited = false)
    # Base.type_limited_string_from_context checks if a Ref{Bool} is passed
    trigger_types_limited = types_limited ? Ref(types_limited) : nothing

    buf = IOContext(IOBuffer(), io)   # We wrap IOBuffer in IOContext(, io) to inherit colors
    Base.StackTraces.show_spec_linfo(IOContext(buf, :backtrace => true, :stacktrace_types_limited => trigger_types_limited), sf)
    st_str = String(take!(buf.io))
    @static if VERSION >= v"1.10"
        st_str = Base.type_limited_string_from_context(io, st_str)
    end
    write(io, st_str)
    println(io)

    sf.func == StackTraces.top_level_scope_sym && return

    print(io, ' '^padding)
    printstyled(io, "at ", color = :light_black)

    file, line = string(sf.file), sf.line
    file = fixup_stdlib_path(file)
    file = something(Base.find_source_file(file), file)
    printstyled(io, normpath(file), ":", line, '\n', color = :light_black)
    return
end

# with https://github.com/JuliaLang/julia/pull/57773, print_response will
# evaluate `display` on the REPL backend. We are however running all of Infiltrator
# on the REPL backend already, so that would cause a deadlock. Luckily we can pass
# nothing instead of the actual REPL backend to work around that.
@static if hasmethod(REPL.print_response, (IO, Any, Nothing, Bool, Bool, Union{AbstractDisplay, Nothing})) &&
        (
        isdefined(REPL, :eval_with_backend) &&
            hasmethod(REPL.eval_with_backend, (Any, Nothing)) ||
            (
            isdefined(REPL, :call_on_backend) &&
                hasmethod(REPL.call_on_backend, (Any, Nothing))
        )
    )

    function print_response(repl, response, show_value, have_color)
        repl.waserror = response[2]
        REPL.with_repl_linfo(repl) do io
            io = IOContext(io, :module => Base.active_module(repl)::Module)

            REPL.print_response(io, response, nothing, show_value, have_color, REPL.specialdisplay(repl))
        end

        return nothing
    end

else

    print_response(args...) = REPL.print_response(args...)

end

# https://github.com/JuliaLang/julia/blob/1fb28ad8768cfdc077e968df7adf5716ae8eb9ab/base/methodshow.jl#L134-L148
function fixup_stdlib_path(path::String)
    BUILD_STDLIB_PATH = isdefined(Sys, :BUILD_STDLIB_PATH) ?
        Sys.BUILD_STDLIB_PATH :
        dirname(abspath(joinpath(String((@which uuid1()).file), "..", "..", "..")))

    STDLIB = Sys.STDLIB::String
    if BUILD_STDLIB_PATH != STDLIB
        # BUILD_STDLIB_PATH gets defined in sysinfo.jl
        npath = normpath(path)
        npath′ = replace(npath, normpath(BUILD_STDLIB_PATH) => normpath(STDLIB))
        return npath == npath′ ? path : npath′
    end
    return path
end

function all_names(m)
    symbols = Set(Symbol[])
    seen = Set(Module[])

    pred = (x, v) -> isdefined(m, x) && !Base.isdeprecated(m, x) && getfield(m, x) === v

    # anonymous modules may not be rooted in any other modules
    all_names(m, pred, symbols, seen)
    for mod in values(Base.loaded_modules)
        all_names(mod, pred, symbols, seen)
    end

    return symbols
end
function all_names(m, pred, symbols = Set(Symbol[]), seen = Set(Module[]))
    push!(seen, m)
    ns = names(m; all = true, imported = true)

    for n in ns
        isdefined(m, n) || continue
        Base.isdeprecated(m, n) && continue
        val = getfield(m, n)
        val isa Core.IntrinsicFunction && continue
        if val isa Module && !(val in seen)
            all_names(val, pred, symbols, seen)
        end
        if pred(n, val)
            push!(symbols, n)
        end
    end
    return symbols
end

function maybe_quote(@nospecialize x)
    is_ir_construct(x) && return QuoteNode(x)
    isa(x, Expr) && return QuoteNode(x)
    isa(x, Symbol) && return QuoteNode(x)
    isa(x, GlobalRef) && return QuoteNode(x)
    return x
end

let ir_constructs = collect(
        DataType,
        filter(map(n -> getfield(Core.IR, n), names(Core.IR))) do x
            @nospecialize x
            return isa(x, DataType)
        end
    )
    @eval is_ir_construct(@nospecialize x) = typeof(x) in $ir_constructs
end

function interpret(expr, evalmod)
    out = Core.eval(evalmod, :(ans = $(expr)))
    return out
end

# runic: off
function ast_transformer()
    return function (@nospecialize(ex),)
        if ex isa Expr
            return Expr(:try, ex, false, false, :($(@__MODULE__).end_session!()))
        end
        return ex
    end
end
# runic: on

# backtraces

function find_first_topelevel_scope(bt::Vector{<:Union{Base.InterpreterIP, Ptr{Cvoid}}})
    for (i, ip) in enumerate(bt)
        st = Base.StackTraces.lookup(ip)
        ind = findfirst(st) do frame
            linfo = frame.linfo
            if linfo isa Core.CodeInfo && VERSION < v"1.12-"
                @static if hasfield(Core.CodeInfo, :debuginfo)
                    linfo.debuginfo.def === StackTraces.top_level_scope_sym && return true
                else
                    linetable = linfo.linetable
                    if isa(linetable, Vector) && length(linetable) ≥ 1
                        lin = first(linetable)
                        if isa(lin, Core.LineInfoNode) && lin.method === StackTraces.top_level_scope_sym
                            return true
                        end
                    end
                end
            else
                return frame.func === StackTraces.top_level_scope_sym
            end
        end
        ind === nothing || return i
    end
    return
end

function crop_backtrace(bt)
    i = find_first_topelevel_scope(bt)
    return bt[1:(i === nothing ? end : i)]
end

# completions

mutable struct InfiltratorCompletionProvider <: REPL.CompletionProvider
    mod::Module
    localmod::Module
end

function LineEdit.complete_line(c::InfiltratorCompletionProvider, s; hint::Bool = false)
    partial = REPL.beforecursor(s.input_buffer)
    full = LineEdit.input_string(s)

    ret, range, should_complete = completions(c, full, partial)
    return ret, partial[range], should_complete
end

function completions(c::InfiltratorCompletionProvider, full, partial)
    # repl backend completions
    comps, range, should_complete = REPL.REPLCompletions.completions(full, lastindex(partial), c.mod)
    ret = map(REPL.REPLCompletions.completion_text, comps)

    # completions for local variables
    comps, range, should_complete = REPL.REPLCompletions.completions(full, lastindex(partial), c.localmod)
    prepend!(ret, map(REPL.REPLCompletions.completion_text, comps))

    # completions for safehouse variables
    comps, range, should_complete = REPL.REPLCompletions.completions(full, lastindex(partial), get_store(store))
    prepend!(ret, map(REPL.REPLCompletions.completion_text, comps))

    # Infiltrator commands completions
    commands = ["?", "@trace", "@trace_all", "@locals", "@toggle", "@exit", "@continue", "@exfiltrate", "@exception"]
    prepend!(ret, filter!(c -> startswith(c, partial), commands))

    return unique!(ret), range, should_complete
end

end # module
