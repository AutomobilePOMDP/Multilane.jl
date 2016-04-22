module Multilane

import StatsBase: WeightVec

using POMDPs
import POMDPs: actions, discount, isterminal, iterator
import POMDPs: create_action, create_state, rand, reward
using GenerativeModels

import Iterators.product

import Base: ==, hash, length

# for visualization
using Interact

# package code goes here
export 
    PhysicalParam,
    CarState,
    MLState,
    MLAction,
    BehaviorModel,
    MLMDP,
    OriginalMDP,
    OriginalRewardModel,
    IDMMOBILModel,
    IDMParam,
    MOBILParam,
    CarNeighborhood,
    IDMMOBILBehavior

export
    get_adj_cars,
    get_idm_dv,
    get_mobil_lane_change,
    is_crash,
    visualize,
    display_sim


include("physical.jl")
include("MDP_types.jl")
include("crash.jl")
include("MDP.jl")
include("IDM.jl")
include("MOBIL.jl")
include("behavior.jl")
include("visualization.jl")

end # module