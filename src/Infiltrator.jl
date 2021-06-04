module Infiltrator

using REPL
using REPL.LineEdit

export @infiltrate

function __init__()
  SCRATCH_PAD[] = Module()
  if VERSION >= v"1.5.0-DEV.282"
    if isdefined(Base, :active_repl_backend)
        pushfirst!(Base.active_repl_backend.ast_transforms, exit_transform)
    else
      atreplinit() do repl
        pushfirst!(repl.ast_transforms, exit_transform)
      end
    end
  end
end

"""
    @infiltrate cond = true

`@infiltrate` sets an infiltration point (or breakpoint).

When the infiltration point is hit, it will drop you into an interactive REPL session that
lets you inspect local variables and the call stack as well as execute aribtrary statements
in the context of the current functions module.

This macro also accepts an optional argument `cond` that must evaluate to a boolean,
and then this macro will serve as a "conditinal breakpoint", which starts inspections only
when its condition is `true`.

### Usage:
`?` in the `debug>` prompt lists all options.

```julia
julia> function f(x)
         out = []
         for i in x
           push!(out, 2i)
           @infiltrate
         end
         out
       end
f (generic function with 1 method)

julia> f([1,2,3])
Infiltrating f(x::Vector{Int64}) at REPL[2]:5:

debug> @locals
- out::Vector{Any} = Any[2]
- i::Int64 = 1
- x::Vector{Int64} = [1, 2, 3]

debug> 0//0
ERROR: ArgumentError: invalid rational: zero(Int64)//zero(Int64)
Stacktrace:
 [1] __throw_rational_argerror_zero(T::Type)
   @ Base ./rational.jl:31
 [2] Rational{Int64}(num::Int64, den::Int64)
   @ Base ./rational.jl:33
 [3] Rational
   @ ./rational.jl:38 [inlined]
 [4] //(n::Int64, d::Int64)
   @ Base ./rational.jl:61
 [5] top-level scope
   @ none:1

debug> intermediate = copy(out)
1-element Vector{Any}:
 2

debug> @disable
Disabled infiltration at this infiltration point.

debug> @disable
Enabled infiltration at this infiltration point.

debug> @continue

Infiltrating f(x::Vector{Int64}) at REPL[2]:5:

debug> @locals
- out::Vector{Any} = Any[2, 4]
- i::Int64 = 2
- x::Vector{Int64} = [1, 2, 3]

debug> @exit

3-element Vector{Any}:
 2
 4
 6

julia> Infiltrator.get_scratch_pad().intermediate
1-element Vector{Any}:
 2
```
"""
macro infiltrate(cond = true)
  quote
    if $(esc(cond))
      $(start_prompt)(@__MODULE__, Base.@locals, $(String(__source__.file)), $(__source__.line))
    end
  end
end

const prompt_color = if Sys.iswindows()
  "\e[33m"
else
  "\e[38;5;166m"
end

const TEST_TERMINAL_REF = Ref{Any}(nothing)
const TEST_REPL_REF = Ref{Any}(nothing)
const TEST_NOSTACK = Ref{Any}(false)

const EXITING = Ref{Bool}(false)
const DISABLED = Set()

const SCRATCH_PAD = Ref{Module}()

"""
    clear_disabled()

Clear disabled infiltration point.
"""
function clear_disabled()
  empty!(DISABLED)
  return nothing
end

"""
    clear_exiting()

Reset "exiting" status.
"""
function clear_exiting()
  EXITING[] = false
  return nothing
end

"""
    clear_scratch_pad()

Reset the scratch pad module used for global symbols.
"""
function clear_scratch_pad()
  SCRATCH_PAD[] = Module()
  nothing
end

"""
    get_scratch_pad()

Scratch pad module containing global symbols created while infiltrating.
"""
get_scratch_pad() = isassigned(SCRATCH_PAD) ? SCRATCH_PAD[] : Module()

