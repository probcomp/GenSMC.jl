import Random

function test_sir_mle()

    @gen function foo()
        local z
        z = @trace(bernoulli(0.2), :z)
        x = @trace(bernoulli(z ? 0.9 : 0.1), :x)
    end

    x = true

    # p(x = 1)
    lml = log(0.2 * 0.9 + 0.8 * 0.1)

    # selection_sir()
    trace, = generate(foo, (), choicemap((:x, true)))
    Random.seed!(1)
    @time (actual, _, _) = selection_sir(trace, select(:z), Int(1e5))
    expected = lml
    @test isapprox(actual, expected, atol=1e-2)

    # test the combinator
    output_addrs = select(:z)

    # get_score(selection_sir_trace), as generated by simulate()
    @time selection_sir_trace = simulate(selection_sir_gf, (trace, select(:z), 1e5))
    z = selection_sir_trace[:z]
    model_trace, = generate(foo, (), choicemap((:z, z), (:x, x)))
    actual = get_score(selection_sir_trace)
    expected = get_score(model_trace) - lml
    @test isapprox(actual, expected, atol=1e-2)

    # get_score(selection_sir_trace), as generated by generate()
    z = false
    @time selection_sir_trace, = generate(
        selection_sir_gf, (trace, select(:z), 1e5), choicemap((:z, z)))
    actual = get_score(selection_sir_trace)
    model_trace, = generate(foo, (), choicemap((:z, z), (:x, x)))
    expected = get_score(model_trace) - lml
    @test isapprox(actual, expected, atol=1e-2)

end

function test_selection_sir_mh()

    # smoke test
    @gen function foo()
        local z
        z = @trace(bernoulli(0.2), :z)
        x = @trace(bernoulli(z ? 0.9 : 0.1), :x)
    end

    Random.seed!(1)
    trace, = generate(foo, (), choicemap((:x, true)))
    new_trace, acc = selection_sir_mh(trace, select(:z), Int(1e5))
    @test acc
end

@testset "SIR" begin
    test_sir_mle()
    test_selection_sir_mh()
end
