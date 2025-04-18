module RegisterOptimize

import MathOptInterface as MOI
using JuMP: JuMP, Model, optimizer_with_attributes, @variable, @objective, @operator, @constraint, termination_status, LOCALLY_SOLVED
using Ipopt, Optim, Interpolations, ForwardDiff, StaticArrays, IterativeSolvers, ProgressMeter
using RegisterCore, RegisterDeformation, RegisterPenalty, RegisterFit, CachedInterpolations, CenterIndexedArrays
using Printf, LinearAlgebra, Statistics, CoordinateTransformations
using RegisterDeformation: convert_to_fixed, convert_from_fixed
using Base: tail

import Base: *

export
    auto_λ,
    auto_λt,
    fit_sigmoid,
    fixed_λ,
    initial_deformation

"""
This module provides convenience functions for minimizing the mismatch
between images. It supports both rigid registration and deformable
registration.

The main functions are:

- `optimize_rigid`: iteratively improve a rigid transformation, given raw images
- `rotation_gridsearch`: brute-force search a grid of possible rotations and shifts to align raw images
- `qd_rigid`: find a rotation and shift to align raw images using the QuadDIRECT algorithm
- `initial_deformation`: provide an initial guess based on mismatch quadratic fits
- `RegisterOptimize.optimize!`: iteratively improve a deformation, given mismatch data
- `fixed_λ` and `auto_λ`: "complete" optimizers that generate initial guesses and then find the minimum
"""
RegisterOptimize


# Some conveniences for MOI
abstract type GradOnly <: MOI.AbstractNLPEvaluator end

function MOI.initialize(d::GradOnly, requested_features::Vector{Symbol})
    for feat in requested_features
        if !(feat in [:Grad, :Jac])
            error("Unsupported feature $feat")
        end
    end
end
MOI.features_available(d::GradOnly) = [:Grad, :Jac]


abstract type GradOnlyBoundsOnly <: GradOnly end

MOI.eval_objective_gradient(::GradOnlyBoundsOnly, g, x) = nothing
MOI.jacobian_structure(::GradOnlyBoundsOnly) = Int[], Int[]
MOI.eval_constraint_jacobian(::GradOnlyBoundsOnly, J, x) = nothing


abstract type BoundsOnly <: MOI.AbstractNLPEvaluator end

MOI.eval_objective_gradient(::BoundsOnly, g, x) = nothing
MOI.jacobian_structure(::BoundsOnly) = Int[], Int[]
MOI.eval_constraint_jacobian(::BoundsOnly, J, x) = nothing


###
### Rigid registration from raw images
###
"""
`tform = optimize_rigid(fixed, moving, tform0, maxshift, [SD = eye];
[thresh=0, tol=1e-4, print_level=0])` optimizes a rigid transformation
(rotation + shift) to minimize the mismatch between `fixed` and
`moving`.

`tform0` is an initial guess.  Use `SD` if your axes are not uniformly
sampled, for example `SD = diagm(voxelspacing)` where `voxelspacing`
is a vector encoding the spacing along all axes of the image. `thresh`
enforces a certain amount of sum-of-squared-intensity overlap between
the two images; with non-zero `thresh`, it is not permissible to
"align" the images by shifting one entirely out of the way of the
other.
"""
function optimize_rigid(fixed, moving, A::AffineMap, maxshift,
                SD = Matrix{Float64}(I,size(A.linear,1),size(A.linear,1)),
                maxrot=pi; thresh=0, tol=1e-4, print_level=0, max_iter=3000)
    objective = RigidOpt(to_float(fixed, moving)..., SD, thresh)
    # Convert initial guess into parameter vector
    R = SD*A.linear/SD
    rotp = rotationparameters(R)
    dx = A.translation
    p0 = [rotp; dx]
    T = eltype(p0)

    # Set up and run the solver
    model = Model(optimizer_with_attributes(Ipopt.Optimizer,
                                            "hessian_approximation" => "limited-memory",
                                             "print_level" => print_level,
                                             "tol" => tol,
                                             "max_iter" => max_iter,
                                             "sb" => "yes"))

    # ub = T[fill(maxrot, length(p0)-length(maxshift)); [maxshift...]]
    # MOI.loadproblem!(model, length(p0), 0, -ub, ub, T[], T[], :Min, objective)
    # MOI.setwarmstart!(model, p0)
    # MOI.optimize!(model)

    # stat = MOI.status(model)
    # stat == :Optimal || @warn("Solution was not optimal")
    # p = MOI.getsolution(model)
    # fval = MOI.getobjval(model)

    N = length(p0)
    ub = T[fill(maxrot, N-length(maxshift)); [maxshift...]]
    @variable(model, -ub[i] <= x[i in 1:N] <= ub[i], start = p0[i])
    @operator(model, op_objective, N, (x...) -> MOI.eval_objective(objective, collect(x)),
                            (g, x...) -> MOI.eval_objective_gradient(objective, g, collect(x)))
    @objective(model, Min, op_objective(x...))
    fval0 =  MOI.eval_objective(objective, p0)
    isfinite(fval0) || error("Initial value must be finite")
    JuMP.optimize!(model)

    stat = termination_status(model)
    stat == LOCALLY_SOLVED || @warn("Solution was not optimal")
    p = JuMP.value.(x)
    fval = JuMP.objective_value(model)

    p2rigid(p, SD), fval
end

"""
`rotations = grid_rotations(maxradians, rgridsz, SD)` generates
a set of rotations (AffineMap) useful for a gridsearch of
possible rotations to align a pair of images.

`maxradians` is either a single maximum angle (in 2D) or a set of
Euler angles (in 3D and higher). `rgridsz` is one or more integers
specifying the number of gridpoints to search in each of the rotation
axes, corresponding with entries in `maxradians`. `SD` is a matrix
specifying the sample spacing.

e.g. `grid_rotations((pi/8,pi/8,pi/8), (3,3,3), Matrix{Float64}(I,3,3))` would
return an array of 27 rotations with 3 possible angles for each
Euler axis: -pi/8, 0, pi/8. Passing `Matrix{Float64}(I,3,3)` for SD indicates
that the resulting  transforms are meant to be applied to an image with isotropic
pixel spacing.
"""
function grid_rotations(maxradians, rgridsz, SD)
    rgridsz = [rgridsz...]
    maxradians = [maxradians...]
    nd = size(SD,1)
    if !all(isodd, rgridsz)
        @warn("rgridsz should be odd; rounding up to the next odd integer")
    end
    for i = 1:length(rgridsz)
        if !isodd(rgridsz[i])
            rgridsz[i] = max(round(Int, rgridsz[i]) + 1, 1)
        end
    end
    grid_radius = map(x->div(x,2), rgridsz)
    if nd > 2
        gridcoords = [range(-grid_radius[x]*maxradians[x], stop=grid_radius[x]*maxradians[x], length=rgridsz[x]) for x=1:nd]
        rotation_angles = Iterators.product(gridcoords...)
    else
        rotation_angles = range(-grid_radius[1]*maxradians[1], stop=grid_radius[1]*maxradians[1], length=rgridsz[1])
    end
    axmat = Matrix{Float64}(I,nd,nd)
    axs = map(x->axmat[:,x], 1:nd)
    tfeye = tformeye(nd)
    output = typeof(tfeye)[]
    for ra in rotation_angles
        if nd > 2
            euler_rots = map(x->tformrotate(x...), zip(axs, ra))
            rot = foldr(∘, euler_rots; init=tfeye)
        elseif nd == 2
            rot = tformrotate(ra)
        else
            error("Unsupported dimensionality")
        end
        push!(output, AffineMap(SD*rot.linear/SD , zeros(nd))) #account for sample spacing
    end
    return output