function start_prompt(mod, locals, file, fileline;
                        terminal = TEST_TERMINAL_REF[],
                        repl = TEST_REPL_REF[],
                        nostack = TEST_NOSTACK[]
                      )
  EXITING[] && return
  (file, fileline) in DISABLED && return

  if terminal === nothing || repl === nothing
    if isdefined(Base, :active_repl) && isdefined(Base.active_repl, :t)
      repl = Base.active_repl
      terminal = Base.active_repl.t
    else
      println("Infiltrator.jl needs a proper Julia REPL.")
      return
    end
  end
  io = Base.pipe_writer(terminal)

  trace = stacktrace()
  start = something(findlast(x -> x.func === Symbol("start_prompt"), trace), 0) + 2
  last = something(findlast(x -> x.func === Symbol("eval"), trace),
                   length(trace)) - 2
  trace = trace[start:last]
  current = trace[1]
  println(io, "Infiltrating $current:")
  println(io)
  debugprompt(mod, locals, trace, terminal, repl, nostack, file=file, fileline=fileline)
  println(io)
end

function show_help(io)
  println(io, """
    Code entered is evaluated in the current functions module. Note that you cannot change local
    variables, but can assign to globals in a permanent scratch pad module.

    The following commands are special cased:
      - `?`: Print this help text.
      - `@trace`: Print the current stack trace.
      - `@locals`: Print local variables.
      - `@disable`: Toggle infiltrating at this `@infiltrate` spot (clear all with `Infiltrator.clear_disabled()`).
      - `@continue`: Continue to the next infiltration point or exit (shortcut: Ctrl-D).
      - `@exit`: Stop infiltrating for the remainder of this session and exit (on Julia versions prior to
        1.5 this needs to be manually cleared with `Infiltrator.clear_exiting()`).
  """)
end

function show_trace(io, trace)
  for (i, frame) in enumerate(trace)
    println(io, "[", i, "] ", frame)
  end
  println(io)
end

function strlimit(str, limit = 30)
  strwidth = 0
  for (i, c) in enumerate(str)
    strwidth += textwidth(c)
    strwidth >= limit && return string(first(str, i - 1), "…")
  end
  return str
end

function show_locals(io, locals)
  width = max(displaysize(io)[2], 40)
  for (var, val) in locals
    prefix = string("- ", strlimit(string(var), width ÷ 3), "::", strlimit(string(typeof(val)), width ÷ 3), " = ")
    println(io, prefix, strlimit(repr(val), max(width - textwidth(prefix), 10)))
  end
  println(io)
end

function is_complete(s)
  ast = Base.parse_input_line(String(take!(copy(LineEdit.buffer(s)))), depwarn=false)
  return !(isa(ast, Expr) && ast.head === :incomplete)
end

const PROMPT = Ref{Any}()

function debugprompt(mod, locals, trace, terminal, repl, nostack = false; file, fileline)
  io = Base.pipe_writer(terminal)

  try
    if isassigned(PROMPT)
      panel = PROMPT[]
      panel.complete = InfiltratorCompletionProvider(mod, locals)
    else
      panel = PROMPT[] = REPL.LineEdit.Prompt("debug> ";
                prompt_prefix = prompt_color,
                prompt_suffix = Base.text_colors[:normal],
                complete = InfiltratorCompletionProvider(mod, locals),
                on_enter = is_complete)
      panel.hist = REPL.REPLHistoryProvider(Dict{Symbol,Any}(:Infiltrator => panel))
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
      elseif sline == "@trace"
        show_trace(io, trace)
        LineEdit.reset_state(s)
        return true
      elseif sline == "@locals"
        show_locals(io, locals)
        LineEdit.reset_state(s)
        return true
      elseif sline == "@disable"
        spot = (file, fileline)
        if spot in DISABLED
          delete!(DISABLED, spot)
          println(io, "Enabled infiltration at this infiltration point.\n")
        else
          push!(DISABLED, spot)
          println(io, "Disabled infiltration at this infiltration point.\n")
        end
        LineEdit.reset_state(s)
        return true
      elseif sline == "@exit"
        EXITING[] = true
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

      @static if VERSION >= v"1.2.0-DEV.253"
        try
          result = interpret(io, expr, mod, locals)
        catch err
          ok = false
          result = Base.catch_stack()
          if nostack
            result = map(r -> Any[first(r), []], result)
          else
            result = map(result) do (err, bt)
              return err, crop_backtrace(bt)
            end
          end
        end
        REPL.print_response(repl, (result, !ok), true, true)
      else
        try
          result = interpret(io, expr, mod, locals)
        catch err
          ok = false
          result = (err, nostack ? Any[] : crop_backtrace(catch_backtrace()))
        end
        REPL.print_response(repl, ok ? result : result[1], ok ? nothing : result[2], true, true)
      end
      println(io)
      LineEdit.reset_state(s)

      return true
    end

    panel.keymap_dict = LineEdit.keymap(Dict{Any,Any}[skeymap, LineEdit.history_keymap, LineEdit.default_keymap, LineEdit.escape_defaults])

    REPL.run_interface(terminal, REPL.LineEdit.ModalInterface([panel, search_prompt]))
  catch e
    e isa InterruptException || rethrow(e)
  end
