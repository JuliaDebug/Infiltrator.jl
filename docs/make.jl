using Documenter, Infiltrator

cp(joinpath(@__DIR__, "..", "README.md"), joinpath(@__DIR__, "src", "index.md"); force=true)

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