end

"""
`best_tform, best_mm = rotation_gridsearch(fixed, moving, maxshift, maxradians, rgridsz, SD =Matrix{Float64}(I,ndims(fixed),ndims(fixed))))`
Tries a grid of rotations to align `moving` to `fixed`.  Also calculates the best translation (`maxshift` pixels
or less) to align the images after performing the rotation. Returns an AffineMap that captures both the
best rotation and shift out of the values searched, along with the mismatch value after applying that transform (`best_mm`).

For more on how the arguments `maxradians`, `rgridsz`, and `SD` influence the search, see the documentation for
`grid_rotations`.
"""
function rotation_gridsearch(fixed, moving, maxshift, maxradians, rgridsz, SD = Matrix{Float64}(I,ndims(fixed),ndims(fixed)))
    rgridsz = [rgridsz...]
    nd = ndims(moving)
    @assert nd == ndims(fixed)
    rots = grid_rotations(maxradians, rgridsz, SD)
    best_mm = Inf
    best_rot = tformeye(ndims(moving))
    best_shift = zeros(nd)
    for rot in rots
        new_moving = transform(moving, rot)
        #calc mismatch
        #mm = mismatch(fixed, new_moving, maxshift; normalization=:pixels)
        mm = mismatch(fixed, new_moving, maxshift)
        thresh = 0.1*maximum(x->x.denom, mm)
        best_i = indmin_mismatch(mm, thresh)
        cur_best =ratio(mm[best_i], 0.0)
        if cur_best < best_mm
            best_mm = cur_best
            best_rot = rot
            best_shift = [best_i.I...]
        end
    end
    return tformtranslate(best_shift) ∘ best_rot, best_mm
end

function p2rigid(p, SD)
    if length(p) == 1
        return AffineMap([1], p)  # 1 dimension
    elseif length(p) == 3
        return AffineMap(SD\(rotation2(p[1])*SD), p[2:end])    # 2 dimensions
    elseif length(p) == 6
        return AffineMap(SD\(rotation3(p[1:3])*SD), p[4:end])  # 3 dimensions
    else
        error("Dimensionality not supported")
    end
end

to_float(A, B) = to_float(typeof(oneunit(eltype(A)) - oneunit(eltype(B))), A, B)
to_float(::Type{T}, A, B) where {T<:AbstractFloat} = convert(Array{T}, A), convert(Array{T}, B)
to_float(::Type{T}, A, B) where {T} = convert(Array{Float32}, A), convert(Array{Float32}, B)


###
### Rigid registration from raw images, MathProg interface
###
mutable struct RigidValue{N,A<:AbstractArray,I<:AbstractExtrapolation,SDT} <: MOI.AbstractNLPEvaluator
    fixed::A
    wfixed::A
    moving::I
    SD::SDT
    thresh
end

function RigidValue(fixed::AbstractArray, moving::AbstractArray{T}, SD, thresh) where T<:Real
    f = copy(fixed)
    fnan = isnan.(f)
    f[fnan] .= 0
    m = copy(moving)
    mnan = isnan.(m)
    m[mnan] .= 0
    metp = extrapolate(interpolate!(m, BSpline(Quadratic(InPlace(OnCell())))), NaN)
    RigidValue{ndims(f),typeof(f),typeof(metp),typeof(SD)}(f, map(!, fnan), metp, SD, thresh)
end

function (d::RigidValue)(x)
    tfm = p2rigid(x, d.SD)
    mov = transform(d.moving, tfm)
    movnan = isnan.(mov)
    mov[movnan] .= 0
    f = d.fixed.*map(!, movnan)
    m = mov.*d.wfixed
    den = sum(abs2, f) + sum(abs2, m)
    real(den) < d.thresh && return convert(typeof(den), Inf)
    sum(abs2, f-m)/den
end

mutable struct RigidOpt{RV<:RigidValue,G} <: GradOnlyBoundsOnly
    rv::RV
    g::G
end

function RigidOpt(fixed, moving, SD, thresh)
    rv = RigidValue(fixed, moving, SD, thresh)
    g = x->ForwardDiff.gradient(rv, x)
    RigidOpt(rv, g)
end

MOI.eval_objective(d::RigidOpt, x) = d.rv(x)
MOI.eval_objective_gradient(d::RigidOpt, grad_f, x) =
    copyto!(grad_f, d.g(x))

###
### Globally-optimal initial guess for deformation given
### quadratic-fit mismatch data
###
"""
`u0, converged = initial_deformation(ap::AffinePenalty, cs, Qs;
[ϕ_old=identity])` prepares a globally-optimal initial guess for a
deformation, given a quadratic fit to the aperture-wise mismatch
data. `cs` and `Qs` must be arrays-of-arrays in the shape of the
u0-grid, each entry as calculated by `qfit`. The initial guess
minimizes the function

```
    ap(ϕ(u0)) + ∑_i (u0[i]-cs[i])' * Qs[i] * (u0[i]-cs[i])
```
where `ϕ(u0)` is the deformation associated with `u0`.

If `ϕ_old` is not the identity, it must be interpolating.
"""
function initial_deformation(ap::AffinePenalty, cs, Qs)
    _initial_deformation(ap, cs, Qs)
end

function _initial_deformation(ap::AffinePenalty{T,N}, cs, Qs) where {T,N}
    if ap.λ <= 0
        return cs2u(SVector{N,T}, cs), true
    end
    b = prep_b(T, cs, Qs)
    # A = to_full(ap, Qs)
    # F = svdfact(A)
    # S = F[:S]
    # smax = maximum(S)
    # fac = sqrt(eps(typeof(smax)))
    # for i = 1:length(S)
    #     if S[i] < fac*smax
    #         S[i] = Inf
    #     end
    # end
    # x, isconverged = F\b, true
    # In case the grid is really big, solve iteratively
    # (The matrix is not sparse, but matrix-vector products can be
    # computed efficiently.)
    P = AffineQHessian(ap, Qs, identity)
    x, isconverged = find_opt(P, b)
    if all(el->el==0, b)
        # Work around https://github.com/JuliaMath/IterativeSolvers.jl/pull/110
        fill!(x, 0)
        isconverged = true
    end
    Array(convert_to_fixed(SVector{N,T}, x, size(cs))), isconverged
end

cs2u(::Type{V}, cs) where {V} = V[V((c...,)) for c in cs]

function initial_deformation(ap::AffinePenalty{T,N}, cs::AbstractArray{V}, Qs::AbstractArray{M}) where {T,N,V<:SVector,M<:SMatrix}
    Tv = eltype(V)
    eltype(M) == Tv || error("element types of cs ($(eltype(V))) and Qs ($(eltype(M))) must match")
    size(M,1) == size(M,2) == length(V) || throw(DimensionMismatch("size $(size(M)) of Qs matrices is inconsistent with cs vectors of size $(size(V))"))
    _initial_deformation(convert(AffinePenalty{Tv,N}, ap), cs, Qs)
end

function to_full(ap::AffinePenalty{T,N}, Qs) where {T,N}
    FF = ap.F*ap.F'
    nA = N*size(FF,1)
    FFN = zeros(nA,nA)
    for o = 1:N
        FFN[o:N:end,o:N:end] = FF
    end
    A = ap.λ*(I - FFN)
    for i = 1:length(Qs)
        A[N*(i-1)+1:N*i, N*(i-1)+1:N*i] += Qs[i]
    end
    A
