# Changelog

## v1.0.0

**Breaking changes**

- `initial_deformation(ap, cs, Qs, ϕ_old, maxshift)` removed. The method body was
  `error("This is broken, don't use it")` and is gone entirely.

- `optimize(tform::AffineMap, mmis, nodes)` removed. Used a deprecated Optim API
  (`interior`/`DifferentiableFunction`/`At_mul_Bt!`) that no longer exists.

- `auto_λ`: the `stackidx::Integer` positional-first-argument overload is removed.
  Pass `stackidx` as a keyword instead:
  ```julia
  # before
  auto_λ(stackidx, cs, Qs, nodes, mmis, λrange)
  # after
  auto_λ(cs, Qs, nodes, mmis, λrange; stackidx)
  ```

- `optimize_rigid`: `SD` and `maxrot` are now keyword arguments (no defaults
  change); `tol` is renamed `atol`; additional keyword arguments are forwarded
  to Ipopt:
  ```julia
  # before
  optimize_rigid(fixed, moving, tform0, maxshift, SD, maxrot; tol=1e-4)
  # after
  optimize_rigid(fixed, moving, tform0, maxshift; SD, maxrot, atol=1e-4)
  ```

- `rotation_gridsearch`: `SD` is now a keyword argument:
  ```julia
  # before
  rotation_gridsearch(fixed, moving, maxshift, maxradians, rgridsz, SD)
  # after
  rotation_gridsearch(fixed, moving, maxshift, maxradians, rgridsz; SD)
  ```

- `initial_deformation`, `optimize!` (time-series), and `fixed_λ`: the temporal
  penalty coefficient `λt` is now a keyword argument (default `nothing`):
  ```julia
  # before
  initial_deformation(ap, λt, cs, Qs)
  optimize!(ϕs, ϕs_old, dp, λt, mmis)
  fixed_λ(cs, Qs, nodes, ap, λt, mmis)
  # after
  initial_deformation(ap, cs, Qs; λt)
  optimize!(ϕs, ϕs_old, dp, mmis; λt)
  fixed_λ(cs, Qs, nodes, ap, mmis; λt)
  ```

- `auto_λt` flat-array adapter overload removed. Pass SVector/SMatrix-typed
  `cs`/`Qs` directly to the main `auto_λt(Es, cs, Qs, ap, λtrange)` overload.

**Non-breaking improvements**

- `auto_λ` flat-array overloads now accept `AbstractArray{<:Number}` and
  `AbstractArray{Float64}` instead of requiring `Array{Tf}` / `Array{Float64}`,
  allowing views and other array wrappers.

- `auto_λ` flat-array overload: the element types of `cs`, `Qs`, and `mmis` are
  now independent (previously all three had to share the same `Tf`).