end

function get_scratch_pad_names()
  global SCRATCH_PAD
  ns = names(SCRATCH_PAD[], all = true)
  out = Dict()
  for n in ns
    if isdefined(SCRATCH_PAD[], n) && n !== :eval
      out[n] = getfield(SCRATCH_PAD[], n)
    end
  end
  out
end

maybe_quote(x) = (isa(x, Expr) || isa(x, Symbol)) ? QuoteNode(x) : x

function interpret(io, expr, mod, locals)
  symbols = merge(locals, get_scratch_pad_names())
  Meta.isexpr(expr, :toplevel) && (expr = expr.args[end])
  res = gensym()
  eval_expr = Expr(:let,
    Expr(:block, map(x->Expr(:(=), x...), [(k, maybe_quote(v)) for (k, v) in symbols])...),
    Expr(:block,
      Expr(:(=), res, expr),
      Expr(:tuple, res, Expr(:tuple, [k for (k, v) in locals]...))
    )
  )
  eval_res, res = Core.eval(mod, eval_expr)

  assignment = nothing
  if Meta.isexpr(expr, :(=))
    if expr.args[1] isa Symbol
      assignment = expr.args[1]
    elseif Meta.isexpr(expr.args[1], :call) && expr.args[1].args[1] isa Symbol
      assignment = expr.args[1].args[1]
    end
  elseif Meta.isexpr(expr, :function)
    assignment = expr.args[1].args[1]
  end
  if assignment !== nothing
    if haskey(locals, assignment)
      str = "Cannot assign a new value to local variable `$(assignment)`."
      if get(io, :color, false)
        println(io, str)
      else
        printstyled(io, str, color = Base.error_color())
      end
    else
      try
        Base.eval(SCRATCH_PAD[], Expr(:(=), assignment, eval_res))
      catch err
        println(io, "Assignment to scratchpad variable failed.")
        Base.display_error(io, err, catch_backtrace())
      end
    end
  end

  eval_res
end

function exit_transform(ex)
  return quote
    out = $(ex)
    $(@__MODULE__).clear_exiting()
    out
  end
end

# backtraces

function find_first_topelevel_scope(bt::Vector{<:Union{Base.InterpreterIP,Ptr{Cvoid}}})
  for (i, ip) in enumerate(bt)
      st = Base.StackTraces.lookup(ip)
      ind = findfirst(st) do frame
          linfo = frame.linfo
          if linfo isa Core.CodeInfo
              linetable = linfo.linetable
              if isa(linetable, Vector) && length(linetable) ≥ 1
                  lin = first(linetable)
                  if isa(lin, Core.LineInfoNode) && lin.method === Symbol("top-level scope")
                      return true
                  end
              end
          else
              return frame.func === Symbol("top-level scope")
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
  locals::Dict{Symbol, Any}
end

function LineEdit.complete_line(c::InfiltratorCompletionProvider, s)
  partial = REPL.beforecursor(s.input_buffer)
  full = LineEdit.input_string(s)

  ret, range, should_complete = completions(c, full, partial)
  return ret, partial[range], should_complete
end

function completions(c::InfiltratorCompletionProvider, full, partial)
  # repl backend completions
  comps, range, should_complete = REPL.REPLCompletions.completions(full, lastindex(partial), c.mod)
  ret = map(REPL.REPLCompletions.completion_text, comps)

  # local completions
  prepend!(ret, filter!(v -> startswith(v, partial), vcat(string.(keys(c.locals)), string.(keys(get_scratch_pad_names())))))

  # Infiltrator commands completions
  commands = ["?", "@trace", "@locals", "@disable", "@exit", "@continue"]
  prepend!(ret, filter!(c -> startswith(c, partial), commands))

  unique!(ret), range, should_complete
end

end # module
