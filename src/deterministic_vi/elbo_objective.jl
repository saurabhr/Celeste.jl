"""
Convolve the current locations and galaxy shapes with the PSF.  If
calculate_derivs is true, also calculate derivatives and hessians for
active sources.

Args:
 - psf: A vector of PSF components
 - ea: The current ElboArgs
 - b: The current band
 - calculate_derivs: Whether to calculate derivatives for active sources.

Returns:
 - star_mcs: An array of BvnComponents with indices
    - PSF component
    - Source (index within active_sources)
 - gal_mcs: An array of BvnComponents with indices
    - PSF component
    - Galaxy component
    - Galaxy type
    - Source (index within active_sources)
  Hessians are only populated for s in ea.active_sources.
"""
function load_bvn_mixtures{NumType <: Number}(
                    ea::ElboArgs{NumType},
                    b::Int;
                    calculate_derivs::Bool=true,
                    calculate_hessian::Bool=true)
    # call bvn loader from the Model Module
    Model.load_bvn_mixtures(ea.S, ea.patches, ea.vp, ea.active_sources,
                            ea.psf_K, b,
                            calculate_derivs=calculate_derivs,
                            calculate_hessian=calculate_hessian)
end


"""
Add the contributions of a star's bivariate normal term to the ELBO,
by updating elbo_vars.fs0m_vec[s] in place.

Args:
    - elbo_vars: Elbo intermediate values.
    - s: The index of the current source in 1:S
    - bmc: The component to be added
    - x: An offset for the component in pixel coordinates (e.g. a pixel location)
    - wcs_jacobian: The jacobian of the function pixel = F(world) at this location.
    - is_active_source: Whether it is an active source, (i.e. whether to
                        calculate derivatives if requested.)

Returns:
    Updates elbo_vars.fs0m_vec[s] in place.
"""
function accum_star_pos!{NumType <: Number}(
                    elbo_vars::ElboIntermediateVariables{NumType},
                    s::Int,
                    bmc::BvnComponent{NumType},
                    x::SVector{2, Float64},
                    wcs_jacobian::Array{Float64, 2},
                    is_active_source::Bool)
    # call accum star pos in model
    Model.accum_star_pos!(elbo_vars.bvn_derivs,
                    elbo_vars.fs0m_vec,
                    elbo_vars.calculate_derivs,
                    elbo_vars.calculate_hessian,
                    s, bmc, x, wcs_jacobian, is_active_source)
end


"""
Add the contributions of a galaxy component term to the ELBO by
updating fs1m in place.

Args:
    - elbo_vars: Elbo intermediate variables
    - s: The index of the current source in 1:S
    - gcc: The galaxy component to be added
    - x: An offset for the component in pixel coordinates (e.g. a pixel location)
    - wcs_jacobian: The jacobian of the function pixel = F(world) at this location.
    - is_active_source: Whether it is an active source, (i.e. whether to
                        calculate derivatives if requested.)

Returns:
    Updates elbo_vars.fs1m_vec[s] in place.
"""
function accum_galaxy_pos!{NumType <: Number}(
                    elbo_vars::ElboIntermediateVariables{NumType},
                    s::Int,
                    gcc::GalaxyCacheComponent{NumType},
                    x::SVector{2, Float64},
                    wcs_jacobian::Array{Float64, 2},
                    is_active_source::Bool)
    # call accum star pos in model
    Model.accum_galaxy_pos!(elbo_vars.bvn_derivs,
                            elbo_vars.fs1m_vec,
                            elbo_vars.calculate_derivs,
                            elbo_vars.calculate_hessian,
                            s, gcc, x, wcs_jacobian, is_active_source)
end