end

function prep_b(::Type{T}, cs, Qs) where T
    n = prod(size(Qs))
    N = length(first(cs))::Int
    b = zeros(T, N*n)
    for i = 1:n
        _copy!(b, (i-1)*N+1:i*N, Qs[i]*cs[i])
    end
    b
end

# Overloading setindex! for Vec introduces too many ambiguities,
# so we define this instead.
_copy!(dest, rng, src::AbstractVector) = dest[rng] = src
function _copy!(dest, rng, src::SVector)
    for (idest, s) in zip(rng, src)
        dest[idest] = s
    end
    src
end

function find_opt(P, b)
    x = cg(P, b; maxiter=length(b))
    x, true
end

# A type for computing multiplication by the linear operator
mutable struct AffineQHessian{AP<:AffinePenalty,M<:StaticMatrix,N,Φ}
    ap::AP
    Qs::Array{M,N}
    ϕ_old::Φ
end

function AffineQHessian(ap::AffinePenalty{T}, Qs::AbstractArray{TQ,N}, ϕ_old) where {T,TQ,N}
    AffineQHessian{typeof(ap),similar_type(SArray,T,Size(N,N)),N,typeof(ϕ_old)}(ap, Qs, ϕ_old)
end

Base.eltype(::Type{AffineQHessian{AP,M,N,Φ}}) where {AP,M,N,Φ} = eltype(AP)
Base.eltype(P::AffineQHessian) = eltype(typeof(P))
Base.size(P::AffineQHessian, d) = length(P.Qs)*size(first(P.Qs),1)

# These compute the gradient of (x'*P*x)/2, where P is the Hessian
# for the objective in the doc text for initial_deformation.
function (*)(P::AffineQHessian{AffinePenalty{T,N}}, x::AbstractVector{T}) where {T,N}
    u = convert_to_fixed(SVector{N,T}, x, size(P.Qs))
    g = similar(u)
    _mul!(g, P, u)
    reshape(reinterpret(T, vec(g)), size(x))
end

function LinearAlgebra.mul!(dest::AbstractVector{T},
                              P::AffineQHessian{AffinePenalty{T,N}},
                              x::AbstractVector{T}) where {T,N}
    u = convert_to_fixed(SVector{N,T}, x, size(P.Qs))
    g = convert_to_fixed(SVector{N,T}, dest, size(P.Qs))
    _mul!(g, P, u)
    dest
end

function _mul!(g, P::AffineQHessian{AffinePenalty{T,N}}, u) where {T,N}
    gridsize = size(P.Qs)
    λ = P.ap.λ
    nspatialgrid = size(P.ap.F, 1)
    P.ap.λ = λ*nspatialgrid/2   # undo the scaling in penalty!
    affine_part!(g, P, u)
    P.ap.λ = λ
    sumQ = zero(T)
    for i = 1:length(u)
        g[i] += P.Qs[i] * u[i]
        sumQ += tr(P.Qs[i])
    end
    # Add a stabilizing diagonal, for cases where λ is very small
    if sumQ == 0
        sumQ = one(T)
    end
    fac = cbrt(eps(T))*sumQ/length(u)
    for i = 1:length(u)
        g[i] += fac*u[i]
    end
    g
end

affine_part!(g, P, u) = _affine_part!(g, P.ap, u)
function _affine_part!(g, ap::AffinePenalty{T,N}, u) where {T,N}
    local s
    if ndims(u) == N
        s = penalty!(g, ap, u)
    elseif ndims(u) == N+1
        # Last dimension is time
        n = size(u)[end]
        colons = ntuple(ColonFun, Val(N))
        for i = 1:n
            indexes = (colons..., i)
            snew = penalty!(view(g, indexes...), ap, view(u, indexes...))
            if i == 1
                s = snew
            else
                s += snew
            end
        end
    else
        throw(DimensionMismatch("unknown dimensionality $(ndims(u)) for $N dimensions"))
    end
    s
end

function initial_deformation(ap::AffinePenalty{T,N}, cs, Qs, ϕ_old, maxshift) where {T,N}
    error("This is broken, don't use it")
    b = prep_b(T, cs, Qs)
    # In case the grid is really big, solve iteratively
    # (The matrix is not sparse, but matrix-vector products can be
    # computed efficiently.)
    P0 = AffineQHessian(ap, Qs, identity)
    x0 = find_opt(P0, b)
    P = AffineQHessian(ap, Qs, ϕ_old)
    x = find_opt(P, b, maxshift, x0)
    u0 = convert_to_fixed(x, (N,size(cs)...)) #reinterpret(SVector{N,eltype(x)}, x, size(cs))
end

# type for minimization with composition (which turns the problem into
# a nonlinear problem)
mutable struct InitialDefOpt{AQH,B} <: GradOnlyBoundsOnly
    P::AQH
    b::B
end

function find_opt(P::AffineQHessian{AP,M,N,Φ}, b, maxshift, x0) where {AP,M,N,Φ<:GridDeformation}
    objective = InitialDefOpt(P, b)
#=
    solver = IpoptSolver(hessian_approximation="limited-memory",
                         print_level=0,
                         sb="yes")
    m = MOI.NonlinearModel(solver)
    T = eltype(b)
    n = length(b)
    ub1 = T[maxshift...] - T(RegisterFit.register_half)
    ub = repeat(ub1, outer=[div(n, length(maxshift))])
    MOI.loadproblem!(m, n, 0, -ub, ub, T[], T[], :Min, objective)
    MOI.setwarmstart!(m, x0)
    MOI.optimize!(m)
    stat = MOI.status(m)
    stat == :Optimal || @warn("Solution was not optimal")
    MOI.getsolution(m)
=#
    T = eltype(b)
    n = length(b)

    model = Model(optimizer_with_attributes(Ipopt.Optimizer,
                                            "hessian_approximation"=>"limited-memory",
                                            "print_level" => 0,
                                            "sb" => "yes"))
    ub1 = T[maxshift...] .- T(RegisterFit.register_half)
    ub = repeat(ub1, outer=[div(n, length(maxshift))])
    @variable(model, -ub[i] <= x[i in 1:n] <= ub[i], start = x0[i])
    @operator(model, op_objective, n, (x...) -> MOI.eval_objective(objective, collect(x)),
                            (g, x...) -> MOI.eval_objective_gradient(objective, g, collect(x)))
    @objective(model, Min, op_objective(x...))
    fval0 =  MOI.eval_objective(objective, x0)
    isfinite(fval0) || error("Initial value must be finite")
    JuMP.optimize!(model)

    stat = termination_status(model)
    stat == LOCALLY_SOLVED || @warn("Solution was not optimal")
    JuMP.value.(x)
end

# We omit the constant term ∑_i cs[i]'*Qs[i]*cs[i], since it won't
# affect the solution
MOI.eval_objective(d::InitialDefOpt, x::AbstractVector) =
    _eval_f(d.P, d.b, x)

