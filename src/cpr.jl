export CPRPreconditioner
"""
Constrained pressure residual
"""
mutable struct CPRPreconditioner <: JutulPreconditioner
    A_p  # pressure system
    r_p  # pressure residual
    p    # last pressure approximation
    buf  # buffer of size equal to full system rhs
    A_ps # full system
    w_p  # pressure weights
    pressure_precond
    system_precond
    strategy
    weight_scaling
    block_size
    update_frequency::Int # Update frequency for AMG hierarchy (and pressure part if partial_update = false)
    update_interval::Symbol   # iteration, ministep, step, ...
    update_frequency_partial::Int # Update frequency for pressure system
    update_interval_partial::Symbol   # iteration, ministep, step, ...
    partial_update            # Perform partial update of AMG and update pressure system
    p_rtol::Union{Float64, Nothing}
    psolver
end

"""
    CPRPreconditioner(p = default_psolve(), s = ILUZeroPreconditioner(); strategy = :quasi_impes, weight_scaling = :unit, update_frequency = 1, update_interval = :iteration, partial_update = true)

Construct a constrained pressure residual (CPR) preconditioner.

By default, this is a AMG-BILU(0) version (algebraic multigrid for pressure, block-ILU(0) for the global system).
"""
function CPRPreconditioner(p = default_psolve(), s = ILUZeroPreconditioner();
    strategy = :quasi_impes,
    weight_scaling = :unit,
    update_frequency = 1,
    update_interval = :iteration,
    update_frequency_partial = 1,
    update_interval_partial = :iteration,
    p_rtol = nothing,
    partial_update = true
    )
    CPRPreconditioner(nothing, nothing, nothing, nothing, nothing, nothing, p, s, strategy, weight_scaling, nothing, update_frequency, update_interval, update_frequency_partial, update_interval_partial, partial_update, p_rtol, nothing)
end

function default_psolve(; max_levels = 10, max_coarse = 10, type = :smoothed_aggregation)
    gs_its = 1
    cyc = AlgebraicMultigrid.V()
    gs = GaussSeidel(ForwardSweep(), gs_its)
    return AMGPreconditioner(type, max_levels = max_levels, max_coarse = max_coarse, presmoother = gs, postsmoother = gs, cycle = cyc)
end

function update!(cpr::CPRPreconditioner, lsys, model, storage, recorder)
    rmodel = reservoir_model(model)
    ctx = rmodel.context
    update_p = update_cpr_internals!(cpr, lsys, model, storage, recorder)
    @tic "s-precond" update!(cpr.system_precond, lsys, model, storage, recorder)
    if update_p
        @tic "p-precond" update!(cpr.pressure_precond, cpr.A_p, cpr.r_p, ctx)
    elseif should_update_cpr(cpr, recorder, :partial)
        @tic "p-precond (partial)" partial_update!(cpr.pressure_precond, cpr.A_p, cpr.r_p, ctx)
    end
end

function initialize_storage!(cpr, J, s)
    if isnothing(cpr.A_p)
        m, n = size(J)
        cpr.block_size = bz = size(eltype(J), 1)
        # @assert n == m == length(s.state.Pressure) "Expected Jacobian dimensions ($m by $n) to both equal number of pressures $(length(s.state.Pressure))"
        cpr.A_p = create_pressure_matrix(J)
        cpr.r_p = zeros(n)
        cpr.buf = zeros(n*bz)
        cpr.p = zeros(n)
        cpr.w_p = zeros(bz, n)
    end
end

function create_pressure_matrix(J)
    nzval = zeros(nnz(J))
    n = size(J, 2)
    return SparseMatrixCSC(n, n, J.colptr, J.rowval, nzval)
end


function create_pressure_matrix(J::Jutul.StaticSparsityMatrixCSR)
    nzval = zeros(nnz(J))
    n = size(J, 2)
    # Assume symmetry in sparse pattern, but not values.
    return Jutul.StaticSparsityMatrixCSR(n, n, J.At.colptr, Jutul.colvals(J), nzval, nthreads = J.nthreads, minbatch = J.minbatch)