"""
Calculate the contributions of a single source for a single pixel to
the sensitive floats E_G_s and var_G_s, which are cleared and updated in place.

Args:
    - elbo_vars: Elbo intermediate values, with updated fs1m_vec and fs0m_vec.
    - ea: Model parameters
    - E_G_s, var_G_s: The expectation  and variance of the brightnesses of this
          source at this pixel, updated in place.
    - fs0m, fs1m: The star and galaxy shape parameters for this source at
          this pixel.
    - sb: Source brightnesse
    - s: The source, in 1:ea.S
    - b: The band

Returns:
    Updates E_G_s and var_G_s in place with the brightness
    for this source at this pixel.
"""
function calculate_source_pixel_brightness!{NumType <: Number}(
                    elbo_vars::ElboIntermediateVariables{NumType},
                    ea::ElboArgs{NumType},
                    E_G_s::SensitiveFloat{CanonicalParams, NumType},
                    var_G_s::SensitiveFloat{CanonicalParams, NumType},
                    fs0m::SensitiveFloat{StarPosParams, NumType},
                    fs1m::SensitiveFloat{GalaxyPosParams, NumType},
                    sb::SourceBrightness{NumType},
                    b::Int, s::Int,
                    is_active_source::Bool)
    E_G2_s = elbo_vars.E_G2_s

    clear_hessian = elbo_vars.calculate_hessian && elbo_vars.calculate_derivs
    clear!(E_G_s, clear_hessian)
    clear!(E_G2_s, clear_hessian)

    @inbounds for i in 1:Ia # Stars and galaxies
        fsm_i = (i == 1) ? fs0m : fs1m
        a_i = ea.vp[s][ids.a[i, 1]]

        lf = sb.E_l_a[b, i].v[1] * fsm_i.v[1]
        llff = sb.E_ll_a[b, i].v[1] * fsm_i.v[1]^2

        E_G_s.v[1] += a_i * lf
        E_G2_s.v[1] += a_i * llff

        # Only calculate derivatives for active sources.
        if is_active_source && elbo_vars.calculate_derivs
            ######################
            # Gradients.

            E_G_s.d[ids.a[i, 1], 1] += lf
            E_G2_s.d[ids.a[i, 1], 1] += llff

            p0_shape = shape_standard_alignment[i]
            p0_bright = brightness_standard_alignment[i]
            u_ind = i == 1 ? star_ids.u : gal_ids.u

            # Derivatives with respect to the spatial parameters
            for p0_shape_ind in 1:length(p0_shape)
                E_G_s.d[p0_shape[p0_shape_ind], 1] +=
                    sb.E_l_a[b, i].v[1] * a_i * fsm_i.d[p0_shape_ind, 1]
                E_G2_s.d[p0_shape[p0_shape_ind], 1] +=
                    sb.E_ll_a[b, i].v[1] * 2 * fsm_i.v[1] * a_i * fsm_i.d[p0_shape_ind, 1]
            end

            # Derivatives with respect to the brightness parameters.
            for p0_bright_ind in 1:length(p0_bright)
                E_G_s.d[p0_bright[p0_bright_ind], 1] +=
                    a_i * fsm_i.v[1] * sb.E_l_a[b, i].d[p0_bright_ind, 1]
                E_G2_s.d[p0_bright[p0_bright_ind], 1] +=
                    a_i * (fsm_i.v[1]^2) * sb.E_ll_a[b, i].d[p0_bright_ind, 1]
            end

            if elbo_vars.calculate_hessian
                ######################
                # Hessians.

                # Data structures to accumulate certain submatrices of the Hessian.
                E_G_s_hsub = elbo_vars.E_G_s_hsub_vec[i]
                E_G2_s_hsub = elbo_vars.E_G2_s_hsub_vec[i]

                # The (a, a) block of the hessian is zero.

                # The (bright, bright) block:
                for p0_ind1 in 1:length(p0_bright), p0_ind2 in 1:length(p0_bright)
                    # TODO: time consuming **************
                    E_G_s.h[p0_bright[p0_ind1], p0_bright[p0_ind2]] =
                        a_i * sb.E_l_a[b, i].h[p0_ind1, p0_ind2] * fsm_i.v[1]
                    E_G2_s.h[p0_bright[p0_ind1], p0_bright[p0_ind2]] =
                        (fsm_i.v[1]^2) * a_i * sb.E_ll_a[b, i].h[p0_ind1, p0_ind2]
                end

                # The (shape, shape) block:
                p1, p2 = size(E_G_s_hsub.shape_shape)
                for ind1 = 1:p1, ind2 = 1:p2
                    E_G_s_hsub.shape_shape[ind1, ind2] =
                        a_i * sb.E_l_a[b, i].v[1] * fsm_i.h[ind1, ind2]
                    E_G2_s_hsub.shape_shape[ind1, ind2] =
                        2 * a_i * sb.E_ll_a[b, i].v[1] * (
                            fsm_i.v[1] * fsm_i.h[ind1, ind2] +
                            fsm_i.d[ind1, 1] * fsm_i.d[ind2, 1])
                end

                # The u_u submatrix of this assignment will be overwritten after
                # the loop.
                for p0_ind1 in 1:length(p0_shape), p0_ind2 in 1:length(p0_shape)
                    E_G_s.h[p0_shape[p0_ind1], p0_shape[p0_ind2]] =
                        a_i * sb.E_l_a[b, i].v[1] * fsm_i.h[p0_ind1, p0_ind2]
                    E_G2_s.h[p0_shape[p0_ind1], p0_shape[p0_ind2]] =
                        E_G2_s_hsub.shape_shape[p0_ind1, p0_ind2]
                end

                # Since the u_u submatrix is not disjoint between different i, accumulate
                # it separate and add it at the end.
                for u_ind1 = 1:2, u_ind2 = 1:2
                    E_G_s_hsub.u_u[u_ind1, u_ind2] =
                        E_G_s_hsub.shape_shape[u_ind[u_ind1], u_ind[u_ind2]]
                    E_G2_s_hsub.u_u[u_ind1, u_ind2] =
                        E_G2_s_hsub.shape_shape[u_ind[u_ind1], u_ind[u_ind2]]
                end

                # All other terms are disjoint between different i and don't involve
                # addition, so we can just assign their values (which is efficient in
                # native julia).

                # The (a, bright) blocks:
                for p0_ind in 1:length(p0_bright)
                    E_G_s.h[p0_bright[p0_ind], ids.a[i, 1]] =
                        fsm_i.v[1] * sb.E_l_a[b, i].d[p0_ind, 1]
                    E_G2_s.h[p0_bright[p0_ind], ids.a[i, 1]] =
                        (fsm_i.v[1] ^ 2) * sb.E_ll_a[b, i].d[p0_ind, 1]
                    E_G_s.h[ids.a[i, 1], p0_bright[p0_ind]] =
                        E_G_s.h[p0_bright[p0_ind], ids.a[i, 1]]
                    E_G2_s.h[ids.a[i, 1], p0_bright[p0_ind]] =
                        E_G2_s.h[p0_bright[p0_ind], ids.a[i, 1]]
                end

                # The (a, shape) blocks.
                for p0_ind in 1:length(p0_shape)
                    E_G_s.h[p0_shape[p0_ind], ids.a[i, 1]] =
                        sb.E_l_a[b, i].v[1] * fsm_i.d[p0_ind, 1]
                    E_G2_s.h[p0_shape[p0_ind], ids.a[i, 1]] =
                        sb.E_ll_a[b, i].v[1] * 2 * fsm_i.v[1] * fsm_i.d[p0_ind, 1]
                    E_G_s.h[ids.a[i, 1], p0_shape[p0_ind]] =
                        E_G_s.h[p0_shape[p0_ind], ids.a[i, 1]]
                    E_G2_s.h[ids.a[i, 1], p0_shape[p0_ind]] =
                        E_G2_s.h[p0_shape[p0_ind], ids.a[i, 1]]
                end

                for ind_b in 1:length(p0_bright), ind_s in 1:length(p0_shape)
                    E_G_s.h[p0_bright[ind_b], p0_shape[ind_s]] =
                        a_i * sb.E_l_a[b, i].d[ind_b, 1] * fsm_i.d[ind_s, 1]
                    E_G2_s.h[p0_bright[ind_b], p0_shape[ind_s]] =
                        2 * a_i * sb.E_ll_a[b, i].d[ind_b, 1] * fsm_i.v[1] * fsm_i.d[ind_s]

                    E_G_s.h[p0_shape[ind_s], p0_bright[ind_b]] =
                        E_G_s.h[p0_bright[ind_b], p0_shape[ind_s]]
                    E_G2_s.h[p0_shape[ind_s], p0_bright[ind_b]] =
                        E_G2_s.h[p0_bright[ind_b], p0_shape[ind_s]]
                end
            end # if calculate hessian
        end # if calculate derivatives
    end # i loop

    @inbounds if elbo_vars.calculate_hessian
        # Accumulate the u Hessian. u is the only parameter that is shared between
        # different values of i.

        # This is
        # for i = 1:Ia
        #     E_G_u_u_hess += elbo_vars.E_G_s_hsub_vec[i].u_u
        #     E_G2_u_u_hess += elbo_vars.E_G2_s_hsub_vec[i].u_u
        # end
        # For each value in 1:Ia, written this way for speed.
        @assert Ia == 2
        for u_ind1 = 1:2, u_ind2 = 1:2
            E_G_s.h[ids.u[u_ind1], ids.u[u_ind2]] =
            elbo_vars.E_G_s_hsub_vec[1].u_u[u_ind1, u_ind2] +
            elbo_vars.E_G_s_hsub_vec[2].u_u[u_ind1, u_ind2]

            E_G2_s.h[ids.u[u_ind1], ids.u[u_ind2]] =
                elbo_vars.E_G2_s_hsub_vec[1].u_u[u_ind1, u_ind2] +
                elbo_vars.E_G2_s_hsub_vec[2].u_u[u_ind1, u_ind2]
        end
    end

    calculate_var_G_s!(elbo_vars, E_G_s, E_G2_s, var_G_s, is_active_source)
