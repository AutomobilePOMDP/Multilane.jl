using Multilane
using MCTS
using POMDPToolbox
using POMDPs
# using POMCP
using Missings
using DataFrames
using CSV
using POMCPOW

@everywhere using Missings
@everywhere using Multilane
@everywhere using POMDPToolbox

@show N = 5000
n_iters = 1000
max_time = Inf
max_depth = 40
val = SimpleSolver()
pp = PhysicalParam(4, lane_length=100.0)
lambda = 0.0
rmodel = SuccessReward(lambda=lambda)


alldata = DataFrame()

dpws = DPWSolver(depth=max_depth,
                 n_iterations=n_iters,
                 max_time=max_time,
                 exploration_constant=8.0,
                 k_state=4.5,
                 alpha_state=1/10.0,
                 enable_action_pw=false,
                 check_repeat_state=false,
                 estimate_value=RolloutEstimator(val)
                 # estimate_value=val
                )
dpws_x10 = deepcopy(dpws)
dpws_x10.n_iterations *= 10

function make_updater(cor, problem, k, rng_seed)
    wup = WeightUpdateParams(smoothing=0.0, wrong_lane_factor=0.05)
    if cor >= 1.0 || k == "meanmpc"
        return AggressivenessUpdater(problem, 2000, 0.05, 0.1, wup, MersenneTwister(rng_seed+50000))
    else
        return BehaviorParticleUpdater(problem, 5000, 0.0, 0.0, wup, MersenneTwister(rng_seed+50000))
    end
end

pow_updater(up::AggressivenessUpdater) = AggressivenessPOWFilter(up.params)
pow_updater(up::BehaviorParticleUpdater) = BehaviorPOWFilter(up.params)


solvers = Dict{String, Solver}(
    "omniscient" => dpws,
    "qmdp" => QBSolver(dpws),
    "pomcpow" => POMCPOWSolver(tree_queries=n_iters,
                               criterion=MaxUCB(8.0),
                               max_depth=max_depth,
                               max_time=max_time,
                               enable_action_pw=false,
                               k_observation=4.5,
                               alpha_observation=1/10.0,
                               estimate_value=FORollout(val),
                               check_repeat_obs=false,
                              ),
    "outcome" => OutcomeSolver(dpws)
)

planners = Dict{Pair{String, Float64}, Any}(("omniscient"=>NaN)=>nothing) # maps to planner => updater pairs 


for sname in ["pomcpow", "qmdp", "outcome"]
    for planner_cor in [0.0, 1.0]
        @show sname => planner_cor
        planner_behaviors = standard_uniform(correlation=planner_cor)
        planner_dmodel = NoCrashIDMMOBILModel(10, pp,
                                          behaviors=planner_behaviors,
                                          p_appear=1.0,
                                          lane_terminate=true,
                                          max_dist=1000.0,
                                          brake_terminate_thresh=4.0,
                                          speed_terminate_thresh=15.0
                                         )

        planner_pomdp = NoCrashPOMDP{typeof(rmodel), typeof(planner_behaviors)}(planner_dmodel, rmodel, 0.95, false)
        planner_mdp = NoCrashMDP{typeof(rmodel), typeof(planner_behaviors)}(planner_dmodel, rmodel, 0.95, false)

        sol = solvers[sname]

        solver_problems = Dict{String, Any}(
            "qmdp"=>planner_mdp,
            "outcome"=>planner_mdp
        )

        updaters = Dict{String, Any}(
            "qmdp"=>make_updater(planner_cor, planner_pomdp, sname, 50000),
            "pomcpow"=>make_updater(planner_cor, planner_pomdp, sname, 50000),
            "outcome"=>nothing,
        )

        sp = get(solver_problems, sname, planner_pomdp)

        up = updaters[sname]
        if sname == "pomcpow"
            sol.node_sr_belief_updater = pow_updater(up)
        end

        planners[sname=>planner_cor] = (solve(sol, sp) => up)
    end
end


