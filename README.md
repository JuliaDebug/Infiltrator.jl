# Infiltrator.jl [![CI](https://github.com/JuliaDebug/Infiltrator.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaDebug/Infiltrator.jl/actions/workflows/CI.yml)

This packages provides a macro called `@infiltrate`, which sets a "breakpoint" in a local context
(similar to Matlab's `keyboard` function and IPython's `embed`). The advantage of this macro over e.g. Debugger.jl is that
all code is completely compiled, so the performance overhead should be negligible.

Note that you cannot access other functions in the callstack, or step into functions. If you need that
functionality, use Debugger.jl, VSCode's or Juno's debugger.

Running code that ends up triggering the `@infiltrate` REPL mode via inline evaluation in VSCode or Juno can cause issues,
so it's recommended to always use the REPL directly.

## `@infiltrate`
    @infiltrate cond = true

`@infiltrate` sets an infiltration point (or breakpoint).

When the infiltration point is hit, it will drop you into an interactive REPL session that
lets you inspect local variables and the call stack as well as execute aribtrary statements
in the context of the current functions module.

This macro also accepts an optional argument `cond` that must evaluate to a boolean,
and then this macro will serve as a "conditinal breakpoint", which starts inspections only
when its condition is `true`.

## `@exfiltrate`
    @exfiltrate

Assigns all local variables into global storage.

## The safehouse
Exfiltrating variables (with `@exfiltrate` or by assignment in a `@infiltrate` session) happens by
assigning the variable to a global storage space (backed by a module); any exfiltrated objects
can be directly accessed, via `Infiltrator.store` or its exported aliases `safehouse` or `exfiltrated`:
```
julia> foo(x) = @exfiltrate
foo (generic function with 1 method)

julia> foo(3)

julia> safehouse.x # or exfiltrated.x
3
```

You can reset the safehouse with `Infiltrator.clear_store!()`.

You can also assign a specific module with `Infiltrator.set_store!(mod)`. This allows you to e.g. set the backing module to `Main` and therefore export the contents of the safehouse to the global namespace (although doing so is not recommended).

## Example usage:
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
Infiltrating f(x::Vector{Int64}) at REPL[7]:5:

infil> ?
  Code entered is evaluated in the current functions module. Note that you cannot change local
  variables, but can assign to globals in a permanent store module.

  The following commands are special cased:
    - `?`: Print this help text.
    - `@trace`: Print the current stack trace.
    - `@locals`: Print local variables.
    - `@exfiltrate`: Save all local variables into the store.
    - `@toggle`: Toggle infiltrating at this `@infiltrate` spot (clear all with `Infiltrator.clear_disabled!()`).
    - `@continue`: Continue to the next infiltration point or exit (shortcut: Ctrl-D).
    - `@exit`: Stop infiltrating for the remainder of this session and exit (on Julia versions prior to
      1.5 this needs to be manually cleared with `Infiltrator.end_session!()`).

infil> @locals
- out::Vector{Any} = Any[2]
- i::Int64 = 1
- x::Vector{Int64} = [1, 2, 3]

infil> 0//0
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

infil> intermediate = copy(out) # assigned (or `@exfiltrate`d) variables can be accessed from the safehouse
1-element Vector{Any}:
 2

infil> @toggle
Disabled infiltration at this infiltration point.

infil> @toggle
Enabled infiltration at this infiltration point.

infil> @continue

Infiltrating f(x::Vector{Int64}) at REPL[7]:5:

infil> @locals
- out::Vector{Any} = Any[2, 4]
- i::Int64 = 2
- x::Vector{Int64} = [1, 2, 3]

infil> @exit

3-element Vector{Any}:
 2
 4
 6

julia> safehouse.intermediate
1-element Vector{Any}:
 2

julia> @withstore begin
         x = 23
         x .* intermediate
       end
1-element Vector{Int64}:
 46
```