end


function calculate_source_pixel_brightness!{NumType <: Number}(
                    elbo_vars::ElboIntermediateVariables{NumType},
                    ea::ElboArgs{NumType},
                    sbs::Vector{SourceBrightness{NumType}},
                    s::Int, b::Int)

    calculate_source_pixel_brightness!(
        elbo_vars,
        ea,
        elbo_vars.E_G_s,
        elbo_vars.var_G_s,
        elbo_vars.fs0m_vec[s],
        elbo_vars.fs1m_vec[s],
        sbs[s],
        b, s,
        s in ea.active_sources)
end


"""
Calculate the variance var_G_s as a function of (E_G_s, E_G2_s).

Args:
    - elbo_vars: Elbo intermediate values.
    - E_G_s: The expected brightness for a source
    - E_G2_s: The expected squared brightness for a source
    - var_G_s: Updated in place.  The variance of the brightness of a source.
    - is_active_source: Whether this is an active source that requires derivatives

Returns:
    Updates var_G_s in place.
"""
function calculate_var_G_s!{NumType <: Number}(
                    elbo_vars::ElboIntermediateVariables{NumType},
                    E_G_s::SensitiveFloat{CanonicalParams, NumType},
                    E_G2_s::SensitiveFloat{CanonicalParams, NumType},
                    var_G_s::SensitiveFloat{CanonicalParams, NumType},
                    is_active_source::Bool)
    clear!(var_G_s,
           elbo_vars.calculate_hessian &&
           elbo_vars.calculate_derivs && is_active_source)

    var_G_s.v[1] = E_G2_s.v[1] - (E_G_s.v[1] ^ 2)

    if is_active_source && elbo_vars.calculate_derivs
        @assert length(var_G_s.d) == length(E_G2_s.d) == length(E_G_s.d)
        @inbounds for ind1 = 1:length(var_G_s.d)
            var_G_s.d[ind1] = E_G2_s.d[ind1] - 2 * E_G_s.v[1] * E_G_s.d[ind1]
        end

        if elbo_vars.calculate_hessian
            p1, p2 = size(var_G_s.h)
            @inbounds for ind2 = 1:p2, ind1 = 1:ind2
                var_G_s.h[ind1, ind2] =
                    E_G2_s.h[ind1, ind2] - 2 * (
                        E_G_s.v[1] * E_G_s.h[ind1, ind2] +
                        E_G_s.d[ind1, 1] * E_G_s.d[ind2, 1])
                var_G_s.h[ind2, ind1] = var_G_s.h[ind1, ind2]
            end
        end
    end
