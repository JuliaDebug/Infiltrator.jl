using Test, VarExplosions, REPL

foo = 3
function f(x)
    x = 2
    y = [1, 2, 3]
    @varexplode
    return x .+ y
end

if Sys.isunix() && VERSION >= v"1.1.0"
    using TerminalRegressionTests

    function run_terminal_test(func, commands, validation)
        TerminalRegressionTests.automated_test(joinpath(@__DIR__, validation), commands) do emuterm
        # TerminalRegressionTests.create_automated_test(joinpath(@__DIR__, validation), commands) do emuterm
            repl = REPL.LineEditREPL(emuterm, true)
            repl.interface = REPL.setup_interface(repl)
            repl.specialdisplay = REPL.REPLDisplay(repl)

            VarExplosions.TEST_TERMINAL_REF[] = repl.t
            VarExplosions.TEST_REPL_REF[] = repl
            @test func() == [3,4,5]
            VarExplosions.TEST_TERMINAL_REF[] = nothing
            VarExplosions.TEST_REPL_REF[] = nothing
        end
        if isfile(joinpath(@__DIR__, "expected.out"))
            @show read(joinpath(@__DIR__, "expected.out"), String)
            @show read(joinpath(@__DIR__, "failed.out"), String)
        end
    end

    run_terminal_test(() -> f(3),
                      ["?\n", "@trace\n", "@locals\n", "x.*y\n", "foo\n", "0//0\n", "\x4"],
                      "Julia_$(VERSION.major).$(VERSION.minor).multiout")
else
    @warn "Skipping UI tests on non unix systems"
end
