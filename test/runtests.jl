using Test

include(joinpath(@__DIR__, "..", "src", "main", "PowerSystemExtractor.jl"))

@test isdefined(Main, :PowerSystemExtractor)
