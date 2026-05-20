# RegisterOptimize.jl

[![CI](https://github.com/HolyLab/RegisterOptimize.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/HolyLab/RegisterOptimize.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/HolyLab/RegisterOptimize.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/HolyLab/RegisterOptimize.jl)

RegisterOptimize provides optimization routines for image registration: given a pair of images, it finds the rigid or deformable transformation that minimizes the mismatch between them. It is part of the [HolyLab image registration ecosystem](#ecosystem).

## Installation

This package is registered in the [HolyLabRegistry](https://github.com/HolyLab/HolyLabRegistry). Add that registry once, then install normally:

```julia
using Pkg
pkg"registry add https://github.com/HolyLab/HolyLabRegistry.git"
Pkg.add("RegisterOptimize")
```

## Ecosystem

RegisterOptimize sits at the optimization end of a multi-package pipeline:

| Package | Role |
|---------|------|
| [RegisterMismatch.jl](https://github.com/HolyLab/RegisterMismatch.jl) | Compute block-wise mismatch between image pairs |
| [RegisterFit.jl](https://github.com/HolyLab/RegisterFit.jl) | Fit quadratic models to mismatch data |
| [RegisterPenalty.jl](https://github.com/HolyLab/RegisterPenalty.jl) | Regularization penalties for deformations |
| [RegisterDeformation.jl](https://github.com/HolyLab/RegisterDeformation.jl) | Deformation types and coordinate transformations |
| **RegisterOptimize.jl** | **Optimize the registration** |

## Concepts

### Mismatch data

The main optimization routines work on *mismatch data* rather than raw images. For each block of the image grid, mismatch data records how much the two images differ as a function of local shift. This representation is precomputed by RegisterMismatch and interpolated before being passed to RegisterOptimize, enabling fast repeated evaluations during optimization.

### Regularization

Deformable registration is ill-posed: without constraints, the optimizer can find deformations that align images locally but are physically unrealistic. A regularization penalty (controlled by strength `λ`) penalizes deformations that deviate from an affine map. Larger `λ` gives smoother but less locally accurate registration; smaller `λ` gives more flexibility but risks overfitting.

`fixed_λ` optimizes at a single user-supplied `λ`. `auto_λ` searches over a range and selects the best value automatically by fitting a sigmoid to the data-penalty curve.

### Rigid vs. deformable

- **Rigid** (`RegisterOptimize.optimize_rigid`): finds the rotation + translation that best aligns two raw images. Useful as an initial pass when images differ primarily by global motion.
- **Deformable** (`fixed_λ`, `auto_λ`): finds a smooth spatially-varying warp field that aligns images locally.

## Usage

### Deformable registration at a fixed λ

```julia
using RegisterMismatch, RegisterFit, RegisterPenalty, RegisterOptimize

# 1. Compute block-wise mismatch between images
mms = mismatch_apertures(fixed, moving, aperture_centers, aperture_width, maxshift;
                         normalization=:pixels)

# 2. Fit quadratic models; get interpolated mismatch arrays
thresh = 0.5^ndims(fixed) * length(fixed) / prod(gridsize)
cs, Qs, mmis = mms2fit(mms, thresh)

# 3. Set up a deformation grid and regularization penalty
nodes = map(d -> range(1, stop=size(fixed, d), length=gridsize[d]), 1:ndims(fixed))
ap = AffinePenalty(nodes, λ)   # λ controls regularization strength

# 4. Optimize: returns the deformation and its total penalty
ϕ, penalty = fixed_λ(cs, Qs, nodes, ap, mmis)
```

`ϕ` is a `GridDeformation` from RegisterDeformation.jl. Apply it with `transform(moving, ϕ)`.

### Automatic λ selection

When you don't know a suitable `λ` in advance, let `auto_λ` find it:

```julia
ϕ, penalty, λ_best, λ_all, datapenalty, quality =
    auto_λ(fixed, moving, gridsize, maxshift, (λmin, λmax))
```

`auto_λ` tests a logarithmic sweep of `λ` values from `λmin` to `λmax`, fits a sigmoid to the data-penalty curve, and returns the deformation at the automatically chosen `λ_best`. Plot `datapenalty` vs `λ_all` (log x-axis) to verify the sigmoidal shape; if it is not sigmoidal, widen the range. A good first guess is `(λmin, λmax) = (1e-6, 100)`.

If mismatch data are already computed, pass them directly to avoid recomputing:

```julia
ϕ, penalty, λ_best, λ_all, datapenalty, quality =
    auto_λ(cs, Qs, nodes, mmis, (λmin, λmax))
```

### Rigid registration

```julia
using RegisterOptimize, CoordinateTransformations, LinearAlgebra

tform0 = AffineMap(Matrix(1.0I, 2, 2), zeros(2))   # identity initial guess
tform, fval = RegisterOptimize.optimize_rigid(fixed, moving, tform0, maxshift)
```

The returned `tform` is an `AffineMap` (rotation + translation) and `fval` is the normalized sum-of-squared-differences at the solution.

### Temporal image sequences

For a time series of images, add a temporal roughness penalty `λt` to penalize frame-to-frame variation in the deformation:

```julia
# Fixed spatial λ and temporal λt
ϕs, penalty = fixed_λ(cs, Qs, nodes, ap, mmis; λt=0.1)

# Or find a good λt automatically from the quadratic approximation
λts, datapenalty = auto_λt(Es, cs, Qs, ap, (1e-6, 1.0))
```

`ϕs` is a `Vector{GridDeformation}`, one per frame. Plot `datapenalty` vs `λts` (log x-axis) to find the "kink" where `λt` begins to constrain the optimization.
