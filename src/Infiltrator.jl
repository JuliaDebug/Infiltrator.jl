module Infiltrator

using REPL
using REPL.LineEdit

export @infiltrate

"""
    @infiltrate ex = true

Sets a "breakpoint" in a local context. Accepts an optional argument that must evaluate to a boolean,
and will drop you into an interactive REPL session that lets you inspect local variables and the call
stack as well as execute aribtrary statements in the context of the current function's module.

Usage:
```
julia> function f(x)
         x *= 2
         y = rand(3)
         @infiltrate
         x += 2
       end
f (generic function with 1 method)

julia> f(3)
Hit `@infiltrate` in f(::Int64) at none:4:

debug> ?
  Code entered is evaluated in the current function's module. Note that you cannot change local
  variables.
  The following commands are special cased:
    - `@trace`: Print the current stack trace.
    - `@locals`: Print local variables.
    - `@stop`: Stop infiltrating at this `@infiltrate` spot.

  Exit this REPL mode with `Ctrl-D`, and clear the effect of `@stop` with `Infiltrator.clear_stop()`.

debug> @trace
[1] f(::Int64) at none:4
[2] top-level scope at none:0

debug> @locals
- y::Array{Float64,1} = [0.187253, 0.145958, 0.183677]
- x::Int64 = 6

debug> x.+y
3-element Array{Float64,1}:
 6.187252565686353
 6.145958004935359
 6.1836766675450034

debug>

8

julia>
```
"""
macro infiltrate(ex = true)
  quote
    if $(esc(ex))
      start_prompt(@__MODULE__, Base.@locals, $(QuoteNode(ex)),
                   $(String(__source__.file)), $(__source__.line))
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

const STOP_SPOTS = Set()
clear_stop() = (empty!(STOP_SPOTS); nothing)

function start_prompt(mod, locals, ex, file, fileline;
                        terminal = TEST_TERMINAL_REF[],
                        repl = TEST_REPL_REF[],
                        nostack = TEST_NOSTACK[]
                      )
  (file, fileline) in STOP_SPOTS && return
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
  println(io, "Hit `@infiltrate", ex == true ? "" : " $(ex)", "` in ", current, ":")
  println(io)
  debugprompt(mod, locals, trace, terminal, repl, nostack, file=file, fileline=fileline)
  println(io)
end

function show_help(io)
  println(io, """
    Code entered is evaluated in the current function's module. Note that you cannot change local
    variables.
    The following commands are special cased:
      - `@trace`: Print the current stack trace.
      - `@locals`: Print local variables.
      - `@stop`: Stop infiltrating at this `@infiltrate` spot.

    Exit this REPL mode with `Ctrl-D`, and clear the effect of `@stop` with `Infiltrator.clear_stop()`.
  """)
end

function show_trace(io, trace)
  for (i, frame) in enumerate(trace)
    println(io, "[", i, "] ", frame)
  end
  println(io)
end

function show_locals(io, locals)
  for (var, val) in locals
    println(io, "- ", var, "::", typeof(val), " = ", repr(val))
  end
  println(io)
end

function debugprompt(mod, locals, trace, terminal, repl, nostack = false; file, fileline)
  io = Base.pipe_writer(terminal)

  try
    panel = REPL.LineEdit.Prompt("debug> ";
              prompt_prefix = prompt_color,
              prompt_suffix = Base.text_colors[:normal],
              complete = InfiltratorCompletionProvider(mod, locals),
              on_enter = s -> true)

    panel.hist = REPL.REPLHistoryProvider(Dict{Symbol,Any}(:Infiltrator => panel))
    REPL.history_reset_state(panel.hist)

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
      elseif sline == "@stop"
        push!(STOP_SPOTS, (file, fileline))
        println(io)
        LineEdit.reset_state(s)
        return true
      end
      ok = true
      result = nothing

      @static if VERSION >= v"1.2.0-DEV.253"
        try
          result = interpret(line, mod, locals)
        catch err
          ok = false
          result = Base.catch_stack()
          nostack && (result = map(r -> Any[first(r), []], result))
        end
        REPL.print_response(repl, (result, !ok), true, true)
      else
        try
          result = interpret(line, mod, locals)
        catch err
          ok = false
          result = (err, nostack ? Any[] : catch_backtrace())
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

maybe_quote(x) = (isa(x, Expr) || isa(x, Symbol)) ? QuoteNode(x) : x

function interpret(command::AbstractString, mod, locals)
    expr = Base.parse_input_line(command)
    Base.Meta.isexpr(expr, :toplevel) && (expr = expr.args[end])
    res = gensym()
    eval_expr = Expr(:let,
        Expr(:block, map(x->Expr(:(=), x...), [(k, maybe_quote(v)) for (k, v) in locals])...),
        Expr(:block,
            Expr(:(=), res, expr),
            Expr(:tuple, res, Expr(:tuple, [k for (k, v) in locals]...))
        ))
    eval_res, res = Core.eval(mod, eval_expr)
    eval_res
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
  prepend!(ret, filter!(v -> startswith(v, partial), string.(keys(c.locals))))

  # Infiltrator commands completions
  commands = ["?", "@trace", "@locals", "@stop"]
  prepend!(ret, filter!(c -> startswith(c, partial), commands))

  unique!(ret), range, should_complete
end

end # module