function _eval_f(P::AffineQHessian{AffinePenalty{T,N}}, b, x::AbstractVector) where {T,N}
    gridsize = size(P.Qs)
    n = prod(gridsize)
    u  = convert_to_fixed(x, (N,gridsize...))# reinterpret(SVector{N,T}, x, gridsize)
    bf = convert_to_fixed(b, (N,gridsize...))# reinterpret(SVector{N,T}, b, gridsize)
    λ = P.ap.λ
    P.ap.λ = λ*n/2
    val = affine_part!(nothing, P, u)
    P.ap.λ = λ
    for i = 1:n
        val += ((u[i]' * P.Qs[i] * u[i])/2 - bf[i]'*u[i])[1]
    end
    val
end

function MOI.eval_objective_gradient(d::InitialDefOpt, grad_f, x)
    P, b = d.P, d.b
    copy!(grad_f, P*x-b)
end

function affine_part!(g, P::AffineQHessian{AP,M,N,Φ}, u) where {AP,M,N,Φ<:GridDeformation}
    ϕ_c, g_c = compose(P.ϕ_old, GridDeformation(u, P.ϕ_old.nodes))
    penalty!(g, P.ap, ϕ_c, g_c)
end

function affine_part!(::Nothing, P::AffineQHessian{AP,M,N,Φ}, u) where {AP,M,N,Φ<:GridDeformation}
    # Sadly, with GradientNumbers this gives an error I haven't traced
    # down (might be a Julia bug)
    # ϕ_c = P.ϕ_old(GridDeformation(u, P.ϕ_old.nodes))
    # penalty!(nothing, P.ap, ϕ_c)
    u_c = RegisterDeformation._compose(P.ϕ_old.u, u, P.ϕ_old.nodes)
    penalty!(nothing, P.ap, u_c)
end

###
### Optimize (via descent) a deformation to mismatch data
###

itporder(mmis::Array) = itporder(eltype(mmis))
itporder(::Type{CenterIndexedArray{T,N,A}}) where {T,N,A} = itporder(A)
itporder(::Type{AI}) where {AI<:AbstractInterpolation} = Interpolations.itptype(AI)

"""
`ϕ, fval, fval0 = optimize!(ϕ, ϕ_old, dp, mmis; [tol=1e-6, print_level=0])`
improves an initial deformation `ϕ` to reduce the mismatch.  The
arguments are as described for `penalty!` in RegisterPenalty.  On
output, `ϕ` is set in-place to the new optimized deformation,
`fval` is the value of the penalty, and `fval0` was the starting value.

It's recommended that you verify that `fval < fval0`; if it's not
true, consider adding `mu_strategy="monotone", mu_init=??` to the
options (where the value of ?? might require some experimentation; a
starting point might be 1e-4).  See also `fixed_λ` and `auto_λ`.

For quadratically-interpolated `mmis`, any additional keyword
arguments get passed as options to Ipopt. For linearly-interpolated
`mmis`, you can use `stepsize=0.25` to take steps that, for the most
strongly-shifted deformation coordinate, are 0.25pixel.
"""
function optimize!(ϕ, ϕ_old, dp::DeformationPenalty, mmis; kwargs...)
    _optimize!(ϕ, ϕ_old, dp, mmis, itporder(mmis); kwargs...)
end

# If the mismatch is interpolated linearly, we don't have a continuous
# gradient and therefore can't use the more sophisticated
# algorithms. In that case we use a subgradient method, using gradient
# descent with a "constant" step length (using an L1 measure of
# length). See https://en.wikipedia.org/wiki/Subgradient_method.
function _optimize!(ϕ, ϕ_old, dp::DeformationPenalty, mmis, ::Type{BSpline{Linear}}; stepsize=1.0, kwargs...)
    mxs = maxshift(first(mmis))
    g = similar(ϕ.u)
    gview = convert_from_fixed(g)
    @assert pointer(gview) == pointer(g)
    p0 = p = penalty!(g, ϕ, ϕ_old, dp, mmis)
    pold = oftype(p, Inf)
    while p < pold
        pold = p
        gmax = mapreduce(abs, max, gview)
        if gmax == 0 || !isfinite(gmax)
            break
        end
        s = eltype(gview)(stepsize/gmax)
        u = ϕ.u .- s .* g
        uclamp!(u, mxs)
        ϕ1 = GridDeformation(u, ϕ.nodes)
        p = penalty!(g, ϕ1, ϕ_old, dp, mmis)
        if p < pold
            copy!(ϕ.u, u)
        end
    end
    ϕ, pold, p0
end

function _optimize!(ϕ, ϕ_old, dp::DeformationPenalty, mmis, T::Type; tol=1e-6, print_level=0, kwargs...)
    objective = DeformOpt(ϕ, ϕ_old, dp, mmis)
    _optimize!(objective, ϕ, dp, mmis, tol, print_level; kwargs...)
end

function optimize!(ϕ, ϕ_old, dp::AffinePenalty{T,N}, mmis::Array{Tf}) where {Tf<:Number, T, N}
    ND = NumDenom{Tf}
    mmisr = reshape(reinterpret(ND, vec(mmis)), tail(size(mmis)))
    mmisc = cachedinterpolators(mmisr, N, ntuple(d->(size(mmisr,d)+1)>>1, N))
    optimize!(ϕ, ϕ_old, dp, mmisc)
end

function _optimize!(objective, ϕ, dp, mmis, tol, print_level; kwargs...)
    uvec = u_as_vec(ϕ)
    T = eltype(uvec)
    skwargs = map(k->String(k)=>kwargs[k],keys(kwargs))
    mxs = maxshift(first(mmis))

    model = Model(optimizer_with_attributes(Ipopt.Optimizer,
                                            "hessian_approximation" => "limited-memory",
                                            "print_level" => print_level,
                                            "sb" => "yes",
                                            "tol" => tol,
                                            skwargs...))

    ub1 = T[mxs...] .- T(RegisterFit.register_half)
    ub = repeat(ub1, outer=[div(length(uvec), length(ub1))])
    N = length(ub)
    @variable(model, -ub[i] <= x[i in 1:N] <= ub[i], start = uvec[i])
    @operator(model, op_objective, N, (x...) -> MOI.eval_objective(objective, collect(x)),
                                      (g, x...) -> MOI.eval_objective_gradient(objective, g, collect(x)))
    @objective(model, Min, op_objective(x...))
    fval0 =  MOI.eval_objective(objective, uvec)
    isfinite(fval0) || error("Initial value must be finite")
    JuMP.optimize!(model)

    stat = termination_status(model)
    stat == LOCALLY_SOLVED || @warn("Solution was not optimal")
    uopt = JuMP.value.(x)
    fval = JuMP.objective_value(model)
    _copy!(ϕ, uopt)
    ϕ, fval, fval0
end

function u_as_vec(ϕ::GridDeformation{S,N}, ::Type{T}=eltype(ϕ)) where {S,N,T}
    R = promote_type(S, T)
    n = length(ϕ.u)
    return convert(AbstractVector{R}, reshape(reinterpret(S, vec(ϕ.u)), (n*N,)))
end

function vec_as_u(g, ϕ::GridDeformation{T,N}) where {T,N}
    reshape(reinterpret(SVector{N,T}, vec(g)), size(ϕ.u))
end

function vec_as_u(g::Array{T}, ϕ::GridDeformation{T,N}) where {T,N}
    reshape(reinterpret(SVector{N,T}, vec(g)), size(ϕ.u))
end

function _copy!(ϕ::GridDeformation, x)
    uvec = u_as_vec(ϕ)
    copyto!(uvec, copy(x))
end

# Sequence of deformations
function u_as_vec(ϕs::Vector{D}, ::Type{T}=eltype(D)) where {D<:GridDeformation,T}
    S = promote_type(T, eltype(D))
    N = ndims(D)
    ngrid = length(first(ϕs).u)
    n = N*ngrid
    uvec = Vector{S}(undef, n*length(ϕs))
    for (i, ϕ) in enumerate(ϕs)
        copyto!(uvec, (i-1)*n+1, reshape(reinterpret(eltype(D), vec(ϕ.u)), (n,)), 1, n)
    end
    uvec
end


mutable struct DeformOpt{D,Dold,DP,M} <: GradOnlyBoundsOnly
    ϕ::D
    ϕ_old::Dold
    dp::DP
    mmis::M
end
# (d::DeformOpt)(x) = MOI.eval_objective(d, x)

function MOI.eval_objective(d::DeformOpt, x::AbstractVector{<:Real})
    uvec = u_as_vec(d.ϕ)#, eltype(x))
    copyto!(uvec, x)
    penalty!(nothing, d.ϕ, d.ϕ_old, d.dp, d.mmis)
end

function MOI.eval_objective_gradient(d::DeformOpt, grad_f, x)
    uvec = u_as_vec(d.ϕ)
    copyto!(uvec, x)
    penalty!(vec_as_u(grad_f, d.ϕ), d.ϕ, d.ϕ_old, d.dp, d.mmis)
end


# With temporal penalty
# function optimize!(ϕs, ϕs_old, dp::DeformationPenalty, λt, mmis; tol=1e-6, print_level=0, kwargs...)
#     objective = DeformTseriesOpt(ϕs, ϕs_old, dp, λt, mmis)
#     _optimize!(objective, ϕs, dp, mmis, tol, print_level; kwargs...)
# end

"""
`ϕs, penalty = optimize!(ϕs, ϕs_old, dp, λt, mmis; kwargs...)`
optimizes a sequence `ϕs` of deformations for an image sequence with
mismatch data `mmis`, using a spatial deformation penalty `dp` and
temporal penalty coefficient `λt`.
"""
function optimize!(ϕs, ϕs_old, dp::AffinePenalty, λt, mmis; kwargs...)
    T = eltype(eltype(first(mmis)))
    objective = DeformTseriesOpt(ϕs, ϕs_old, dp, λt, mmis)
    uvec = u_as_vec(ϕs)
    df = OnceDifferentiable(x->MOI.eval_objective(objective, x),
                                (g,x)->MOI.eval_objective_gradient(objective, g, x),uvec)
    mxs = maxshift(first(mmis))
    ub1 = T[mxs...] .- T(RegisterFit.register_half)
    ub = repeat(ub1, outer=[div(length(uvec), length(ub1))])
    results = Optim.optimize(df, -ub, ub, uvec, Fminbox(LBFGS()), Optim.Options(x_tol=1e-4, kwargs...))
    _copy!(ϕs, Optim.minimizer(results)), Optim.minimum(results)
end

function optimize!(ϕs, ϕs_old, dp::AffinePenalty{T,N}, λt, mmis::Array{Tf}) where {Tf<:Number, T, N}
    ND = NumDenom{Tf}
    mmisr = reshape(reinterpret(ND, vec(mmis)), tail(size(mmis)))
    mmisc = cachedinterpolators(mmisr, N, ntuple(d->(size(mmisr,d)+1)>>1, N))
    optimize!(ϕs, ϕs_old, dp, λt, mmisc)
end

mutable struct DeformTseriesOpt{D,Dsold,DP,T,M} <: GradOnlyBoundsOnly
    ϕs::Vector{D}
    ϕs_old::Dsold
    dp::DP
    λt::T
    mmis::M
end

# Using MOI is a legacy of the old Ipopt interface, but
# keeping it doesn't hurt anything.
function MOI.eval_objective(d::DeformTseriesOpt, x)
    _copy!(d.ϕs, x)
    penalty!(nothing, d.ϕs, d.ϕs_old, d.dp, d.λt, d.mmis)
end

function MOI.eval_objective_gradient(d::DeformTseriesOpt, grad_f, x)
    _copy!(d.ϕs, x)
    penalty!(grad_f, d.ϕs, d.ϕs_old, d.dp, d.λt, d.mmis)
end

function _copy!(ϕs::Vector{D}, x::Array{T}) where {D<:GridDeformation,T<:Number}
    N = ndims(first(ϕs))
    L = N*length(first(ϕs).u)
    length(x) == L*length(ϕs) || throw(DimensionMismatch("ϕs is incommensurate with a vector of length $(length(x))"))
    for (i, ϕ) in enumerate(ϕs)
        uvec = reshape(reinterpret(eltype(ϕ), vec(ϕ.u)), (L,))
        copyto!(uvec, 1, x, (i-1)*L+1, L)
    end
    ϕs
end

"""
`ϕ, penalty = fixed_λ(cs, Qs, nodes, affinepenalty, mmis)` computes an
optimal deformation `ϕ` and its total `penalty` (data penalty +
regularization penalty).  `cs` and `Qs` come from `qfit`, `nodes`
specifies the deformation grid, `affinepenalty` the `AffinePenalty`
object for that grid, and `mmis` is the array-of-mismatch arrays
(already interpolating, see `interpolate_mm!`).

See also: `auto_λ`.
"""
function fixed_λ(cs, Qs, nodes::NTuple{N}, ap::AffinePenalty{T,N}, mmis; ϕs_old = identity, mu_init=0.1, kwargs...) where {T,N}
    maxshift = map(x->(x-1)>>1, size(first(mmis)))
    u0, isconverged = initial_deformation(ap, cs, Qs)
    if !isconverged
        Base.warn_once("initial_deformation failed to converge with λ = ", ap.λ)
        if any(x->!isfinite(x), convert_from_fixed(u0))
            u0 = cs2u(SVector{N,T}, cs)
        end
    end
    uclamp!(u0, maxshift)
    ϕ = GridDeformation(u0, nodes)
    local mismatch
    while mu_init > 1e-16
        ϕ, mismatch, mismatch0 = optimize!(ϕ, ϕs_old, ap, mmis; mu_strategy="monotone", mu_init=mu_init, kwargs...)
        mismatch <= mismatch0 && break
        mu_init /= 10
        @show mu_init
    end
    ϕ, mismatch
end

"""
`ϕs, penalty = fixed_λ(cs, Qs, nodes, affinepenalty, λt, mmis)`
computes an optimal vector-of-deformations `ϕs` for an image sequence,
using an temporal penalty coefficient `λt`.
"""
function fixed_λ(cs::AbstractArray{SVector{N,T}}, Qs::AbstractArray{SMatrix{N,N,T,L}}, nodes::NTuple{N}, ap::AffinePenalty{TP,N}, λt, mmis; ϕs_old = identity, mu_init=0.1, kwargs...) where {T,N,TP,L}
    λtT = T(λt)
    apT = convert(AffinePenalty{T,N}, ap)
    maxshift = map(x->(x-1)>>1, size(first(mmis)))
    print("Calculating initial guess (this may take a while)...")
    u0, isconverged = initial_deformation(apT, λtT, cs, Qs)
    println("done")
    if !isconverged
        Base.warn_once("initial_deformation failed to converge with λ = ", ap.λ, ", λt = ", λt)
    end
    uclamp!(u0, maxshift)
    colons = ntuple(ColonFun, Val(N))
    ϕs = [GridDeformation(u0[colons..., i], nodes) for i = 1:size(u0)[end]]
    local mismatch
    println("Starting optimization.")
    optimize!(ϕs, ϕs_old, apT, λtT, mmis; kwargs...)
end

# This version re-packs variables as read from the .jld file
function fixed_λ(cs::Array{Tf}, Qs::Array{Tf}, nodes::NTuple{N}, ap::AffinePenalty{T,N}, λt, mmis::Array{Tf}; kwargs...) where {Tf<:Number,T,N}
    csr = unsafe_wrap(Array, convert(Ptr{SVector{N,Tf}}, pointer(cs)), (tail(size(cs))...,))
    Qsr = unsafe_wrap(Array, convert(Ptr{similar_type(SArray,Tf,Size(N,N))}, pointer(Qs)), (tail(tail(size(Qs)))...,))
    if length(mmis) > 10^7
        L = length(mmis)*sizeof(Tf)/1024^3
        @printf "The mismatch data are %0.2f GB in size.\n  During optimization, the initial function evaluations may be limited by I/O and\n  could be very slow. Later evaluations should be faster.\n" L
    end
    ND = NumDenom{Tf}
    mmisr = unsafe_wrap(Array, convert(Ptr{ND}, pointer(mmis)), (tail(size(mmis))...,))
    mmisc = cachedinterpolators(mmisr, N, ntuple(d->(size(mmisr,d)+1)>>1, N))
    fixed_λ(csr, Qsr, nodes, ap, λt, mmisc; kwargs...)
end

###
### Set λ automatically
###
"""
`ϕ, penalty, λ, datapenalty, quality = auto_λ(fixed, moving, gridsize, maxshift, (λmin, λmax))` automatically chooses "the best"
value of `λ` to serve in the spatial regularization penalty. It tests a
sequence of `λ` values, starting with `λmin` and each successive value
two-fold larger than the previous; for each such `λ`, it optimizes the
registration and then evaluates just the "data" portion of the
penalty.  The "best" value is selected by a sigmoidal fit of the
impact of `λ` on the data penalty, choosing a value that lies at the
initial upslope of the sigmoid (indicating that the penalty is large
enough to begin limiting the form of the deformation, but not yet to
substantially decrease the quality of the registration).

`ϕ, penalty, λ, datapenalty, quality = auto_λ(cs, Qs, nodes, mmis,
(λmin, λmax))` is used if you've already computed mismatch data. `cs`
and `Qs` come from `qfit`, `nodes` specifies the deformation grid, and
`mmis` is the array-of-mismatch arrays (already interpolating, see
`interpolate_mm!`).

As a first pass, try setting `λmin=1e-6` and `λmax=100`. You can plot
the returned `datapenalty` and check that it is approximately
sigmoidal; if not, you will need to alter the range you supply.

Upon return, `ϕ` is the chosen deformation, `penalty` its total
penalty (data penalty+regularization penalty), `λ` is the chosen value
of `λ`, `datapenalty` is a vector containing the data penalty for each
tested `λ` value, and `quality` an estimate (possibly broken) of the
fidelity of the sigmoidal fit.

If you have data for an image sequence, `auto_λ(stackindex, cs, Qs,
nodes, mmis, (λmin, λmax))` will perform the analysis on the chosen
`stackindex`.

See also: `fixed_λ`. Because `auto_λ` performs the optimization
repeatedly for many different `λ`s, it is slower than `fixed_λ`.
"""
function auto_λ(fixed::AbstractArray{R}, moving::AbstractArray{S}, gridsize::NTuple{N}, maxshift::NTuple{N}, λrange; thresh=(0.5)^ndims(fixed)*length(fixed)/prod(gridsize), kwargs...) where {R<:Real,S<:Real,N}
    T = Float64
    local mms
    try
        mms = Main.mismatch_apertures(T, fixed, moving, gridsize, maxshift; normalization=:pixels)
    catch
        @warn("call to mismatch_apertures failed. Make sure you're using either RegisterMismatch or RegisterMismatchCuda")
        rethrow()
    end
    cs, Qs, mmis = mms2fit(mms, thresh)
    nodes = map(d->range(1, stop=size(fixed,d), length=gridsize[d]), (1:ndims(fixed)...,))::NTuple{N, LinSpace{Float64}}
    auto_λ(cs, Qs, nodes, mmis, λrange; kwargs...)
end

function auto_λ(cs, Qs, nodes::NTuple{N}, mmis, λrange; kwargs...) where N
    ap = AffinePenalty{Float64,N}(nodes, λrange[1])  # default to affine-residual penalty, Ipopt needs Float64
    auto_λ(cs, Qs, nodes, ap, mmis, λrange; kwargs...)
end

function auto_λ(stackidx::Integer, cs, Qs, nodes::NTuple{N}, mmis, λrange; kwargs...) where N
    cs1 = cs[ntuple(d->Colon(),ndims(cs)-1)..., stackidx];
    Qs1 = Qs[ntuple(d->Colon(),ndims(Qs)-1)..., stackidx];
    mmis1 = mmis[ntuple(d->Colon(),ndims(mmis)-1)..., stackidx];
    auto_λ(cs1, Qs1, nodes, mmis1, λrange; kwargs...)
end

function auto_λ(cs::Array{Tf}, Qs::Array{Tf}, nodes::NTuple{N}, ap::AffinePenalty{T,N}, mmis::Array{Tf}, λrange; kwargs...) where {Tf<:Number,T,N}
    # Ipopt requires Float64
    auto_λ(convert(Array{Float64}, cs), convert(Array{Float64}, Qs), nodes, ap, convert(Array{Float64}, mmis), λrange; kwargs...)
end

function auto_λ(cs::Array{Float64}, Qs::Array{Float64}, nodes::NTuple{N}, ap::AffinePenalty{T,N}, mmis::Array{Float64}, λrange; kwargs...) where {T,N}
    csr = reshape(reinterpret(SVector{N,Float64}, vec(cs)), tail(size(cs)))
    Qsr = reshape(reinterpret(similar_type(SArray,Float64,Size(N,N)), vec(Qs)), tail(tail(size(Qs))))
    mmisr = reshape(reinterpret(NumDenom{Float64}, vec(mmis)), tail(size(mmis)))
    mmisc = cachedinterpolators(mmisr, N, ntuple(d->(size(mmisr,d)+1)>>1, N))
    ap64 = convert(AffinePenalty{Float64,N}, ap)
    auto_λ(csr, Qsr, nodes, ap64, mmisc, λrange; kwargs...)
end

function auto_λ(cs, Qs, nodes::NTuple{N}, ap::AffinePenalty{T,N}, mmis, λrange; kwargs...) where {T,N}
    λmin, λmax = λrange
    gridsize = map(length, nodes)
    uc = zeros(T, N, gridsize...)
    for i in CartesianIndices(gridsize)
        uc[:,i] = convert(Vector{T}, cs[i])
    end
    function optimizer!(x, mu_init)
        local pnew
        while mu_init > 1e-16
            x, pnew, p0 = optimize!(x, identity, ap, mmis; mu_strategy="monotone", mu_init=mu_init, kwargs...)
            pnew <= p0 && break
            mu_init /= 10
        end
        x, pnew
    end
    ap.λ = λ = λmin
    maxshift = map(x->(x-1)>>1, size(first(mmis)))
    uclamp!(uc, maxshift)
    ϕprev = GridDeformation(uc, nodes)
    mu_init = 0.1
    ϕprev, penaltyprev = optimizer!(ϕprev, mu_init)
    u0, isconverged = initial_deformation(ap, cs, Qs)
    if !isconverged
        Base.warn_once("initial_deformation failed to converge with λ = ", λ)
    end
    uclamp!(u0, maxshift)
    ϕap = GridDeformation(u0, nodes)
    ϕap, penaltyap = optimizer!(ϕap, mu_init)
    n = ceil(Int, log2(λmax) - log2(λmin))
    λ_all = Vector{typeof(λmin)}(undef, n)
    penalty_all = similar(λ_all, typeof(penaltyprev))
    datapenalty_all = similar(penalty_all)
    ϕ_all = Any[]
    # Keep the lower penalty, but for the purpose of the sigmoidal fit
    # evaluate just the data penalty
    if penaltyprev < penaltyap
        penalty_all[1] = penaltyprev
        datapenalty_all[1] = penalty!(nothing, ϕprev, mmis)
        push!(ϕ_all, ϕprev)
    else
        penalty_all[1] = penaltyap
        datapenalty_all[1] = penalty!(nothing, ϕap, mmis)
        push!(ϕ_all, ϕap)
    end
    λ_all[1] = λ
    @showprogress 1 "Calculating penalty vs. λ: " for i = 2:n
        λ *= 2
        ap.λ = λ
        ϕprev = GridDeformation(copy(ϕ_all[end].u), nodes)
        ϕprev, penaltyprev = optimizer!(ϕprev, mu_init)
        u0, isconverged = initial_deformation(ap, cs, Qs)
        if !isconverged
            Base.warn_once("initial_deformation failed to converge with λ = ", λ)
        end
        uclamp!(u0, maxshift)
        ϕap = GridDeformation(u0, nodes)
        ϕap, penaltyap = optimizer!(ϕap, mu_init)
        if penaltyprev < penaltyap
            penalty_all[i] = penaltyprev
            datapenalty_all[i] = penalty!(nothing, ϕprev, mmis)
            push!(ϕ_all, ϕprev)
        else
            penalty_all[i] = penaltyap
            datapenalty_all[i] = penalty!(nothing, ϕap, mmis)
            push!(ϕ_all, ϕap)
        end
        λ_all[i] = λ
    end
    bottom, top, center, width, val = fit_sigmoid(datapenalty_all)
    idx = max(1, round(Int, center-width))
    quality = val/(top-bottom)^2/length(datapenalty_all)
    ϕ_all[idx], penalty_all[idx], λ_all[idx], λ_all, datapenalty_all, quality
end

# Because of the long run times, here we only use the quadratic approximation
"""
`λts, datapenalty = auto_λt(Es, cs, Qs, ap, (λtmin, λtmax))` estimates
the whole-experiment mismatch penalty as a function of `λt`, choosing
values starting at `λtmin` and increasing two-fold until `λtmax`.
`Es`, `cs`, and `Qs` come from the quadratic fix of the mismatch, and
`ap` is the (spatial) affine-residual penalty.  As a first guess, try
`λtmin=1e-6` and `λtmax=1`.  (Larger values of `λt` are noticeably
slower to optimize.)

By plotting `datapenalty` vs `λts` (with a log-scale on the x-axis),
you can find the "kink" at which the value of `λt` begins to constrain
the optimization.  Good choices for `λt` tend to be near this kink.
Since only an approximation of the mismatch is used, the value of the
estimated data penalty will not be terribly accurate, but the hope is
that its dependence on `λt` will be approximately correct.
"""
function auto_λt(Es, cs, Qs, ap, λtrange)
    ngrid = prod(size(Es)[1:end-1])
    Esum = sum(Es)
    λt = first(λtrange)
    n = ceil(Int, log2(last(λtrange)) - log2(λt))
    datapenalty = Vector{typeof(Esum)}(undef, n)
    λts = Vector{typeof(λt)}(undef, n)
    @showprogress 1 "Calculating quadratic penalty as a function of λt: " for λindex = 1:n
        λts[λindex] = λt
        u0, isconverged = initial_deformation(ap, λt, cs, Qs)
        if !isconverged
            println("initial_deformation failed to converge with λ = ", ap.λ, ", λt = ", λt)
        end
        val = Esum
        for i = 1:length(u0)
            du = u0[i] - cs[i]
            val += dot(du, Qs[i] * du)
        end
        datapenalty[λindex] = val/ngrid
        λt *= 2
    end
    λts, datapenalty
end

function auto_λt(Es, cs::Array{Tf}, Qs::Array{Tf}, ap::AffinePenalty{T,N}, λt) where {Tf<:Number,T,N}
    csr = reshape(reinterpret(SVector{N,Tf}, vec(cs)), tail(size(cs)))
    Qsr = reshape(reinterpret(similar_type(SArray,Tf,Size(N,N)), vec(Qs)), tail(tail(size(Qs))))
    auto_λt(Es, csr, Qsr, ap, λt)
end

###
### Whole-experiment optimization with a temporal roughness penalty
###
function initial_deformation(ap::AffinePenalty{T,N}, λt, cs::AbstractArray{V}, Qs::AbstractArray{M}) where {T,N,V<:SVector,M<:SMatrix}
    Tv = eltype(V)
    eltype(M) == Tv || error("element types of cs ($(eltype(V))) and Qs ($(eltype(M))) must match")
    length(V) == N || throw(DimensionMismatch("Dimensionality $N of ap does not match $(length(V))"))
    size(M,1) == size(M,2) == N || throw(DimensionMismatch("size $(size(M)) of Qs matrices is inconsistent with cs vectors of size $(size(V))"))
    apc = convert(AffinePenalty{Tv,N}, ap)
    b = prep_b(Tv, cs, Qs)
    P = TimeHessian(AffineQHessian(apc, Qs, identity), convert(Tv, λt))
    x, isconverged = find_opt(P, b)
    convert_to_fixed(SVector{N,Tv}, x, size(cs)), isconverged
end

struct TimeHessian{AQH<:AffineQHessian,T}
    aqh::AQH
    λt::T
end

Base.eltype(::Type{TimeHessian{AQH,T}}) where {AQH,T} = eltype(AQH)
Base.eltype(P::TimeHessian) = eltype(typeof(P))
Base.size(P::TimeHessian, d) = size(P.aqh, d)

function (*)(P::TimeHessian{AQH}, x::AbstractVector) where AQH
    yv = P.aqh*x
    ϕs = vec2vecϕ(P.aqh.Qs, x)
    y = convert_to_fixed(SVector{size(P.aqh.Qs[1],1),eltype(yv)}, yv, size(P.aqh.Qs))
    penalty!(y, P.λt, ϕs)
    yv
end

function LinearAlgebra.mul!(y::AbstractVector,
                              P::TimeHessian{AQH},
                              x::AbstractVector) where AQH
    mul!(y, P.aqh, x)
    ϕs = vec2vecϕ(P.aqh.Qs, x)
    penalty!(y, P.λt, ϕs)
    y
end

function vec2vecϕ(Qs::Array{SMatrix{N,N,T,L}}, x::AbstractVector{T}) where {T,N,L}
    xf = convert_to_fixed(SVector{N,T}, x, size(Qs))
    _vec2vecϕ(xf, Base.front(axes(Qs)))
end

@noinline function _vec2vecϕ(x::AbstractArray, axs::NTuple{N,<:AbstractUnitRange}) where N
    colons = ntuple(ColonFun, Val(N))
    [GridDeformation(view(x, colons..., i), axs) for i = 1:size(x)[end]]
end


###
### Mismatch-based optimization of affine transformation
###
### NOTE: not updated yet, probably broken
"""
`tform = optimize(tform0, mms, nodes)` performs descent-based
minimization of the total mismatch penalty as a function of the
parameters of an affine transformation, starting from an initial guess
`tform0`.  While this is unlikely to yield very accurate results for
large rotations or skews (the mismatch data are themselves suspect in
such cases), it can be helpful for polishing small deformations.

For a good initial guess, see `mismatch2affine`.
"""
function optimize(tform::AffineMap, mmis, nodes)
    gridsize = size(mmis)
    N = length(gridsize)
    ndims(tform) == N || error("Dimensionality of tform is $(ndims(tform)), which does not match $N for nums/denoms")
    mm = first(mmis)
    mxs = maxshift(mm)
    T = eltype(eltype(mm))
    # Compute the bounds
    asz = arraysize(nodes)
    center = T[(asz[i]+1)/2 for i = 1:N]
    X = zeros(T, N+1, prod(gridsize))
    for (i, node) in enumerate(eachnode(nodes))
        X[1:N,i] = node - center
        X[N+1,i] = 1
    end
    bound = convert(Vector{T}, [mxs .- register_half; Inf])
    lower = repeat(-bound, outer=[1,size(X,2)])
    upper = repeat( bound, outer=[1,size(X,2)])
    # Extract the parameters from the initial guess
    Si = tform.linear
    displacement = tform.translation
    A = convert(Matrix{T}, [Si-Matrix{Float64}(I,N,N) displacement; zeros(1,N) 1])
    # Determine the blocks that start in-bounds
    AX = A*X
    keep = trues(gridsize)
    for j = 1:length(keep)
        for idim = 1:N
            xi = AX[idim,j]
            if xi < -mxs[idim]+register_half_safe || xi > mxs[idim]-register_half_safe
                keep[j] = false
                break
            end
        end
    end
    if !any(keep)
        @show tform
        @warn("No valid blocks were found")
        return tform
    end
    ignore = !keep[:]
    lower[:,ignore] = -Inf
    upper[:,ignore] =  Inf
    # Assemble the objective and constraints

    constraints = Optim.ConstraintsL(X', lower', upper')
    gtmp = Array{SVector{N,T}}(undef, gridsize)
    objective = (x,g) -> affinepenalty!(g, x, mmis, keep, X', gridsize, gtmp)
    @assert typeof(objective(A', T[])) == T
    result = interior(DifferentiableFunction(x->objective(x,T[]), Optim.dummy_g!, objective), A', constraints, method=:cg)
    @assert Optim.converged(result)
    Aopt = result.minimum'
    Siopt = Aopt[1:N,1:N] + Matrix{Float64}(I,N,N)
    displacementopt = Aopt[1:N,end]
    AffineMap(convert(Matrix{T}, Siopt), convert(Vector{T}, displacementopt)), result.f_minimum
end

function affinepenalty!(g, At, mmis, keep, Xt, gridsize::NTuple{N}, gtmp) where N
    u = _calculate_u(At, Xt, gridsize)
    @assert eltype(u) == eltype(At)
    val = penalty!(gtmp, u, mmis, keep)
    @assert isa(val, eltype(At))
    if !isempty(g)
        T = eltype(eltype(gtmp))
        nblocks = size(Xt,1)
        At_mul_Bt!(g, Xt, [reshape(reinterpret(T,vec(gtmp)),(N,nblocks)); zeros(1,nblocks)])
    end
    val
end

function _calculate_u(At, Xt, gridsize::NTuple{N}) where N
    Ut = Xt*At
    u = Ut[:,1:size(Ut,2)-1]'                   # discard the dummy dimension
    reshape(reinterpret(SVector{N, eltype(u)}, vec(u)), gridsize) # put u in the shape of the grid
end

###
### Fitting to a sigmoid
###
# Used in automatically setting λ

"""
`fit_sigmoid(data, [bottom, top, center, width])` fits the y-values in `data` to a logistic function
```
   y = bottom + (top-bottom)./(1 + exp(-(data-center)/width))
```
This is "non-extrapolating": the parameter values are constrained to
be within the range of the supplied data (i.e., `bottom` and `top`
between the min and max values of `data`, `center` within `[1,
length(data)]`, and `0.1 <= width <= length(data)`.)
"""
function fit_sigmoid(data, bottom, top, center, width)
    length(data) >= 4 || error("Too few data points for sigmoidal fit")
    objective = SigmoidOpt(data)

    # solver = IpoptSolver(print_level=0, sb="yes")
    # m = MOI.NonlinearModel(solver)
    # x0 = Float64[bottom, top, center, width]
    # mn, mx = extrema(data)
    # ub = [mx, mx, length(data), length(data)]
    # lb = [mn, mn, 1, 0.1]
    # MOI.loadproblem!(m, 4, 0, lb, ub, Float64[], Float64[], :Min, objective)
    # MOI.setwarmstart!(m, x0)
    # MOI.optimize!(m)

    model = Model(optimizer_with_attributes(Ipopt.Optimizer,
                                            "print_level" => 0,
                                            "sb" => "yes"))
    mn, mx = extrema(data)
    x0 = Float64[bottom, top, center, width]
    N = length(x0)
    @variable(model, mn <= x[i in 1:N] <= mx, start = x0[i])
    @operator(model, op_objective, N, (x...) -> MOI.eval_objective(objective, collect(x)),
                            (g, x...) -> MOI.eval_objective_gradient(objective, g, collect(x)))
    @objective(model, Min, op_objective(x...))
    fval0 =  MOI.eval_objective(objective, x0)
    isfinite(fval0) || error("Initial value must be finite")
    JuMP.optimize!(model)

    stat = termination_status(model)
    stat == LOCALLY_SOLVED || @warn("Solution was not optimal")
    x = JuMP.value.(x)

    x[1], x[2], x[3], x[4], JuMP.objective_value(model)
end

function fit_sigmoid(data)
    length(data) >= 4 || error("Too few data points for sigmoidal fit")
    sdata = sort(data)
    mid = length(data)>>1
    bottom = mean(sdata[1:mid])
    top = mean(sdata[mid+1:end])
    fit_sigmoid(data, bottom, top, mid, mid)
end


mutable struct SigmoidOpt{G,H} <: BoundsOnly
    data::Vector{Float64}
    g::G
    h::H
end

SigmoidOpt(data::Vector{Float64}) = SigmoidOpt(data, y->ForwardDiff.gradient(x->sigpenalty(x, data), y), y->ForwardDiff.hessian(x->sigpenalty(x, data), y))

function MOI.initialize(d::SigmoidOpt, requested_features::Vector{Symbol})
    for feat in requested_features
        if !(feat in [:Grad, :Jac, :Hess])
            error("Unsupported feature $feat")
        end
    end
end
MOI.features_available(d::SigmoidOpt) = [:Grad, :Jac, :Hess]

MOI.eval_objective(d::SigmoidOpt, x) = sigpenalty(x, d.data)

MOI.eval_objective_gradient(d::SigmoidOpt, grad_f, x) =
    copyto!(grad_f, d.g(x))

function MOI.hessian_lagrangian_structure(d::SigmoidOpt)
    I, J = Int[], Int[]
    for i in CartesianIndices((4,4))
        push!(I, i[1])
        push!(J, i[2])
    end
    (I, J)
end

function MOI.eval_hessian_lagrangian(d::SigmoidOpt, H, x, σ, μ)
    copyto!(H, σ * d.h(x))
end

function sigpenalty(x, data)
    bottom, top, center, width = x[1], x[2], x[3], x[4]
    sum(abs2, (data .- bottom) / (top-bottom) - 1 ./(1 .+ exp.(-(collect(1:length(data)) .- center)/width)))
end

@generated function RegisterCore.maxshift(A::CachedInterpolation{T,N}) where {T,N}
    args = [:(size(A.parent, $d)>>1) for d = 1:N]
    Expr(:tuple, args...)
end

end # module
