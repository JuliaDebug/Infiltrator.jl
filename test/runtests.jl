using Test, Infiltrator, REPL

baz = 3
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
    return x * xxxxx
end

struct Bar
    xxx
    yyy
end
function k()
    zzzzz = 333
    aaaa = Bar(zzzzz, zzzzz)
    @infiltrate
    return aaaa
end

module Jmod
    using Random
    using ..Infiltrator
    jfunc() = @infiltrate
end

function multiexfiltrate()
    for i in 1:10
        @infiltrate
    end
    return
end

function function_form_infiltration(x)
    return if isdefined(Main, :Infiltrator)
        Main.infiltrate(@__MODULE__, Base.@locals, @__FILE__, @__LINE__)
    end
end

function anon()
    return let
        m = Module()
        Core.eval(m, :(using Infiltrator))
        Core.eval(m, :(aasdf = 3))
        Core.eval(m, :(f() = @infiltrate))
        Core.eval(m, :(f()))
    end
end

function cond(t)
    for i in 1:10
        println(t, i)
        @infiltrate
    end
    return
end

function infiltry(x)
    return @infiltry x // x
end

function globalref(m, s)
    gr = GlobalRef(m, s)
    @infiltrate
    return gr
end

module Asdf
    using ..Infiltrator: Infiltrator as I, @infiltrate

    function f(x)
        @infiltrate
        return x
    end
end

module Shadow
    using ..Infiltrator: @infiltrate

    a = 1
    function shadow()
        a = 2
        @infiltrate

        return a
    end
end


