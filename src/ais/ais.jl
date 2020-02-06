using Gen

#######
# AIS #
#######

"""

    (lml_est, trace, weights) = ais(
        model::GenerativeFunction, constraints::ChoiceMap,
        args_seq::Vector{Tuple}, argdiffs::Tuple,
        mh_kernel::Function)

Run annealed importance sampling, returning the log marginal likelihood estimate (`lml_est`).
"""
function ais(
        model::GenerativeFunction, args::Tuple, constraints::ChoiceMap,
        args_seq::Vector{<:Tuple}, argdiffs::Tuple,
        mh_kernel::Function)

    # run forward AIS
    weights = Float64[]
    lml_est = 0.
    trace, weight = generate(model, args_seq[1], constraints)
    lml_est += weight
    push!(weights, weight)
    for intermediate_args in args_seq[2:end]
        trace = mh_kernel(trace)
        (trace, weight, _, _) = update(trace, intermediate_args, argdiffs, choicemap())
        lml_est += weight
        push!(weights, weight)
    end
    trace = mh_kernel(trace)
    (trace, weight, _, _) = update(
        trace, args, argdiffs, choicemap())
    lml_est += weight
    push!(weights, weight)

    # do mh at the very end
    trace = mh_kernel(trace)

    (lml_est, trace, weights)
end



######################################
# AIS generative function combinator #
######################################

# (for doing inference conditioned on existing values in a trace)

function combinator_reverse_ais(
        model::GenerativeFunction, args::Tuple, combined_constraints::ChoiceMap,
        args_seq::Vector, argdiffs::Tuple,
        mh_fwd::Function, mh_rev::Function,
        output_addrs::Selection)

    # construct final model trace from the output choices (constraints) and all
    # the fixed choices
    #fixed_addrs = ComplementSelection(output_addrs)
    #fixed_choices = get_selected(get_choices(model_trace), fixed_addrs)
    (trace, should_be_score) = generate(model, args, combined_constraints)
    init_score = get_score(trace)
    @assert isapprox(should_be_score, init_score) # check its deterministic
    ais_score = init_score

    # do mh at the very beginning
    trace = mh_rev(trace)

    # run backward AIS
    lml_est = 0.
    weights = Float64[]
    for model_args in reverse(args_seq)
        (trace, weight, _, _) = update(trace, model_args, argdiffs, choicemap())
        if isnan(weight)
            error("NaN weight")
        end
        ais_score += weight # we are adding because the weights are the reciprocal of the forward weight
        lml_est -= weight
        push!(weights, -weight)
        trace = mh_rev(trace)
    end

    # get pi_1(z_0) / q(z_0) -- the weight that would be returned by the initial 'generate' call
    # select the addresses that would be constrained by the call to generate inside to AIS.simulate()
    @assert get_args(trace) == args_seq[1]
    score_from_project = project(trace, ComplementSelection(output_addrs))
    ais_score -= score_from_project
    lml_est += score_from_project
    push!(weights, score_from_project)
    if isnan(score_from_project)
        error("NaN score_from_project")
    end

    (lml_est, ais_score, reverse(weights))
end

struct AISTrace <: Gen.Trace
    gen_fn::GenerativeFunction
    args::Tuple
    score::Float64
    choices::ChoiceMap
    weights::Vector{Float64}
end

Gen.get_gen_fn(trace::AISTrace) = trace.gen_fn
Gen.get_args(trace::AISTrace) = trace.args
Gen.get_retval(trace::AISTrace) = trace.weights
Gen.get_choices(trace::AISTrace) = trace.choices
Gen.get_score(trace::AISTrace) = trace.score

struct AISGF <: GenerativeFunction{Vector{Float64},AISTrace} end

function Gen.simulate(gen_fn::AISGF, args::Tuple)
    (model::GenerativeFunction, model_args::Tuple, model_constraints::ChoiceMap,
    args_seq::Vector{<:Tuple}, argdiffs::Tuple,
    mh_fwd::Function, mh_rev::Function, output_addrs::Selection) = args

    # everything except the output addrs
    #fixed_addrs = ComplementSelection(output_addrs)
    #constraints = get_selected(get_choices(model_trace), fixed_addrs)

    (lml_est, trace, weights) = ais(
        model, model_args, model_constraints,
        args_seq, argdiffs,
        mh_fwd) 

    ais_score = get_score(trace) - lml_est
    output = get_selected(get_choices(trace), output_addrs)
    AISTrace(gen_fn, args, ais_score, output, weights)
end

function Gen.generate(gen_fn::AISGF, args::Tuple, constraints::ChoiceMap)
    (model::GenerativeFunction, model_args::Tuple, model_constraints::ChoiceMap,
    args_seq::Vector{<:Tuple}, argdiffs::Tuple,
    mh_fwd::Function, mh_rev::Function, output_addrs::Selection) = args

    combined_choices = merge(model_constraints, constraints)

    (_, ais_score, weights) = combinator_reverse_ais(
        model, model_args, combined_choices,
        args_seq, argdiffs, 
        mh_fwd, mh_rev, output_addrs)

    trace = AISTrace(gen_fn, args, ais_score, constraints, weights)
    (trace, ais_score)
end

#####################
# MH move using AIS #
#####################

function make_ais_mh_move(output_addrs, mh_fwd, mh_rev, args_seq, argdiffs)

    gf = AISGF()

    @gen function ais_proposal(trace)
        constraints = get_selected(get_choices(trace), ComplementSelection(output_addrs))
        @trace(gf(get_gen_fn(trace), get_args(trace), constraints, args_seq, argdiffs, mh_fwd, mh_rev), :ais)
    end

    function involution(trace, fwd_choices, fwd_ret, fwd_args)
        ais_choices = get_selected(get_choices(trace), output_addrs)
        bwd_choices = choicemap()
        set_submap!(bwd_choices, :ais, ais_choices)

        constraints = get_submap(fwd_choices, :ais)
        args = get_args(trace)
        argdiffs = map((_) -> NoChange(), args)
        new_trace, weight = update(trace, args, argdiffs, constraints)

        (new_trace, bwd_choices, weight + 0.)
    end

    function ais_move(trace; check_round_trip=false)
        mh(trace, ais_proposal, (), involution, check_round_trip=check_round_trip)
    end

    ais_move
end

export AISGF, ais, reverse_ais, make_ais_mh_move
