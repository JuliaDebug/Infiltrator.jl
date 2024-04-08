# API

## Infiltration and exfiltration
Add [`@infiltrate`](@ref) to any function to start the `infil>` REPL mode when that line runs.

It's recommended to put Infiltrator.jl into your global environment and not into package environments
for two reasons:
- Infiltrator.jl is intended as a development tool only and as such should not be shipped
- Any `@infiltrate` invocations in your package code will fail at compile-time, which prevents you from accidentally committing infiltrated code

This means that you'll need to use [Revise.jl](https://github.com/timholy/Revise.jl), inline evaluation
in VS Code, or just plain old `@eval` to apply `@infiltrate` statements in your package code.
```@docs
@infiltrate
@infiltry
infiltrate
@exfiltrate
```

## The safehouse

This is where all exfiltrated variables end up. You can either exfiltrate a variable explicitly with
`@exfiltrate` or implicitly by assignment in the `infil>` REPL mode.
```@docs
safehouse
Infiltrator.clear_store!
Infiltrator.set_store!
Infiltrator.@withstore
```

## Utility
```@docs
Infiltrator.clear_disabled!
Infiltrator.end_session!
Infiltrator.toggle_async_check
```