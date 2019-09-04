module Infiltrator

using REPL
using REPL.LineEdit

export @infiltrate

struct InfiltratorState
  locals::Dict{Symbol, Any}
  trace::Vector
  mod::Module
  file::String
  line::Int
  condition
end

function create_infiltrator_state(locals, backtrace, mod, file, line, condition)
  # TODO: Use backtrace() so that we can use Base.show_backtrace()
  trace = stacktrace()
  start = something(findlast(x -> x.func === Symbol("create_infiltrator_state"), trace), 0) + 2
  last = something(findlast(x -> x.func === Symbol("eval"), trace),
                  length(trace)) - 2
  trace = trace[start:last]
  return InfiltratorState(locals, trace, mod, file, line, condition)
end

maybe_quote(x) = (isa(x, Expr) || isa(x, Symbol)) ? QuoteNode(x) : x

function interpret(state::InfiltratorState, command::AbstractString)
    expr = Base.parse_input_line(command)
    Base.Meta.isexpr(expr, :toplevel) && (expr = expr.args[end])
    res = gensym()
    eval_expr = Expr(:let,
        Expr(:block, map(x->Expr(:(=), x...), [(k, maybe_quote(v)) for (k, v) in state.locals])...),
        Expr(:block,
            Expr(:(=), res, expr),
            Expr(:tuple, res, Expr(:tuple, [k for (k, v) in state.locals]...))
        ))
    eval_res, res = Core.eval(state.mod, eval_expr)
    eval_res
end

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

  Exit this REPL mode with `Ctrl-D`.

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
macro infiltrate(condition = true)
  quote
    if $(esc(condition))
      start_prompt(create_infiltrator_state(Base.@locals, stacktrace(), @__MODULE__, @__FILE__, @__LINE__, $(QuoteNode(condition))))
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

function start_prompt(state::InfiltratorState,
                        terminal = TEST_TERMINAL_REF[],
                        repl = TEST_REPL_REF[],
                        nostack = TEST_NOSTACK[]
                      )
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

  current = state.trace[1]
  println(io, "Hit `@infiltrate", state.condition == true ? "" : " $(state.condition)", "` in ", current, ":")
  println(io)
  debugprompt(state, terminal, repl, nostack)
  println(io)
end

function show_help(io)
  println(io, """
    Code entered is evaluated in the current function's module. Note that you cannot change local
    variables.
    The following commands are special cased:
      - `@trace`: Print the current stack trace.
      - `@locals`: Print local variables.

    Exit this REPL mode with `Ctrl-D`.
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

function debugprompt(state, terminal, repl, nostack = false)
  io = Base.pipe_writer(terminal)

  try
    panel = REPL.LineEdit.Prompt("debug> ";
              prompt_prefix = prompt_color,
              prompt_suffix = Base.text_colors[:normal],
              on_enter = s -> true)

    panel.hist = REPL.REPLHistoryProvider(Dict{Symbol,Any}(:VarExplosions => panel))
    panel.complete = REPL.LatexCompletions()
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
        show_trace(io, state.trace)
        LineEdit.reset_state(s)
        return true
      elseif sline == "@locals"
        show_locals(io, state.locals)
        LineEdit.reset_state(s)
        return true
      end
      ok = true
      result = nothing

      @static if VERSION >= v"1.2.0-DEV.253"
        try
          result = interpret(state, line)
        catch err
          ok = false
          result = Base.catch_stack()
          nostack && (result = map(r -> Any[first(r), []], result))
        end
        REPL.print_response(repl, (result, !ok), true, true)
      else
        try
          result = interpret(state, line)
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

end # module
