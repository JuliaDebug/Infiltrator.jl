using Documenter, Infiltrator

open(joinpath(@__DIR__, "src", "index.md"), "w") do io
    println(io, """
    ```@raw html
    <div align="center">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
      <source media="(prefers-color-scheme: light)" srcset="assets/logo.svg">
      <img alt="Infiltrator Logo" src="assets/logo.svg" width="150px">
    </picture>
    </div>
    ```
    """)
    for line in readlines(joinpath(@__DIR__, "..", "README.md"))
        startswith(line, r"\s*<") && continue
        println(io, line)
    end
end

makedocs(;
    modules=[Infiltrator],
    warnonly = [:missing_docs, :linkcheck],
    format=Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        assets = ["assets/favicon.ico"],
    ),
    repo="https://github.com/JuliaDebug/Infiltrator.jl/blob/{commit}{path}#L{line}",
    sitename="Infiltrator.jl",
    authors = "Sebastian Pfitzner"
)

if get(ENV, "CI", nothing) == "true"
    deploydocs(;
        repo="github.com/JuliaDebug/Infiltrator.jl",
        push_preview = true
    )
end