@static if Sys.isunix()
    using TerminalRegressionTests

    @static if VERSION >= v"1.11"
        # FIXME: this is a hack to work around the test failures on 1.11.
        # The LineEdit code now assumes that eof and peek interact correctly (i.e. that
        # `eof(term) || peek(term)` won't error), but that's not true for EmulatedTerminals.
        @eval Base.peek(::TerminalRegressionTests.EmulatedTerminal) = UInt8(0)
    end

    function run_terminal_test(func, result, commands, testname)
        testpath = joinpath(@__DIR__, "outputs", "$(VERSION.major).$(VERSION.minor)", "$testname.multiout")
        mkpath(dirname(testpath))

        test_func = TerminalRegressionTests.automated_test
        if haskey(ENV, "INFILTRATOR_CREATE_TEST") && !haskey(ENV, "CI")
            test_func = TerminalRegressionTests.create_automated_test
            @info "Generating regression test outputs for $testname"
        end

        test_func(testpath, commands) do emuterm
            Infiltrator.end_session!()
            repl = REPL.LineEditREPL(emuterm, true)
            repl.interface = REPL.setup_interface(repl)
            repl.mistate = REPL.LineEdit.init_state(REPL.terminal(repl), repl.interface)
            repl.specialdisplay = REPL.REPLDisplay(repl)

            Infiltrator.TEST_TERMINAL_REF[] = repl.t
            Infiltrator.TEST_NOSTACK[] = true
            Infiltrator.TEST_REPL_REF[] = repl
            Infiltrator.CHECK_TASK[] = false

            @test func(repl.t) == result

            Infiltrator.TEST_TERMINAL_REF[] = nothing
            Infiltrator.TEST_NOSTACK[] = false
            Infiltrator.TEST_REPL_REF[] = nothing
            if VERSION > v"1.9-"
                finalize(emuterm.pty)
            end
        end
    end

    @testset "infiltration tests" begin
        run_terminal_test(
            (t) -> f(3), [3, 4, 5],
            ["?\n", "@trace\n", "@trace_all\n", "@locals\n", "x.*y\n", "3+\n4\n", "ans\n", "baz\n", "0//0\n", "@toggle\n", "@toggle\n", "@toggle\n", "\x4"],
            "f"
        )

        @test f(3) == [3, 4, 5] # `@toggle`d `@infiltrate` should not open a prompt

        Infiltrator.clear_disabled!()

        run_terminal_test(
            (t) -> f(3), [3, 4, 5],
            ["@locals\n", "\x4"],
            "f2"
        )

        run_terminal_test(
            (t) -> f(3), [3, 4, 5],
            ["@locals x\n", "\x4"],
            "f2_filter"
        )

        @test g(1) == 12 # conditional @infiltrate should not open a prompt

        run_terminal_test(
            (t) -> g(2), 24,
            ["?\n", "@trace\n", "@locals\n", "x\n", "\x4"],
            "g"
        )

        run_terminal_test(
            (t) -> h([1, 2, 3]), [[3, 4, 5], [3, 4, 5], [3, 4, 5]],
            ["\x4", "@locals\n", "@exit\n"],
            "h"
        )

        # Test that history is correctly using prefixes.
        run_terminal_test(
            (t) -> h([1, 2, 3]), [[3, 4, 5], [3, 4, 5], [3, 4, 5]],
            ["y = 1\n", "x = 3\n", "y\e[A\n", "\x4", "y\e[A\n", "@exit\n"],
            "phist"
        )

        run_terminal_test(
            (t) -> i(1000), i(1000),
            ["2+2\n", "@locals\n", "\x4"],
            "i"
        )

        # scratch pad test
        run_terminal_test(
            (t) -> g(2), 24,
            ["@locals\n", "xxxxx = 12\n", "aa, bb = ('a', 'b')\n", "foo(x) = x\n", "function bar(x); 2x; end\n", "x = 2\n", "@exfiltrate xxxxx aa bb foo bar\n", "\x4"],
            "exfil"
        )

        @test Infiltrator.store.xxxxx == 12
        @test Infiltrator.store.aa == 'a'
        @test Infiltrator.store.bb == 'b'
        @test Infiltrator.store.foo(3) == 3
        @test Infiltrator.store.bar(3) == 6
        @test !isdefined(getfield(Infiltrator.store, :store), :x)

        # proper scoping of scratch pad
        run_terminal_test(
            (t) -> j(2), 8,
            ["@locals\n", "@exfiltrate\n", "\x4"],
            "scoping"
        )

        @test Infiltrator.store.xxxxx == 4

        # persistent history
        run_terminal_test(
            (t) -> h([1, 2, 3]), [[3, 4, 5], [3, 4, 5], [3, 4, 5]],
            ["y\n", "\e[A\n", "\x4", "\e[A\n", "@exit\n"],
            "hist"
        )

        # top-level test
        run_terminal_test(
            (t) -> begin
                if VERSION > v"1.7"
                    redirect_stdout(t) do
                        include(joinpath(@__DIR__, "fixtures", "toplevel-fixture.jl"))
                    end
                else
                    include(joinpath(@__DIR__, "fixtures", "toplevel-fixture.jl"))
                end
            end, "success",
            ["@exit\n"],
            "toplevel"
        )

        # completions test
        run_terminal_test(
            (t) -> k(), Bar(333, 333),
            ["struct Foo\nxxx\nyyy\nend\n", "foo = Foo(1, 2)\n", "fo\t\t\x3", "foo.xx\t\t\n", "zz\t\t\x3", "aa\t\t\x3", "aaaa.xx\t\t\n", "@exfiltrate foo nope\n", "@exit\n"],
            "completions"
        )
        @test Infiltrator.store.foo.xxx == 1

        # imported globals
        run_terminal_test(
            (t) -> Jmod.jfunc(), nothing,
            ["x\n", "randstring\n", "@exit\n"],
            "imported_globals"
        )

        run_terminal_test(
            (t) -> globalref(Main, :undefvar), GlobalRef(Main, :undefvar),
            ["gr\n", "@exit\n"],
            "globalref"
        )

        # safehouse should not shadow local variables
        run_terminal_test(
            (t) -> multiexfiltrate(), nothing,
            ["i\n", "@continue\n", "i\n", "@exfiltrate\n", "@continue\n", "i\n", "safehouse.i\n", "@continue\n", "@exit\n"],
            "multi_exfiltrate"
        )
        @test Infiltrator.store.i == 2

        # function-form infiltration
        run_terminal_test(
            (t) -> function_form_infiltration(2), nothing,
            ["x\n", "@exit\n"],
            "function_inf"
        )

        # test Core.Compiler
        @static if VERSION >= v"1.8"
            @eval Core.Compiler __foo(x) = Main.Infiltrator.@infiltrate
            run_terminal_test(
                (t) -> Core.Compiler.__foo(Core.SSAValue(3)), nothing,
                ["x\n", "@exfiltrate\n", "@exit\n"],
                "compiler"
            )
            @test Infiltrator.store.x == Core.SSAValue(3)
        end

        # anonymous modules
        run_terminal_test(
            (t) -> anon(), nothing,
            ["aas\t\t\n", "@exfiltrate aasdf\n", "@exit\n"],
            "anon"
        )
        @test Infiltrator.store.aasdf == 3

        # conditional infiltration
        run_terminal_test(
            (t) -> cond(t), nothing,
            ["@continue\n", "@continue\n", "@cond i > 6\n", "@continue\n", "i\n", "@exit\n"],
            "cond"
        )

        # soft scoping
        run_terminal_test(
            (t) -> f(3), [3, 4, 5],
            ["x = 1; for i in 1:5; x = i; end\n", "x\n", "\x4"],
            "soft"
        )

        # import as, only works on 1.12
        if VERSION > v"1.12-"
            run_terminal_test(
                (t) -> Asdf.f(1), 1,
                ["I\n", "I.all_names\n", "\x4"],
                "importas"
            )
        end

        run_terminal_test(
            (t) -> f(3), [3, 4, 5],
            ["\\sigm\t\t = 2\n", "\\sig\t\t\n", "\x4"],
            "backslash completions"
        )

        run_terminal_test(
            (t) -> Shadow.shadow(), 2,
            ["a\n", "Shadow.a\n", "\x4"],
            "shadowing of global bindings"
        )
    end

    @testset "infiltry" begin
        run_terminal_test(
            (t) -> try
                infiltry(0)
            catch
                nothing
            end, nothing,
            ["@exception\n", "@locals\n", "@exit\n"],
            "infiltry"
        )

        function foo(x)
            @infiltry z = 2x
            z
        end
        @test foo(2) == 4

        function bar(x)
            @infiltry y, z = 2x, 3x
            y + z
        end
        @test bar(1) == 5
    end
else
    @warn "Skipping UI tests on non unix systems"
end

@testset "exfiltration tests" begin
    Infiltrator.clear_store!()
    function foo_ex(x)
        y = 3
        foo = :asd
        store = 33
        bar = function (yy)
            yy
        end
        @exfiltrate
    end
    foo_ex(55)

    @test Infiltrator.store.y == 3
    @test Infiltrator.store.foo == :asd
    @test Infiltrator.store.store == 33
    @test Infiltrator.store.bar(3) == 3
    @test_throws UndefVarError Infiltrator.store.asd

    # `@with` is basically for dynamic usage only
    @test 6 == Core.eval(@__MODULE__, :(Infiltrator.@withstore(2y)))
    @test "asd" == Core.eval(@__MODULE__, :(Infiltrator.@withstore(string(foo))))

    Infiltrator.clear_store!()
    function foo_ex2(x)
        yy = x * 2
        @exfiltrate x zz = yy + 2
    end
    foo_ex2(55)
    @test Infiltrator.store.zz == 55 * 2 + 2
    @test Infiltrator.store.x == 55
    @test_throws UndefVarError Infiltrator.store.yy
end