end


"""
Add the contributions from a single source at a single pixel to the
sensitive floast E_G and var_G, which are updated in place.
"""
function accumulate_source_pixel_brightness!{NumType <: Number}(
                    elbo_vars::ElboIntermediateVariables{NumType},
                    ea::ElboArgs{NumType},
                    E_G::SensitiveFloat{CanonicalParams, NumType},
                    var_G::SensitiveFloat{CanonicalParams, NumType},
                    fs0m::SensitiveFloat{StarPosParams, NumType},
                    fs1m::SensitiveFloat{GalaxyPosParams, NumType},
                    sb::SourceBrightness{NumType},
                    b::Int, s::Int,
                    is_active_source::Bool)
    calculate_hessian = elbo_vars.calculate_hessian &&
                        elbo_vars.calculate_derivs &&
                        is_active_source

    # This updates elbo_vars.E_G_s and elbo_vars.var_G_s
    calculate_source_pixel_brightness!(
        elbo_vars,
        ea,
        elbo_vars.E_G_s,
        elbo_vars.var_G_s,
        elbo_vars.fs0m_vec[s],
        elbo_vars.fs1m_vec[s],
        sb,
        b,
        s,
        s in ea.active_sources)

    if is_active_source
        sa = findfirst(ea.active_sources, s)
        add_sources_sf!(E_G, elbo_vars.E_G_s, sa, calculate_hessian)
        add_sources_sf!(var_G, elbo_vars.var_G_s, sa, calculate_hessian)
    else
        # If the sources is inactive, simply accumulate the values.
        E_G.v[1] += elbo_vars.E_G_s.v[1]
        var_G.v[1] += elbo_vars.var_G_s.v[1]
    end