end

function update_cpr_internals!(cpr::CPRPreconditioner, lsys, model, storage, recorder)
    do_p_update = should_update_cpr(cpr, recorder, :amg)
    s = reservoir_storage(model, storage)
    A = reservoir_jacobian(lsys)
    rmodel = reservoir_model(model)
    cpr.A_ps = linear_operator(lsys)
    initialize_storage!(cpr, A, s)
    ps = rmodel.primary_variables[:Pressure].scale
    if do_p_update || cpr.partial_update
        @tic "weights" w_p = update_weights!(cpr, rmodel, s, A, ps)
        @tic "pressure system" update_pressure_system!(cpr.A_p, A, w_p, cpr.block_size, model.context)
    end
    return do_p_update
end

function update_pressure_system!(A_p, A, w_p, bz, ctx)
    nz = nonzeros(A_p)
    nz_s = nonzeros(A)
    rows = rowvals(A_p)
    @assert size(nz) == size(nz_s)
    n = A.n
    # Update the pressure system with the same pattern in-place
    tb = minbatch(ctx, n)
    @batch minbatch=tb for col in 1:n
        update_row_csc!(nz, A_p, w_p, rows, nz_s, col)
    end
end

function update_row_csc!(nz, A_p, w_p, rows, nz_s, col)
    @inbounds for j in nzrange(A_p, col)
        row = rows[j]
        Ji = nz_s[j]
        tmp = 0
        @inbounds for b in axes(Ji, 1)
            tmp += Ji[b, 1]*w_p[b, row]
        end
        nz[j] = tmp
    end
end


function update_pressure_system!(A_p::Jutul.StaticSparsityMatrixCSR, A::Jutul.StaticSparsityMatrixCSR, w_p, bz, ctx)
    T_p = eltype(A_p)
    nz = nonzeros(A_p)
    nz_s = nonzeros(A)
    cols = Jutul.colvals(A)
    @assert size(nz) == size(nz_s)
    n = size(A_p, 1)
    # Update the pressure system with the same pattern in-place
    tb = minbatch(ctx, n)
    @batch minbatch=tb for row in 1:n
        update_row_csr!(nz, A_p, w_p, cols, nz_s, row)
    end
end

function update_row_csr!(nz, A_p, w_p, cols, nz_s, row)
    @inbounds for j in nzrange(A_p, row)
        Ji = nz_s[j]
        tmp = 0
        @inbounds for b = axes(Ji, 1)
            tmp += Ji[b, 1]*w_p[b, row]
        end
        nz[j] = tmp
    end
end

function operator_nrows(cpr::CPRPreconditioner)
    return length(cpr.r_p)*cpr.block_size
end

using Krylov
function apply!(x, cpr::CPRPreconditioner, r, arg...)
    r_p, w_p, bz, Δp = cpr.r_p, cpr.w_p, cpr.block_size, cpr.p
    if false
        y = copy(r)
        # y = r
        # Construct right hand side by the weights
        norm0 = norm(r)
        do_cpr = true
        update_p_rhs!(r_p, y, bz, w_p)
        println("**************************************************************")
        # Apply preconditioner to pressure part
        @info "Before pressure correction" norm(y) norm(r_p)
        if do_cpr
            apply!(Δp, cpr.pressure_precond, r_p)
            correct_residual_for_dp!(y, x, Δp, bz, cpr.buf, cpr.A_ps)
            norm_after = norm(y)
            @info "After pressure correction" norm(y) norm(cpr.A_p*Δp - r_p) norm_after/norm0
        end
        apply!(x, cpr.system_precond, y)
        if do_cpr
            @info "After second stage" norm(cpr.A_ps*x - y)
            increment_pressure!(x, Δp, bz)
        end
        @info "Final" norm(cpr.A_ps*x - r) norm(cpr.A_ps*x - r)/norm0
    else
        y = r
        # Construct right hand side by the weights
        @tic "p rhs" update_p_rhs!(r_p, y, bz, w_p)
        # Apply preconditioner to pressure part
        @tic "p apply" begin
            p_rtol = cpr.p_rtol
            p_precond = cpr.pressure_precond
            cpr_p_apply!(Δp, cpr, p_precond, r_p, p_rtol)
        end
        @tic "r update" correct_residual_for_dp!(y, x, Δp, bz, cpr.buf, cpr.A_ps)
        @tic "s apply" apply!(x, cpr.system_precond, y)
        @tic "Δp" increment_pressure!(x, Δp, bz)
    end