for cor in 0.0:0.2:1.0
# for cor in 1.0
    @show cor

    behaviors = standard_uniform(correlation=cor)
    dmodel = NoCrashIDMMOBILModel(10, pp,
                                  behaviors=behaviors,
                                  p_appear=1.0,
                                  lane_terminate=true,
                                  max_dist=1000.0,
                                  brake_terminate_thresh=4.0,
                                  speed_terminate_thresh=15.0
                                 )
    pomdp = NoCrashPOMDP{typeof(rmodel), typeof(behaviors)}(dmodel, rmodel, 0.95, false)
    mdp = NoCrashMDP{typeof(rmodel), typeof(behaviors)}(dmodel, rmodel, 0.95, false)

    problems = Dict{String, Any}(
        "baseline"=>mdp,
        "omniscient"=>mdp,
        "omniscient-x10"=>mdp,
        "outcome"=>mdp
    )

    for ((k, planner_cor),pup) in planners
        @show k
        @show planner_cor


        p = get(problems, k, pomdp)
        sim_problem = deepcopy(p)
        sim_problem.throw=true

        if pup == nothing
            planner = solve(solvers[k], p)
        else
            (planner, up) = pup
        end

        sims = []

        for i in 1:N
            rng_seed = i+40000
            rng = MersenneTwister(rng_seed)
            is = initial_state(p, rng)
            ips = MLPhysicalState(is)

            metadata = Dict(:rng_seed=>rng_seed,
                            :lambda=>lambda,
                            :solver=>k,
                            :dt=>pp.dt,
                            :cor=>cor,
                            :planner_cor=>planner_cor
                       )   
            hr = HistoryRecorder(max_steps=100, rng=rng, capture_exception=false)

            if sim_problem isa POMDP
                srand(planner, rng_seed+80000)
                push!(sims, Sim(sim_problem, planner, up, ips, is,
                                simulator=hr,
                                metadata=metadata
                               ))
            else
                push!(sims, Sim(sim_problem, planner, is,
                                simulator=hr,
                                metadata=metadata
                               ))
            end
            @assert problem(last(sims)).throw
        end

        # data = run(sims) do sim, hist
        data = run_parallel(sims) do sim, hist

            if nothing === (exception(hist))
                p = problem(sim)
                steps_in_lane = 0
                steps_to_lane = missing
                nb_brakes = 0
                crashed = false
                min_speed = Inf
                min_ego_speed = Inf
                for (k,(s,sp)) in enumerate(eachstep(hist, "s,sp"))

                    nb_brakes += detect_braking(p, s, sp)

                    if sp.cars[1].y == p.rmodel.target_lane
                        steps_in_lane += 1
                    end
                    if sp.cars[1].y == p.rmodel.target_lane
                        if ismissing(steps_to_lane)
                            steps_to_lane = k
                        end
                    end

                    if is_crash(p, s, sp)
                        crashed = true
                    end

                    min_speed = min(minimum(c.vel for c in sp.cars), min_speed)
                    min_ego_speed = min(min_ego_speed, sp.cars[1].vel)
                end
                time_to_lane = steps_to_lane*p.dmodel.phys_param.dt
                distance = last(state_hist(hist)).x

                return [:n_steps=>n_steps(hist),
                        :mean_iterations=>mean(ai[:tree_queries] for ai in eachstep(hist, "ai")),
                        :mean_search_time=>1e-6*mean(ai[:search_time_us] for ai in eachstep(hist, "ai")),
                        :reward=>discounted_reward(hist),
                        :crashed=>crashed,
                        :steps_to_lane=>steps_to_lane,
                        :steps_in_lane=>steps_in_lane,
                        :nb_brakes=>nb_brakes,
                        :exception=>false,
                        :distance=>distance,
                        :mean_ego_speed=>distance/(n_steps(hist)*p.dmodel.phys_param.dt),
                        :min_speed=>min_speed,
                        :min_ego_speed=>min_ego_speed,
                        :terminal=>string(last(state_hist(hist).terminal, missing))
                       ]
            else
                warn("Error in Simulation")
                showerror(STDERR, exception(hist))
                # show(STDERR, MIME("text/plain"), stacktrace(backtrace(hist)))
                return [:exception=>true,
                        :ex_type=>string(typeof(exception(hist)))
                       ]
            end
        end

        success = 100.0*sum(data[:terminal].=="lane")/N
        brakes = 100.0*sum(data[:nb_brakes].>=1)/N
        @printf("%% reaching:%5.1f; %% braking:%5.1f\n", success, brakes)

        @show extrema(data[:distance])
        @show mean(data[:mean_iterations])
        @show mean(data[:mean_search_time])
        @show mean(data[:reward])
        if minimum(data[:min_speed]) < 15.0
            @show minimum(data[:min_speed])
        end

        if isempty(alldata)
            alldata = data
        else
            alldata = vcat(alldata, data)
        end
    end
    
end

# @show alldata

datestring = Dates.format(now(), "E_d_u_HH_MM")
filename = Pkg.dir("Multilane", "data", "cor_rob_"*datestring*".csv")
println("Writing data to $filename")
CSV.write(filename, alldata)