end


"""
Add the lower bound to the log term to the elbo for a single pixel.

Args:
     - elbo_vars: Intermediate variables
     - x_nbm: The photon count at this pixel
     - iota: The optical sensitivity

 Returns:
    Updates elbo_vars.elbo in place by adding the lower bound to the log
    term.
"""
function add_elbo_log_term!{NumType <: Number}(
                elbo_vars::ElboIntermediateVariables{NumType},
                E_G::SensitiveFloat{CanonicalParams, NumType},
                var_G::SensitiveFloat{CanonicalParams, NumType},
                elbo::SensitiveFloat{CanonicalParams, NumType},
                x_nbm::AbstractFloat, iota::AbstractFloat)
    # See notes for a derivation. The log term is
    # log E[G] - Var(G) / (2 * E[G] ^2 )

    @inbounds begin
        # The gradients and Hessians are written as a f(x, y) = f(E_G2, E_G)
        log_term_value = log(E_G.v[1]) - 0.5 * var_G.v[1]    / (E_G.v[1] ^ 2)

        # Add x_nbm * (log term * log(iota)) to the elbo.
        # If not calculating derivatives, add the values directly.
        elbo.v[1] += x_nbm * (log(iota) + log_term_value)

        if elbo_vars.calculate_derivs
            elbo_vars.combine_grad[1] = -0.5 / (E_G.v[1] ^ 2)
            elbo_vars.combine_grad[2] = 1 / E_G.v[1] + var_G.v[1] / (E_G.v[1] ^ 3)

            if elbo_vars.calculate_hessian
                elbo_vars.combine_hess[1, 1] = 0.0
                elbo_vars.combine_hess[1, 2] = elbo_vars.combine_hess[2, 1] = 1 / E_G.v[1]^3
                elbo_vars.combine_hess[2, 2] =
                    -(1 / E_G.v[1] ^ 2 + 3    * var_G.v[1] / (E_G.v[1] ^ 4))
            end

            # Calculate the log term.
            combine_sfs!(
                var_G, E_G, elbo_vars.elbo_log_term,
                log_term_value, elbo_vars.combine_grad, elbo_vars.combine_hess,
                elbo_vars.calculate_hessian)

            # Add to the ELBO.
            for ind in 1:length(elbo.d)
                elbo.d[ind] += x_nbm * elbo_vars.elbo_log_term.d[ind]
            end

            if elbo_vars.calculate_hessian
                for ind in 1:length(elbo.h)
                    elbo.h[ind] += x_nbm * elbo_vars.elbo_log_term.h[ind]
                end
            end
        end
    end
end


function add_pixel_term!{NumType <: Number}(
                    ea::ElboArgs{NumType},
                    n::Int, h::Int, w::Int,
                    star_mcs::Array{BvnComponent{NumType}, 2},
                    gal_mcs::Array{GalaxyCacheComponent{NumType}, 4},
                    sbs::Vector{SourceBrightness{NumType}};
                    calculate_derivs=true,
                    calculate_hessian=true)
    # This combines the bvn components to get the light density for each
    # source separately.
    Model.populate_fsm_vecs!(ea.elbo_vars.bvn_derivs,
                             ea.elbo_vars.fs0m_vec,
                             ea.elbo_vars.fs1m_vec,
                             ea.elbo_vars.calculate_derivs,
                             ea.elbo_vars.calculate_hessian,
                             ea.patches,
                             ea.active_sources,
                             ea.num_allowed_sd,
                             n, h, w,
                             gal_mcs, star_mcs)
    elbo_vars = ea.elbo_vars
    img = ea.images[n]

    # This combines the sources into a single brightness value for the pixel.
    clear!(elbo_vars.E_G,
        elbo_vars.calculate_hessian && elbo_vars.calculate_derivs)
    clear!(elbo_vars.var_G,
        elbo_vars.calculate_hessian && elbo_vars.calculate_derivs)

    for s in 1:size(ea.patches, 1)
        p = ea.patches[s,n]

        h2 = h - p.bitmap_corner[1]
        w2 = w - p.bitmap_corner[2]

        H2, W2 = size(p.active_pixel_bitmap)
        if 1 <= h2 <= H2 && 1 <= w2 < W2 && p.active_pixel_bitmap[h2, w2]
            is_active_source = s in ea.active_sources
            accumulate_source_pixel_brightness!(
                elbo_vars, ea, elbo_vars.E_G, elbo_vars.var_G,
                elbo_vars.fs0m_vec[s], elbo_vars.fs1m_vec[s],
                sbs[s], ea.images[n].b, s, is_active_source)
        end
    end

    # There are no derivatives with respect to epsilon, so can safely add
    # to the value.
    elbo_vars.E_G.v[1] += img.epsilon_mat[h, w]

    # Add the terms to the elbo given the brightness.
    add_elbo_log_term!(elbo_vars,
                       elbo_vars.E_G,
                       elbo_vars.var_G,
                       elbo_vars.elbo,
                       img.pixels[h,w],
                       img.iota_vec[h])
    add_scaled_sfs!(elbo_vars.elbo,
                    elbo_vars.E_G,
                    -img.iota_vec[h],
                    elbo_vars.calculate_hessian && elbo_vars.calculate_derivs)

    # Subtract the log factorial term. This is not a function of the
    # parameters so the derivatives don't need to be updated. Note that
    # even though this does not affect the ELBO's maximum, it affects
    # the optimization convergence criterion, so I will leave it in for now.
    elbo_vars.elbo.v[1] -= lfact(img.pixels[h,w])
