for version in ["1.1", "1.6", "1.7", "1.8", "1.9", "1.10", "1.11", "1.12"]
    println("Generating outputs with Julia v$version")
    rm(joinpath(@__DIR__, "..", "Manifest.toml"))
    run(addenv(`julia +$version --project=$(dirname(@__DIR__)) -e 'using Pkg; Pkg.instantiate(); Pkg.test()'`, "INFILTRATOR_CREATE_TEST" => 1))
end
