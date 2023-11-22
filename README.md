<div align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/src/assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/src/assets/logo.svg">
  <img alt="Infiltrator Logo" src="docs/src/assets/logo.svg" width="150px">
</picture>
</div>

# Infiltrator.jl

[![CI](https://github.com/JuliaDebug/Infiltrator.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/JuliaDebug/Infiltrator.jl/actions/workflows/CI.yml) [![Codecov](https://codecov.io/gh/JuliaDebug/Infiltrator.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaDebug/Infiltrator.jl) [![version](https://juliahub.com/docs/Infiltrator/version.svg)](https://juliahub.com/ui/Packages/Infiltrator/ge3PS)

[![docs stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://juliadebug.github.io/Infiltrator.jl/stable) [![docs dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://juliadebug.github.io/Infiltrator.jl/dev)

This packages provides the `@infiltrate` macro, which acts as a breakpoint with negligible runtime
performance overhead.

Note that you cannot access other function scopes or step into further calls. Use an actual debugger
if you need that level of flexibility.

Running code that ends up triggering the `@infiltrate` REPL mode via inline evaluation in VS Code
or Juno can cause issues, so it's recommended to always use the REPL directly.

## `@infiltrate`

```julia
@infiltrate
@infiltrate condition::Bool
```

`@infiltrate` sets an infiltration point.

When the infiltration point is hit, it will drop you into an interactive REPL session that
lets you inspect local variables and the call stack as well as execute arbitrary statements
in the context of the current local and global scope.

The optional argument `cond` only enables this infiltration point if it evaluates to `true`, e.g.

```julia
@infiltrate false # does not infiltrate
```

You can also use

```julia
if isdefined(Main, :Infiltrator)
  Main.infiltrate(@__MODULE__, Base.@locals, @__FILE__, @__LINE__)
end
```

to infiltrate package code without any post-hoc evaluation into the module (because the
functional form does not require Infiltrator to be loaded at compiletime).

## Auto-loading Infiltrator.jl

The following convenience macro can be defined in e.g. `startup.jl` or your package code.
It will automatically load Infiltrator.jl (if it is in your environment stack) and
subsequently call `@infiltrate`:
```julia
macro autoinfiltrate(cond=true)
    pkgid = Base.PkgId(Base.UUID("5903a43b-9cc3-4c30-8d17-598619ec4e9b"), "Infiltrator")
    if !haskey(Base.loaded_modules, pkgid)
        try
            Base.eval(Main, :(using Infiltrator))
        catch err
            @error "Cannot load Infiltrator.jl. Make sure it is included in your environment stack."
        end
    end
    i = get(Base.loaded_modules, pkgid, nothing)
    lnn = LineNumberNode(__source__.line, __source__.file)

    if i === nothing
        return Expr(
            :macrocall,
            Symbol("@warn"),
            lnn,
            "Could not load Infiltrator.")
    end

    return Expr(
        :macrocall,
        Expr(:., i, QuoteNode(Symbol("@infiltrate"))),
        lnn,
        esc(cond)
    )
end
```
Note that this probably won't work as expected in module-level statements in package code due
to precompilation.

## `@exfiltrate`

```julia
@exfiltrate
```

Assigns all local variables into global storage.

## The safehouse

Exfiltrating variables (with `@exfiltrate` or by assignment in an `@infiltrate` session) happens by
assigning the variable to a global storage space (backed by a module); any exfiltrated objects
can be directly accessed, via `Infiltrator.store` or its exported aliases `safehouse` or `exfiltrated`:

```julia
julia> foo(x) = @exfiltrate
foo (generic function with 1 method)

julia> foo(3)

julia> safehouse.x # or exfiltrated.x
3
```

You can reset the safehouse with `Infiltrator.clear_store!()`.

You can also assign a specific module with `Infiltrator.set_store!(mod)`. This allows you to e.g. set the
backing module to `Main` and therefore export the contents of the safehouse to the global namespace
(although doing so is not recommended).

## Example usage

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

julia> f([1,2,3,4,5,6,7,8,9,10])
Infiltrating f(x::Vector{Int64})
  at REPL[10]:5

infil> ?
  Code entered here is evaluated in the current scope. Changes to local variables are not possible; global variables can only be changed with eval/@eval.

  All assignments will end up in the safehouse.

  The following commands are special cased:

    •  ?: Print this help text.

    •  @trace: Print the current stack trace.

    •  @locals: Print local variables. @locals x y only prints x and y.

    •  @exfiltrate: Save all local variables into the store. @exfiltrate x y saves x and y; this variant can also exfiltrate variables defined in the infil> REPL.

    •  @toggle: Toggle infiltrating at this @infiltrate spot (clear all with Infiltrator.clear_disabled!()).

    •  @cond expr: Infiltrate at this @infiltrate spot only if <expr> evaluates to true (clear all with
       Infiltrator.clear_conditions!()).

    •  @continue: Continue to the next infiltration point or exit (shortcut: Ctrl-D).

    •  @doc symbol: Get help for symbol (same as in the normal Julia REPL).

    •  @exit: Stop infiltrating for the remainder of this session and exit (on Julia versions prior to 1.5 this needs to be manually cleared with Infiltrator.end_session!()).

infil> @locals
- out::Vector{Any} = Any[2]
- i::Int64 = 1
- x::Vector{Int64} = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

infil> 0//0
ERROR: ArgumentError: invalid rational: zero(Int64)//zero(Int64)
Stacktrace:
 [1] __throw_rational_argerror_zero(T::Type)
   @ Base ./rational.jl:32
 [2] Rational{Int64}(num::Int64, den::Int64)
   @ Base ./rational.jl:34
 [3] Rational
   @ ./rational.jl:39 [inlined]
 [4] //(n::Int64, d::Int64)
   @ Base ./rational.jl:62
 [5] top-level scope
   @ none:1

infil> @toggle
Disabled infiltration at this infiltration point.

infil> @toggle
Enabled infiltration at this infiltration point.

infil> @cond i > 5
Conditionally enabled infiltration at this infiltration point.

infil> @continue

Infiltrating f(x::Vector{Int64})
  at REPL[10]:5

infil> i
6

infil> intermediate = copy(out)
6-element Vector{Any}:
  2
  4
  6
  8
 10
 12

infil> @exfiltrate intermediate x
Exfiltrating 2 local variables into the safehouse.

infil> @exit

10-element Vector{Any}:
  2
  4
  6
  8
 10
 12
 14
 16
 18
 20


julia> safehouse.intermediate
6-element Vector{Any}:
  2
  4
  6
  8
 10
 12

julia> @withstore begin
         x = 23
         x .* intermediate
       end
6-element Vector{Int64}:
  46
  92
 138
 184
 230
 276
```

## Related projects

- [`@exfiltrate` for Python](https://github.com/NightMachinary/PyExfiltrator)