end


function cpr_p_apply!(Δp, cpr, p_precond, r_p, p_rtol)
    apply!(Δp, p_precond, r_p)
    if !isnothing(p_rtol)
        A_p = cpr.A_p
        if isnothing(cpr.psolver)
            cpr.psolver = FgmresSolver(A_p, r_p)
        end
        psolve = cpr.psolver
        warm_start!(psolve, Δp)
        M = Jutul.PrecondWrapper(linear_operator(p_precond))
        fgmres!(psolve, A_p, r_p, M = M, rtol = p_rtol, atol = 1e-12, itmax = 20)
        @. Δp = psolve.x
    end
end

reservoir_residual(lsys) = lsys.r
reservoir_jacobian(lsys) = lsys.jac

function reservoir_residual(lsys::MultiLinearizedSystem)
    return lsys[1, 1].r
end

function reservoir_jacobian(lsys::MultiLinearizedSystem)
    return lsys[1, 1].jac
end

function update_weights!(cpr, model, res_storage, J, ps)
    n = size(cpr.A_p, 1)
    bz = cpr.block_size
    if isnothing(cpr.w_p)
        cpr.w_p = ones(bz, n)
    end
    w = cpr.w_p
    r = zeros(bz)
    r[1] = 1.0
    scaling = cpr.weight_scaling
    if cpr.strategy == :true_impes
        eq_s = res_storage.equations[:mass_conservation]
        if eq_s isa ConservationLawTPFAStorage
            acc = eq_s.accumulation.entries
        else
            acc = res_storage.state.TotalMasses
            # This term isn't scaled by dt, so use simple weights instead
            ps = 1.0
        end
        true_impes!(w, acc, r, n, bz, ps, scaling)
    elseif cpr.strategy == :analytical
        rstate = res_storage.state
        cpr_weights_no_partials!(w, model, rstate, r, n, bz, scaling)
    elseif cpr.strategy == :quasi_impes
        quasi_impes!(w, J, r, n, bz, scaling)
    elseif cpr.strategy == :none
        # Do nothing. Already set to one.
    else
        error("Unsupported strategy $(cpr.strategy)")
    end
    return w
end

function true_impes!(w, acc, r, n, bz, arg...)
    if bz == 2
        # Hard coded variants
        true_impes_2!(w, acc, r, n, bz, arg...)
    elseif bz == 3
        true_impes_3!(w, acc, r, n, bz, arg...)
    elseif bz == 4
        true_impes_4!(w, acc, r, n, bz, arg...)
    elseif bz == 5
        true_impes_5!(w, acc, r, n, bz, arg...)
    elseif bz == 8
        true_impes_8!(w, acc, r, n, bz, arg...)
    else
        true_impes_gen!(w, acc, r, n, bz, arg...)
    end
end

function true_impes_2!(w, acc, r, n, bz, p_scale, scaling)
    r_p = SVector{2}(r)
    @inbounds for cell in 1:n
        W = acc[1, cell]
        O = acc[2, cell]

        ∂W∂p = W.partials[1]*p_scale
        ∂O∂p = O.partials[1]*p_scale

        ∂W∂s = W.partials[2]
        ∂O∂s = O.partials[2]

        A = @SMatrix [∂W∂p ∂O∂p; 
                      ∂W∂s ∂O∂s]
        invert_w!(w, A, r_p, cell, bz, scaling)
    end
end

function M_entry(acc, i, j, c)
    return @inbounds acc[j, c].partials[i]
