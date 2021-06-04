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

h(x) = [f(x) for x in x]

function i(x)
    y = [1.0 for _ in 1:x]
    @infiltrate
    return y
end

function j(x)
    xxxxx = 4
    @infiltrate
    return x*xxxxx
end

if Sys.isunix() && VERSION >= v"1.1.0"
    using TerminalRegressionTests

    function run_terminal_test(func, result, commands, validation)
        TerminalRegressionTests.automated_test(joinpath(@__DIR__, validation), commands) do emuterm
        # TerminalRegressionTests.create_automated_test(joinpath(@__DIR__, validation), commands) do emuterm
            Infiltrator.end_session()
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
                      ["?\n", "@trace\n", "@locals\n", "x.*y\n", "3+\n4\n", "foo\n", "0//0\n", "@toggle\n", "@toggle\n", "@toggle\n", "\x4"],
                      "Julia_f_$(VERSION.major).$(VERSION.minor).multiout")

    @test f(3) == [3, 4, 5] # `@toggle`d `@infiltrate` should not open a prompt

    Infiltrator.clear_disabled()

    run_terminal_test(() -> f(3), [3, 4, 5],
                      ["@locals\n", "\x4"],
                      "Julia_f2_$(VERSION.major).$(VERSION.minor).multiout")

    @test g(1) == 12 # conditional @infiltrate should not open a prompt

    run_terminal_test(() -> g(2), 24,
                      ["?\n", "@trace\n", "@locals\n", "x\n", "\x4"],
                      "Julia_g_$(VERSION.major).$(VERSION.minor).multiout")

    run_terminal_test(() -> h([1,2,3]), [[3,4,5], [3,4,5], [3,4,5]],
                      ["\x4", "@locals\n", "@exit\n"],
                      "Julia_h_$(VERSION.major).$(VERSION.minor).multiout")


    run_terminal_test(() -> i(1000), i(1000),
                      ["2+2\n", "@locals\n", "\x4"],
                      "Julia_i_$(VERSION.major).$(VERSION.minor).multiout")

    # scratch pad test
    run_terminal_test(() -> g(2), 24,
                      ["@locals\n", "xxxxx = 12\n", "foo(x) = x\n", "function bar(x); 2x; end\n", "x = 2\n", "\x4"],
                      "Julia_exfil_$(VERSION.major).$(VERSION.minor).multiout")

    m = Infiltrator.get_scratch_pad()
    @test m.xxxxx == 12
    @test m.foo(3) == 3
    @test m.bar(3) == 6
    @test !isdefined(m, :x)

    # proper scoping of scratch pad
    run_terminal_test(() -> j(2), 8,
                      ["@locals\n", "\x4"],
                      "Julia_scoping_$(VERSION.major).$(VERSION.minor).multiout")

    m = Infiltrator.get_scratch_pad()
    @test m.xxxxx == 12

    # persistent history
    run_terminal_test(() -> h([1,2,3]), [[3,4,5], [3,4,5], [3,4,5]],
                      ["y\n", "\e[A\n", "\x4", "\e[A\n", "@exit\n"],
                      "Julia_hist_$(VERSION.major).$(VERSION.minor).multiout")
else
    @warn "Skipping UI tests on non unix systems"
end
