using Test, Infiltrator, REPL

foo = 3
function f(x)
    x = 2
    y = [1, 2, 3]
    @infiltrate
    return x .+ y
end

function g(x)
    x *= 12
    @infiltrate x > 12
    return x
end

if Sys.isunix() && VERSION >= v"1.1.0"
    using TerminalRegressionTests

    function run_terminal_test(func, result, commands, validation)
        # TerminalRegressionTests.automated_test(joinpath(@__DIR__, validation), commands) do emuterm
        TerminalRegressionTests.create_automated_test(joinpath(@__DIR__, validation), commands) do emuterm
            repl = REPL.LineEditREPL(emuterm, true)
            repl.interface = REPL.setup_interface(repl)
            repl.specialdisplay = REPL.REPLDisplay(repl)

            Infiltrator.TEST_TERMINAL_REF[] = repl.t
            Infiltrator.TEST_NOSTACK[] = true
            Infiltrator.TEST_REPL_REF[] = repl
            @test func() == result
            Infiltrator.TEST_TERMINAL_REF[] = nothing
            Infiltrator.TEST_NOSTACK[] = false
            Infiltrator.TEST_REPL_REF[] = nothing
        end
    end

    run_terminal_test(() -> f(3), [3, 4, 5],
                      ["?\n", "@trace\n", "@locals\n", "x.*y\n", "foo\n", "0//0\n", "@stop\n", "\x4"],
                      "Julia_f_$(VERSION.major).$(VERSION.minor).multiout")

    @test f(3) == [3, 4, 5] # `@stop`ped `@infiltrate` should not open a prompt

    Infiltrator.clear_stop()

    run_terminal_test(() -> f(3), [3, 4, 5],
                      ["@locals\n", "\x4"],
                      "Julia_f2_$(VERSION.major).$(VERSION.minor).multiout")

    @test g(1) == 12 # conditional @infiltrate should not open a prompt

    run_terminal_test(() -> g(2), 24,
                      ["?\n", "@trace\n", "@locals\n", "x\n", "\x4"],
                      "Julia_g_$(VERSION.major).$(VERSION.minor).multiout")
else
    @warn "Skipping UI tests on non unix systems"
end
