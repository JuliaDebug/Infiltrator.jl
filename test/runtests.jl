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
    return x*xxxxx
end

struct Bar
    xxx
    yyy
end
function k()
    zzzzz = 333
    aaaa = Bar(zzzzz, zzzzz)
    @infiltrate
    aaaa
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
end

function function_form_infiltration(x)
    if isdefined(Main, :Infiltrator)
        Main.infiltrate(@__MODULE__, Base.@locals, @__FILE__, @__LINE__)
    end
end

function anon()
    let
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
end

function infiltry(x)
    @infiltry x//x
end

function globalref(m, s)
    gr = GlobalRef(m, s)
    @infiltrate
    return gr
end

@testset "infiltration tests" begin
    if Sys.isunix() && VERSION >= v"1.1.0"
        using TerminalRegressionTests

        function run_terminal_test(func, result, commands, validation)
            test_func = TerminalRegressionTests.automated_test
            if haskey(ENV, "INFILTRATOR_CREATE_TEST") && !haskey(ENV, "CI")
                test_func = TerminalRegressionTests.create_automated_test
            end
            test_func(joinpath(@__DIR__, "outputs", validation), commands) do emuterm
                Infiltrator.end_session!()
                repl = REPL.LineEditREPL(emuterm, true)
                repl.interface = REPL.setup_interface(repl)
                repl.mistate = REPL.LineEdit.init_state(REPL.terminal(repl), repl.interface)
                repl.specialdisplay = REPL.REPLDisplay(repl)

                Infiltrator.TEST_TERMINAL_REF[] = repl.t
                Infiltrator.TEST_NOSTACK[] = true
                Infiltrator.TEST_REPL_REF[] = repl;
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
        run_terminal_test((t) -> f(3), [3, 4, 5],
                        ["?\n", "@trace\n", "@locals\n", "x.*y\n", "3+\n4\n", "ans\n", "baz\n", "0//0\n", "@toggle\n", "@toggle\n", "@toggle\n", "\x4"],
                        "Julia_f_$(VERSION.major).$(VERSION.minor).multiout")

        @test f(3) == [3, 4, 5] # `@toggle`d `@infiltrate` should not open a prompt

        Infiltrator.clear_disabled!()

        run_terminal_test((t) -> f(3), [3, 4, 5],
                        ["@locals\n", "\x4"],
                        "Julia_f2_$(VERSION.major).$(VERSION.minor).multiout")

        run_terminal_test((t) -> f(3), [3, 4, 5],
                        ["@locals x\n", "\x4"],
                        "Julia_f2_filter_$(VERSION.major).$(VERSION.minor).multiout")

        @test g(1) == 12 # conditional @infiltrate should not open a prompt

        run_terminal_test((t) -> g(2), 24,
                        ["?\n", "@trace\n", "@locals\n", "x\n", "\x4"],
                        "Julia_g_$(VERSION.major).$(VERSION.minor).multiout")

        run_terminal_test((t) -> h([1,2,3]), [[3,4,5], [3,4,5], [3,4,5]],
                        ["\x4", "@locals\n", "@exit\n"],
                        "Julia_h_$(VERSION.major).$(VERSION.minor).multiout")

        run_terminal_test((t) -> i(1000), i(1000),
                        ["2+2\n", "@locals\n", "\x4"],
                        "Julia_i_$(VERSION.major).$(VERSION.minor).multiout")

        # scratch pad test
        run_terminal_test((t) -> g(2), 24,
                        ["@locals\n", "xxxxx = 12\n", "aa, bb = ('a', 'b')\n","foo(x) = x\n", "function bar(x); 2x; end\n", "x = 2\n", "@exfiltrate xxxxx aa bb foo bar\n", "\x4"],
                        "Julia_exfil_$(VERSION.major).$(VERSION.minor).multiout")

        @test Infiltrator.store.xxxxx == 12
        @test Infiltrator.store.aa == 'a'
        @test Infiltrator.store.bb == 'b'
        @test Infiltrator.store.foo(3) == 3
        @test Infiltrator.store.bar(3) == 6
        @test !isdefined(getfield(Infiltrator.store, :store), :x)

        # proper scoping of scratch pad
        run_terminal_test((t) -> j(2), 8,
                        ["@locals\n", "@exfiltrate\n", "\x4"],
                        "Julia_scoping_$(VERSION.major).$(VERSION.minor).multiout")

        @test Infiltrator.store.xxxxx == 4

        # persistent history
        run_terminal_test((t) -> h([1,2,3]), [[3,4,5], [3,4,5], [3,4,5]],
                        ["y\n", "\e[A\n", "\x4", "\e[A\n", "@exit\n"],
                        "Julia_hist_$(VERSION.major).$(VERSION.minor).multiout")

        # top-level test
        run_terminal_test((t) -> begin
                            if VERSION > v"1.7"
                                redirect_stdout(t) do
                                    include(joinpath(@__DIR__, "fixtures", "toplevel-fixture.jl"))
                                end
                            else
                                include(joinpath(@__DIR__, "fixtures", "toplevel-fixture.jl"))
                            end
                        end, "success",
                        ["@exit\n"],
                        "Julia_toplevel_$(VERSION.major).$(VERSION.minor).multiout")

                        # completions test
        run_terminal_test((t) -> k(), Bar(333, 333),
                        ["struct Foo\n  xxx\n  yyy\nend\n", "foo = Foo(1, 2)\n", "fo\t\t\x3", "foo.xx\t\t\n", "zz\t\t\x3", "aa\t\t\x3", "aaaa.xx\t\t\n", "@exfiltrate foo nope\n", "@exit\n"],
                        "Julia_completions_$(VERSION.major).$(VERSION.minor).multiout")
        @test Infiltrator.store.foo.xxx == 1

        # imported globals
        run_terminal_test((t) -> Jmod.jfunc(), nothing,
                          ["x\n", "randstring\n", "@exit\n"],
                          "Julia_imported_globals_$(VERSION.major).$(VERSION.minor).multiout")

        run_terminal_test((t) -> globalref(Main, :undefvar), GlobalRef(Main, :undefvar),
                           ["gr\n", "@exit\n"],
                           "Julia_globalref_$(VERSION.major).$(VERSION.minor).multiout")

        # safehouse should not shadow local variables
        run_terminal_test((t) -> multiexfiltrate(), nothing,
                          ["i\n", "@continue\n", "i\n", "@exfiltrate\n", "@continue\n", "i\n", "safehouse.i\n", "@continue\n", "@exit\n"],
                          "Julia_multi_exfiltrate_$(VERSION.major).$(VERSION.minor).multiout")
        @test Infiltrator.store.i == 2

        # function-form infiltration
        run_terminal_test((t) -> function_form_infiltration(2), nothing,
                          ["x\n", "@exit\n"],
                          "Julia_function_inf_$(VERSION.major).$(VERSION.minor).multiout")

        # test Core.Compiler
        @static if VERSION >= v"1.8"
            @eval Core.Compiler __foo(x) = Main.Infiltrator.@infiltrate
            run_terminal_test((t) -> Core.Compiler.__foo(Core.SSAValue(3)), nothing,
                            ["x\n", "@exfiltrate\n", "@exit\n"],
                            "Julia_compiler_$(VERSION.major).$(VERSION.minor).multiout")
            @test Infiltrator.store.x == Core.SSAValue(3)
        end

        # anonymous modules
        run_terminal_test((t) -> anon(), nothing,
                          ["aas\t\t\n", "@exfiltrate aasdf\n", "@exit\n"],
                          "Julia_anon_$(VERSION.major).$(VERSION.minor).multiout")
        @test Infiltrator.store.aasdf == 3

        # anonymous modules
        run_terminal_test((t) -> cond(t), nothing,
                          ["@continue\n", "@continue\n", "@cond i > 6\n", "@continue\n", "i\n", "@exit\n"],
                          "Julia_cond_$(VERSION.major).$(VERSION.minor).multiout")

        # @infiltry
        println("inflitry")
        run_terminal_test((t) -> try; infiltry(0); catch; nothing; end, nothing,
                            ["@exception\n", "@locals\n", "@exit\n"],
                            "Julia_infiltry_$(VERSION.major).$(VERSION.minor).multiout")
    else
        @warn "Skipping UI tests on non unix systems"
    end
end

@testset "exfiltration tests" begin
    Infiltrator.clear_store!()
    function foo_ex(x)
        y = 3
        foo = :asd
        store = 33
        bar = function (yy) yy end
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
end

@testset "infiltry allows assignments" begin
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