end

# TODO: Turn these into @generated functions

function true_impes_3!(w, acc, r, n, bz, s, scaling)
    r_p = SVector{3}(r)
    f(i, j, c) = M_entry(acc, i, j, c)
    for c in 1:n
        A = @SMatrix    [s*f(1, 1, c) s*f(1, 2, c) s*f(1, 3, c);
                           f(2, 1, c) f(2, 2, c) f(2, 3, c);
                           f(3, 1, c) f(3, 2, c) f(3, 3, c)]
        invert_w!(w, A, r_p, c, bz, scaling)
    end
end

function true_impes_4!(w, acc, r, n, bz, s, scaling)
    r_p = SVector{4}(r)
    f(i, j, c) = M_entry(acc, i, j, c)
    for c in 1:n
        A = @SMatrix    [s*f(1, 1, c) s*f(1, 2, c) s*f(1, 3, c) s*f(1, 4, c);
                           f(2, 1, c) f(2, 2, c) f(2, 3, c) f(2, 4, c);
                           f(3, 1, c) f(3, 2, c) f(3, 3, c) f(3, 4, c);
                           f(4, 1, c) f(4, 2, c) f(4, 3, c) f(4, 4, c)]
        invert_w!(w, A, r_p, c, bz, scaling)
    end
end

function true_impes_5!(w, acc, r, n, bz, s, scaling)
    r_p = SVector{5}(r)
    f(i, j, c) = M_entry(acc, i, j, c)
    for c in 1:n
        A = @SMatrix    [s*f(1, 1, c) s*f(1, 2, c) s*f(1, 3, c) s*f(1, 4, c) s*f(1, 5, c);
                         f(2, 1, c) f(2, 2, c) f(2, 3, c) f(2, 4, c) f(2, 5, c);
                         f(3, 1, c) f(3, 2, c) f(3, 3, c) f(3, 4, c) f(3, 5, c);
                         f(4, 1, c) f(4, 2, c) f(4, 3, c) f(4, 4, c) f(4, 5, c);
                         f(5, 1, c) f(5, 2, c) f(5, 3, c) f(5, 4, c) f(5, 5, c)]
        invert_w!(w, A, r_p, c, bz, scaling)
    end
end

function true_impes_8!(w, acc, r, n, bz, s, scaling)
    r_p = SVector{8}(r)
    f(i, j, c) = M_entry(acc, i, j, c)
    for c in 1:n
        A = @SMatrix    [s*f(1, 1, c) s*f(1, 2, c) s*f(1, 3, c) s*f(1, 4, c) s*f(1, 5, c) s*f(1, 6, c) s*f(1, 7, c) s*f(1, 8, c);
                         f(2, 1, c) f(2, 2, c) f(2, 3, c) f(2, 4, c) f(2, 5, c) f(2, 6, c) f(2, 7, c) f(2, 8, c);
                         f(3, 1, c) f(3, 2, c) f(3, 3, c) f(3, 4, c) f(3, 5, c) f(3, 6, c) f(3, 7, c) f(3, 8, c);
                         f(4, 1, c) f(4, 2, c) f(4, 3, c) f(4, 4, c) f(4, 5, c) f(4, 6, c) f(4, 7, c) f(4, 8, c);
                         f(5, 1, c) f(5, 2, c) f(5, 3, c) f(5, 4, c) f(5, 5, c) f(5, 6, c) f(5, 7, c) f(5, 8, c);
                         f(6, 1, c) f(6, 2, c) f(6, 3, c) f(6, 4, c) f(6, 5, c) f(6, 6, c) f(6, 7, c) f(6, 8, c);
                         f(7, 1, c) f(7, 2, c) f(7, 3, c) f(7, 4, c) f(7, 5, c) f(7, 6, c) f(7, 7, c) f(7, 8, c);
                         f(8, 1, c) f(8, 2, c) f(8, 3, c) f(8, 4, c) f(8, 5, c) f(8, 6, c) f(8, 7, c) f(8, 8, c)]
        invert_w!(w, A, r_p, c, bz, scaling)
    end
