# Infiltrator.jl [![Build Status](https://travis-ci.org/JuliaDebug/Infiltrator.jl.svg?branch=master)](https://travis-ci.org/JuliaDebug/Infiltrator.jl)

This packages provides a macro called `@infiltrate`, which sets a "breakpoint" in a local context
(similar to Matlab's `keyboard` function and IPython's `embed`). The advantage of this macro over e.g. Debugger.jl is that
all code is completely compiled, so the performance overhead should be negligible.

Note that you cannot access other functions in the callstack, or step into functions. If you need that
functionality, use Debugger.jl, VSCode's or Juno's debugger.

Running code that ends up triggering the `@infiltrate` REPL mode via inline evaluation in VSCode or Juno can cause issues,
so it's recommended to always use the REPL directly.

## `@infiltrate` macro

The `@infiltrate` macro is the entry point of infiltration.

<!-- extracted from the @infiltrate doc -->

    @infiltrate cond = true

`@infiltrate` sets "breakpoint" in a local context.
When the breakpoint is hit, it will drop you into an interactive REPL session that lets you
inspect local variables and the call stack as well as execute aribtrary statements in the
context of the current function's module.

This macro also accepts an optional argument `cond` that must evaluate to a boolean,
and then this macro will serve as a "conditinal breakpoint",
which starts inspections only when its condition is `true`.

### Usage:
```julia
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

debug> # press Ctrl-D and exit

8

julia>
```
