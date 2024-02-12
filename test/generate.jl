for version in ["1.1", "1.6", "1.7", "1.8", "1.9", "1.10"]
    println("Generating outputs with Julia v$version")
    run(addenv(`julia +$version --project=$(dirname(@__DIR__)) -e 'using Pkg; Pkg.test()'`, "INFILTRATOR_CREATE_TEST" => 1))
end