end

function true_impes_gen!(w, acc, r, n, bz, p_scale, scaling)
    r_p = SVector{bz}(r)
    A = MMatrix{bz, bz, eltype(r)}(zeros(bz, bz))
    for cell in 1:n
        @inbounds for i = 1:bz
            v = acc[i, cell]
            @inbounds A[1, i] = v.partials[1]*p_scale
            @inbounds for j = 2:bz
                A[j, i] = v.partials[j]
            end
        end
        invert_w!(w, A, r_p, cell, bz, scaling)
    end
end

function quasi_impes!(w, J, r, n, bz, scaling)
    r_p = SVector{bz}(r)
    @batch for cell = 1:n
        J_b = J[cell, cell]'
        invert_w!(w, J_b, r_p, cell, bz, scaling)
    end
end

@inline function invert_w!(w, J, r, cell, bz, scaling)
    tmp = J\r
    if scaling == :unit
        s = 1.0/norm(tmp)
    else
        s = 1.0
    end
    @inbounds for i = 1:bz
        w[i, cell] = tmp[i]*s
    end
end

function update_p_rhs!(r_p, y, bz, w_p)
    if false
        @batch minbatch = 1000 for i in eachindex(r_p)
            v = 0.0
            @inbounds for b = 1:bz
                v += y[(i-1)*bz + b]*w_p[b, i]
            end
            @inbounds r_p[i] = v
        end
    end
    n = length(y) ÷ bz
    yv = reshape(y, bz, n)
    @tullio r_p[i] = yv[b, i]*w_p[b, i]
end

function correct_residual_for_dp!(y, x, Δp, bz, buf, A)
    # x = x' + Δx
    # A (x' + Δx) = y
    # A x' = y'
    # y' = y - A*Δx
    # x = A \ y' + Δx
    @batch minbatch = 1000 for i in eachindex(Δp)
        set_dp!(x, bz, Δp, i)
    end
    mul!(y, A, x, -1.0, true)
end

@inline function set_dp!(x, bz, Δp, i)
    @inbounds x[(i-1)*bz + 1] = Δp[i]
    @inbounds for j = 2:bz
        x[(i-1)*bz + j] = 0.0
    end
end

function increment_pressure!(x, Δp, bz)
    @inbounds for i in eachindex(Δp)
        x[(i-1)*bz + 1] += Δp[i]
    end
end


function should_update_pressure_subsystem(cpr, rec)
    interval = cpr.update_interval
    if isnothing(cpr.A_p)
        update = true
    elseif interval == :once
        update = false
    else
        it = Jutul.subiteration(rec)
        outer_step = Jutul.step(rec)
        ministep = Jutul.substep(rec)
        if interval == :iteration
            crit = true
            n = it
        elseif interval == :ministep
            n = ministep
            crit = it == 1
        elseif interval == :step
            n = outer_step
            crit = it == 1
        else
            error("Bad parameter update_frequency: $interval")
        end
        uf = cpr.update_frequency
        update = crit && (uf == 1 || (n % uf) == 1)
    end
    return update
end

function should_update_cpr(cpr, rec, type = :amg)
    if type == :partial
        interval, update_frequency = cpr.update_interval_partial, cpr.update_frequency_partial
    else
        @assert type == :amg
        interval, update_frequency = cpr.update_interval, cpr.update_frequency
    end
    if isnothing(cpr.A_p)
        update = true
    elseif interval == :once
        update = false
    else
        it = Jutul.subiteration(rec)
        outer_step = Jutul.step(rec)
        ministep = Jutul.substep(rec)
        if interval == :iteration
            crit = true
            n = it
        elseif interval == :ministep
            n = ministep
            crit = it == 1
        elseif interval == :step
            n = outer_step
            crit = it == 1
        else
            error("Bad parameter update_frequency: $interval")
        end
        uf = update_frequency
        update = crit && (uf == 1 || (n % uf) == 1)
    end
    return update
end