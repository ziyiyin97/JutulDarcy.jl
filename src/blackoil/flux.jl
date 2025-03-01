@inline function component_mass_fluxes!(q, face, state, model::StandardBlackOilModel, kgrad, upw)
    sys = model.system
    a, l, v = phase_indices(sys)
    rhoAS, rhoLS, rhoVS = reference_densities(sys)
    kdisc = kgrad_common(face, state, model, kgrad)

    # Get the potentials since the flux is more complicated for miscible phases
    potential(phase) = darcy_phase_kgrad_potential(face, phase, state, model, kgrad, kdisc)

    b_mob = state.SurfaceVolumeMobilities
    # Water component is the aqueous phase only
    ψ_a = potential(a)
    λb_a = phase_upwind(upw, b_mob, a, ψ_a)
    q_a = rhoAS*λb_a*ψ_a

    # Oil mobility
    ψ_l = potential(l)
    λb_l = phase_upwind(upw, b_mob, l, ψ_l)
    # Gas mobility
    ψ_v = potential(v)
    λb_v = phase_upwind(upw, b_mob, v, ψ_v)

    # Rv (vaporized oil) upwinded by vapor potential
    Rv = state.Rv
    f_rv = cell -> @inbounds Rv[cell]
    rv = upwind(upw, f_rv, ψ_v)
    # Final flux = oil phase flux + oil-in-gas flux
    q_l = rhoLS*(λb_l*ψ_l + rv*λb_v*ψ_v)

    # Rs (solute gas) upwinded by liquid potential
    Rs = state.Rs
    f_rs = cell -> @inbounds Rs[cell]
    rs = upwind(upw, f_rs, ψ_l)
    # Final flux = gas phase flux + gas-in-oil flux
    q_v = rhoVS*(λb_v*ψ_v + rs*λb_l*ψ_l)

    q = setindex(q, q_a, a)
    q = setindex(q, q_l, l)
    q = setindex(q, q_v, v)
    return q
end

@inline function component_mass_fluxes!(q, face, state, model::VapoilBlackOilModel, kgrad, upw)
    sys = model.system
    a, l, v = phase_indices(sys)
    rhoAS, rhoLS, rhoVS = reference_densities(sys)
    kdisc = kgrad_common(face, state, model, kgrad)

    # Get the potentials since the flux is more complicated for miscible phases
    potential(phase) = darcy_phase_kgrad_potential(face, phase, state, model, kgrad, kdisc)

    b_mob = state.SurfaceVolumeMobilities
    # Water component is the aqueous phase only
    ψ_a = potential(a)
    λb_a = phase_upwind(upw, b_mob, a, ψ_a)
    q_a = rhoAS*λb_a*ψ_a

    # Oil mobility
    ψ_l = potential(l)
    λb_l = phase_upwind(upw, b_mob, l, ψ_l)
    # Gas mobility
    ψ_v = potential(v)
    λb_v = phase_upwind(upw, b_mob, v, ψ_v)

    # Rv (vaporized oil) upwinded by vapor potential
    Rv = state.Rv
    f_rv = cell -> @inbounds Rv[cell]
    rv = upwind(upw, f_rv, ψ_v)
    # Final flux = oil phase flux + oil-in-gas flux
    q_l = rhoLS*(λb_l*ψ_l + rv*λb_v*ψ_v)
    # Vapor flux is simple
    q_v = rhoVS*λb_v*ψ_v

    q = setindex(q, q_a, a)
    q = setindex(q, q_l, l)
    q = setindex(q, q_v, v)
    return q
end

@inline function component_mass_fluxes!(q, face, state, model::DisgasBlackOilModel, kgrad, upw)
    sys = model.system
    has_water = has_other_phase(sys)
    if has_water
        a, l, v = phase_indices(sys)
        rhoAS, rhoLS, rhoVS = reference_densities(sys)
    else
        l, v = phase_indices(sys)
        rhoLS, rhoVS = reference_densities(sys)
    end
    kdisc = kgrad_common(face, state, model, kgrad)

    # Get the potentials since the flux is more complicated for miscible phases
    potential(phase) = darcy_phase_kgrad_potential(face, phase, state, model, kgrad, kdisc)

    b_mob = state.SurfaceVolumeMobilities
    if has_water
        # Water component is the aqueous phase only
        ψ_a = potential(a)
        λb_a = phase_upwind(upw, b_mob, a, ψ_a)
        q_a = rhoAS*λb_a*ψ_a
        q = setindex(q, q_a, a)
    end
    # Oil component is the oil phase only
    ψ_l = potential(l)
    λb_l = phase_upwind(upw, b_mob, l, ψ_l)
    q_l = rhoLS*λb_l*ψ_l
    # Gas mobility
    ψ_v = potential(v)
    λb_v = phase_upwind(upw, b_mob, v, ψ_v)
    # Rs (solute gas) upwinded by liquid potential
    Rs = state.Rs
    f_rs = cell -> @inbounds Rs[cell]
    rs = upwind(upw, f_rs, ψ_l)
    # Final flux = gas phase flux + gas-in-oil flux
    q_v = rhoVS*(λb_v*ψ_v + rs*λb_l*ψ_l)

    q = setindex(q, q_l, l)
    q = setindex(q, q_v, v)
    return q
end


function apply_flow_bc!(acc, q, bc, model::StandardBlackOilModel, state, time)
    mu = state.PhaseViscosities
    b = state.ShrinkageFactors
    kr = state.RelativePermeabilities
    rho = state.PhaseMassDensities
    nph = length(acc)
    @assert size(kr, 1) == nph

    rho_inj = bc.density
    f_inj = bc.fractional_flow
    c = bc.cell
    sys = model.system
    if q > 0
        # Pressure inside is higher than outside, flow out from domain
        phases = phase_indices(sys)
        wat = has_other_phase(sys)
        rhoS = reference_densities(sys)

        if wat
            a, l, v = phases
        else
            l, v = phases
        end

        if wat
            acc[a] += q*rho[a, c]*kr[a, c]/mu[a, c]
        end
        q_l = q_v = 0.0
        q = q*b[l, c]*kr[l, c]/mu[l, c]
        if has_disgas(sys)
            q_v += state.Rs[c]*q
        end
        q_l += q

        q = q*b[v, c]*kr[v, c]/mu[v, c]
        if has_vapoil(sys)
            q_l += state.Rv[c]*q
        end
        q_v += q

        acc[l] += q_l*rhoS[l]
        acc[v] += q_v*rhoS[v]
    else
        # Injection of mass
        λ_t = 0.0
        for ph in eachindex(acc)
            λ_t += kr[ph, c]/mu[ph, c]
        end
        if isnothing(rho_inj)
            # Density not provided, take saturation average from what we have in
            # the inside of the domain
            rho_inj = 0.0
            for ph in 1:nph
                rho_inj += state.Saturations[ph, c]*rho[ph, c]
            end
        end
        if isnothing(f_inj)
            # Fractional flow not provided. We match the mass fraction we
            # observe on the inside.
            total = 0.0
            for ph in 1:nph
                total += state.TotalMasses[ph, c]
            end
            for ph in 1:nph
                F = state.TotalMasses[ph, c]/total
                acc[ph] += q*rho_inj*λ_t*F
            end
        else
            @assert length(f_inj) == nph
            for ph in 1:nph
                F = f_inj[ph]
                acc[ph] += q*rho_inj*λ_t*F
            end
        end
    end
end