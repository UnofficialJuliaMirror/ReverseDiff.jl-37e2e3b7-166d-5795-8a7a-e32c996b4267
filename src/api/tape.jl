################
# AbstractTape #
################

abstract AbstractTape

Base.show(io::IO, t::AbstractTape) = print(io, typeof(t).name, "(", t.func, ")")

# Define a few different T<:AbstractTape types. All these types share the same structure,
# but feature different constructors and dispatch restrictions in downstream code.
for T in (:GradientTape, :JacobianTape, :HessianTape)
    _T = Symbol(string("_", T))
    @eval begin
        immutable $(T){F,I,O} <: AbstractTape
            func::F
            input::I
            output::O
            tape::RawTape
            # disable default outer constructor
            $(T)(func, input, output, tape) = new(func, input, output, tape)
        end

        # "private" convienence constructor
        $(_T){F,I,O}(func::F, input::I, output::O, tape::RawTape) = $(T){F,I,O}(func, input, output, tape)
    end
end

Base.length(t::AbstractTape) = length(t.tape)

forward_pass!(t::AbstractTape) = forward_pass!(t.tape)

reverse_pass!(t::AbstractTape) = reverse_pass!(t.tape)

function seeded_forward_pass!(t::AbstractTape, input)
    value!(t.input, input)
    forward_pass!(t)
    return nothing
end

function seeded_reverse_pass!(result, t::AbstractTape)
    seeded_reverse_pass!(result, t.output, t.input, t)
    return result
end

############
# Compiled #
############

immutable Compiled{T<:AbstractTape,F,I,O,FP,RP} <: AbstractTape
    record_type::Type{T}
    func::F
    input::I
    output::O
    forward_pass!::FP
    reverse_pass!::RP
end

typealias CompiledGradient{T<:GradientTape,F,I,O,FP,RP} Compiled{T,F,I,O,FP,RP}
typealias CompiledJacobian{T<:JacobianTape,F,I,O,FP,RP} Compiled{T,F,I,O,FP,RP}
typealias CompiledHessian{T<:HessianTape,F,I,O,FP,RP}   Compiled{T,F,I,O,FP,RP}

"""
    ReverseDiff.compile(t::AbstractTape)

Return a fully compiled representation of `t`. The type of this representation will be
`CompiledGradient`/`CompiledJacobian`/`CompiledHessian`, depending on the type of `t`. This
object can be passed to any API methods that accept `t`.

In many cases, compiling `t` can significantly speed up execution time. Note that the longer
the tape, the more time compilation may take. Very long tapes (i.e. when `length(t)` is on
the order of 10000 elements) can take a very long time to compile.
"""
function compile(t::AbstractTape)
    return Compiled(typeof(t), t.func, t.input, t.output,
                    eval(ReverseDiff, :(() -> $(generate_forward_code(t.tape)))),
                    eval(ReverseDiff, :(() -> $(generate_reverse_code(t.tape)))))
end

forward_pass!(ct::Compiled) = ct.forward_pass!()

reverse_pass!(ct::Compiled) = ct.reverse_pass!()

################
# GradientTape #
################

"""
    ReverseDiff.GradientTape(f, input, cfg::GradientConfig = GradientConfig(input))

Return a `GradientTape` instance containing a pre-recorded execution trace of `f` at the
given `input`.

This `GradientTape` can then be passed to `ReverseDiff.gradient!` to take
gradients of the execution trace with new `input` values.

See `ReverseDiff.gradient` for a description of acceptable types for `input`.
"""
function GradientTape(f, input, cfg::GradientConfig = GradientConfig(input))
    track!(cfg.input, input)
    tracked_ouput = f(cfg.input)
    return _GradientTape(f, cfg.input, tracked_ouput, cfg.tape)
end

function GradientTape(f, input::Tuple, cfg::GradientConfig = GradientConfig(input))
    for i in eachindex(cfg.input)
        track!(cfg.input[i], input[i])
    end
    tracked_output = f(cfg.input...)
    return _GradientTape(f, cfg.input, tracked_output, cfg.tape)
end

################
# JacobianTape #
################

"""
    ReverseDiff.JacobianTape(f, input, cfg::JacobianConfig = JacobianConfig(input))

Return a `JacobianTape` instance containing a pre-recorded execution trace of
`f` at the given `input`.

This `JacobianTape` can then be passed to `ReverseDiff.jacobian!` to take
Jacobians of the execution trace with new `input` values.

See `ReverseDiff.jacobian` for a description of acceptable types for `input`.
"""
function JacobianTape(f, input, cfg::JacobianConfig = JacobianConfig(input))
    track!(cfg.input, input)
    tracked_ouput = f(cfg.input)
    return _JacobianTape(f, cfg.input, tracked_ouput, cfg.tape)
end

function JacobianTape(f, input::Tuple, cfg::JacobianConfig = JacobianConfig(input))
    for i in eachindex(cfg.input)
        track!(cfg.input[i], input[i])
    end
    tracked_output = f(cfg.input...)
    return _JacobianTape(f, cfg.input, tracked_output, cfg.tape)
end

"""
    ReverseDiff.JacobianTape(f!, output, input, cfg::JacobianConfig = JacobianConfig(output, input))

Return a `JacobianTape` instance containing a pre-recorded execution trace of
`f` at the given `output` and `input`.

This `JacobianTape` can then be passed to `ReverseDiff.jacobian!` to take
Jacobians of the execution trace with new `input` values.

See `ReverseDiff.jacobian` for a description of acceptable types for `input`.
"""
function JacobianTape(f!, output, input, cfg::JacobianConfig = JacobianConfig(output, input))
    track!(cfg.output, output, cfg.tape)
    track!(cfg.input, input)
    f!(cfg.output, cfg.input)
    return _JacobianTape(f!, cfg.input, cfg.output, cfg.tape)
end

function JacobianTape(f!, output, input::Tuple, cfg::JacobianConfig = JacobianConfig(output, input))
    track!(cfg.output, output, cfg.tape)
    for i in eachindex(input)
        track!(cfg.input[i], input[i])
    end
    f!(cfg.output, cfg.input...)
    return _JacobianTape(f!, cfg.input, cfg.output, cfg.tape)
end

###############
# HessianTape #
###############

"""
    ReverseDiff.HessianTape(f, input, cfg::HessianConfig = HessianConfig(input))

Return a `HessianTape` instance containing a pre-recorded execution trace of
`f` at the given `input`.

This `HessianTape` can then be passed to `ReverseDiff.hessian!` to take
Hessians of the execution trace with new `input` values.

See `ReverseDiff.hessian` for a description of acceptable types for `input`.
"""
function HessianTape(f, input, cfg::HessianConfig = HessianConfig(input))
    gcfg = cfg.gradient_config
    jcfg = cfg.jacobian_config
    ht = _HessianTape(f, jcfg.input, similar(deriv(gcfg.input)), jcfg.tape)
    track!(ht.input, input)
    gt = GradientTape(f, ht.input, gcfg)
    seeded_reverse_pass!(ht.output, gt.output, gt.input, gt.tape)
    return ht
end