end


"""
Return the expected log likelihood for all bands in a section
of the sky.
Returns: A sensitive float with the log likelihood.
"""
function elbo_likelihood{NumType <: Number}(
                    ea::ElboArgs{NumType};
                    calculate_derivs=true,
                    calculate_hessian=true)
    clear!(ea.elbo_vars)
    ea.elbo_vars.calculate_derivs = calculate_derivs
    ea.elbo_vars.calculate_hessian = calculate_derivs && calculate_hessian

    # this call loops over light sources (but not images)
    sbs = load_source_brightnesses(ea,
                calculate_derivs=ea.elbo_vars.calculate_derivs,
                calculate_hessian=ea.elbo_vars.calculate_hessian)

    for n in 1:ea.N
        img = ea.images[n]

        # could preallocate these---outside of elbo_likehood even to use for
        # all ~50 evalulations of the likelihood
        # This convolves the PSF with the star/galaxy model, returning a
        # mixture of bivariate normals.
        star_mcs, gal_mcs = Model.load_bvn_mixtures(ea.S, ea.patches,
                                    ea.vp, ea.active_sources,
                                    ea.psf_K, n,
                                    calculate_derivs=calculate_derivs,
                                    calculate_hessian=calculate_hessian)

        # if there's only one active source, we know each pixel we visit
        # hasn't been visited before, so no need to allocate memory.
        # currently length(ea.active_sources) > 1 only in unit tests, never
        # when invoked from `bin`.
        already_visited = length(ea.active_sources) == 1 ?
                              falses(0, 0) :
                              falses(size(img.pixels))

        # iterate over the pixels by iterating over the patches, and visiting
        # all the pixels in the patch that are active and haven't already been
        # visited
        for s in ea.active_sources
            p = ea.patches[s, n]
            H2, W2 = size(p.active_pixel_bitmap)
            for w2 in 1:W2, h2 in 1:H2
                # (h2, w2) index the local patch, while (h, w) index the image
                h = p.bitmap_corner[1] + h2
                w = p.bitmap_corner[2] + w2

                if !p.active_pixel_bitmap[h2, w2]
                    continue
                end

                # if there's only one active source, we know this pixel is new
                if length(ea.active_sources) != 1
                    if already_visited[h,w]
                        continue
                    end
                    already_visited[h,w] = true
                end

                # if we're here it's a unique active pixel
                add_pixel_term!(ea, n, h, w, star_mcs, gal_mcs, sbs;
                                calculate_derivs=ea.elbo_vars.calculate_derivs,
                                calculate_hessian=ea.elbo_vars.calculate_hessian)
            end
        end
    end

    assert_all_finite(ea.elbo_vars.elbo)
    deepcopy(ea.elbo_vars.elbo)
end


"""
Calculates and returns the ELBO and its derivatives for all the bands
of an image.
Returns: A sensitive float containing the ELBO for the image.
"""
function elbo{NumType <: Number}(
                    ea::ElboArgs{NumType};
                    calculate_derivs=true,
                    calculate_hessian=true)
    elbo = elbo_likelihood(ea; calculate_derivs=calculate_derivs,
                               calculate_hessian=calculate_hessian)
    # TODO: subtract the kl with the hessian.
    subtract_kl!(ea, elbo, calculate_derivs=calculate_derivs)
    elbo
end
