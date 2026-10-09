# Inverting J = M * I in phone astrophotography: deconvolution of star trailing, frame calibration, and foreground/sky segmentation (iOS, tripod, many sub-exposures)

Date context: 2 October 2026. Scope: (a) intra-frame trailing correction (non-blind or blind deconvolution with a known or estimated, spatially-varying rotational kernel), (b) cross-frame correction (multi-frame deconvolution, stacking-based denoising), plus calibration, sky/foreground masking, gradient removal and stretch.

Verification legend:
- **[V]** means the bibliographic data or claim was checked this session against a primary or indexing page (publisher, arXiv, ADS, MPI, Google blog, Apple forum).
- **[M]** means it comes from established domain knowledge and was not fetched this session. The equations are textbook-standard, but the report writer should re-check the DOI or page numbers before final publication.

---

## Q1. Non-blind deconvolution with a known motion PSF (RL, damped/regularized RL, Wiener, TV, FFT; iterations, ringing, noise)

### Takeaway
For a tripod phone, the sky motion during one sub-exposure is fully determined by the sidereal rate, the exposure time, the focal length/intrinsics, and the celestial-pole direction in the camera frame. The trailing operator M is therefore known (non-blind). Richardson–Lucy (RL), the EM/ML solution under Poisson noise, is the natural on-device solver. It needs only forward and adjoint applications of M (FFT convolutions or GPU warps). It must be regularized (TV, damping) or stopped early, because noise amplification and ringing grow with the iteration count. Since the box-shaped motion PSF has spectral zeros, deconvolution is best limited to short residual trails of about 1–5 px. The main tool should be keeping sub-exposures short and aligning across frames (cross-frame).

### Cited Findings
**Image formation model (general, written for this project):**
- Shift-invariant case: J = k ⊛ I + n. Spatially-variant case: J = M I + n, where M is a sparse linear operator and each column is the local PSF. With Poisson-dominated shot noise, J ~ Poisson(M I) (+ Gaussian read noise). The models below come from the RL/EM literature [M]: Richardson, W. H. (1972), "Bayesian-Based Iterative Method of Image Restoration", *JOSA* 62(1):55–59, DOI [10.1364/JOSA.62.000055](https://doi.org/10.1364/JOSA.62.000055) [M]; Lucy, L. B. (1974), "An iterative technique for the rectification of observed distributions", *AJ* 79:745, DOI [10.1086/111605](https://doi.org/10.1086/111605), ADS [1974AJ.....79..745L](https://ui.adsabs.harvard.edu/abs/1974AJ.....79..745L) [M].

**Richardson–Lucy update [M, standard]:**
- Shift-invariant form: Î^{t+1} = Î^t · [ k̃ ⊛ ( J / (k ⊛ Î^t) ) ], where k̃(x) = k(−x) is the flipped PSF, Σk = 1, and · and / are pixel-wise.
- General operator form, valid for any non-negative M including the rotational trail: Î^{t+1} = Î^t ⊙ Mᵀ( J ⊘ M Î^t ) ⊘ Mᵀ1. It is the EM (expectation-maximization) algorithm for maximising the Poisson log-likelihood Σ [J log(MI) − MI]. Properties: it preserves non-negativity, conserves flux (Σ Î = Σ J when Mᵀ1 = 1), and converges slowly. Early iterations restore low frequencies. Late iterations fit the noise, which produces "speckle" noise amplification and ringing around bright stars (Gibbs ringing and dark halos). Practical counts are about 10–50 iterations with early stopping, or more with regularization. [M]
- Read noise and sky background are handled by adding the background b to the model (J/(MÎ+b)) and by the "modified RL" variant for Poisson+Gaussian noise, where a constant σ²_read is added to both J and the model. [M]
- Damped RL: White, R. L. (1994), "Image restoration using the damped Richardson-Lucy method", *ASP Conf. Ser.* 61 / SPIE 2198 [M, venue not verified]. It suppresses the update where the residual is consistent with noise, i.e. it limits noise fitting in the background.
- RL-TV (Dey et al. 2006, *Microscopy Research and Technique* 69:260–266 [M]): Î^{t+1} = { Î^t / [1 − λ·div(∇Î^t/|∇Î^t|)] } ⊙ k̃ ⊛ (J / (k ⊛ Î^t)). Typical λ is about 0.001–0.01. Larger λ produces "cartoon"/staircase artefacts, which hurt faint stars.
- Acceleration: Biggs & Andrews (1997), "Acceleration of iterative image restoration algorithms", *Applied Optics* 36(8):1766 [M]. Vector extrapolation gives a 2–5× speed-up and is cheap on GPU.

**Wiener filter (single FFT step, cheapest) [M, standard]:**
- Î = F⁻¹{ K*(ω) J(ω) / ( |K(ω)|² + NSR(ω) ) }. NSR is the noise-to-signal power ratio, a constant 1/SNR in practice.
- Wiener is non-iterative: one forward and one inverse FFT per channel, O(N log N), which suits Metal Performance Shaders / vDSP on iPhone. It is only valid for a shift-invariant PSF, so it has to be applied per patch for a rotating field (Q2).
- It does not guarantee non-negativity and causes ringing around saturated stars, because saturation violates the linear model. Clip saturated cores and mask them before filtering.

**Total-variation regularization:**
- Rudin–Osher–Fatemi TV denoising generalized to deblurring: min_I ½‖k ⊛ I − J‖² + λ‖∇I‖₁. Blind version with alternating estimation of I and k: Chan, T. F. & Wong, C.-K. (1998), "Total variation blind deconvolution", *IEEE Trans. Image Processing* 7(3):370–375, DOI [10.1109/83.661187](https://doi.org/10.1109/83.661187) [M].
- Fast solvers for the non-blind TV problem use half-quadratic splitting or ADMM. Every sub-step is a closed-form FFT division plus pixel-wise shrinkage, which is GPU-friendly. [M]
- Caveat for astro: TV favours piecewise-constant images, so it reduces faint stars and smooths nebulosity. Use it only with small λ, or only on the background. [Inference]

**Real precedent: known-kernel deconvolution of star trails from rotation (star trackers):**
- Wang, Zhang, Ning & Zhou (2018), "Motion Blurred Star Image Restoration Based on MEMS Gyroscope Aid and Blur Kernel Correction", *Sensors* 18(8):2662, DOI 10.3390/s18082662 [V] — [PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC6111557/).
  - The star trajectory on the focal plane comes from the angular velocity ω = (ω_x, ω_y, ω_z) and focal length f:
    - x(t+Δt) = x(t) + y(t)·ω_z·Δt + f·ω_y·Δt
    - y(t+Δt) = y(t) − x(t)·ω_z·Δt − f·ω_x·Δt
  - The PSF is built by linear interpolation of these trajectory points. The kernel is then refined with an interior-point method on min ‖Ax − y‖²₂ + φ‖x‖₁ (x ≥ 0).
  - The image is restored with **scaled gradient projection**, which the authors report as about 3× faster than accelerated RL.
  - The trajectory is position-dependent through the ω_z (roll) term, so this is a spatially-varying blur, exactly as in the phone sky case. [V]
- There is a related line of work on star-sensor smearing under variable angular velocity and region-confined restoration (deconvolving only the regions around star streaks), plus 2026 learning-based variants such as an "angular velocity assisted U-Net" in *Acta Astronautica*. These were seen as titles only in [search results](https://www.sciencedirect.com/science/article/abs/pii/S0094576526000494); details were not verified.

### Inferences
- **The phone sky case is non-blind.** The sky rotates rigidly about the celestial pole at the sidereal rate ω⊕ ≈ 7.2921×10⁻⁵ rad/s [M]. With fixed camera intrinsics K and a pole direction p (in camera coordinates), each sub-exposure of length T has the trail operator:

  M I(x) = (1/T) ∫₀ᵀ I( H(t)⁻¹ x ) dt, with H(t) = K · R_p(ω⊕ t) · K⁻¹.

  - The direction p can be obtained from CoreMotion attitude, GPS latitude and compass. A better source is the inter-frame registration of the stack: the rotation between frames is the same rotation that causes intra-frame trailing.
  - Discretize the integral with N sub-steps, where N ≈ the trail length in pixels at the field edge. Mᵀ is the same sum with inverse warps.
  - This makes RL directly implementable as 2·N GPU warps per iteration (Metal compute, bilinear sampling). There is no need to estimate a PSF from the image. This is the Whyte et al. "homography-sum" model (Q2) with a 1-DoF, known trajectory.
- **Trail-length budget.** At focal length f_px pixels, a star at angular distance δ from the pole moves about ω⊕·T·f_px·sin δ px. For a typical main camera (f_px ≈ 3000 px at 12 MP):
  - At the celestial equator (sin δ = 1), a 10 s exposure gives ≈ 2.2 px of trail, and a 16 s exposure (the Night Sight limit) gives ≈ 3.5 px. This is the regime where 10–30 RL iterations with damping/TV is realistic.
  - Very long sub-exposures with trails of tens of px are not worth deconvolving, because of the box-PSF spectral zeros (Q2), noise amplification and saturation.
- **Order of operations.** Calibrate first (darks, flats, hot pixels; Q4) and keep data linear. RL assumes linear photon counts, so any tone curve must come after deconvolution. On the phone this means using linear RAW (DNG / Bayer or ProRAW linear before tone mapping).
- **Better alternative: deconvolve the stack.** Each aligned sub-frame shares the same trail kernel up to the rotation-stack alignment, so averaging N aligned frames gives the same M with noise reduced by √N. A single deconvolution of the stacked result therefore has far better SNR than per-frame deconvolution, though the warp of the alignment slightly changes M (negligible for small angles).

### Gaps
- The full text of White 1994 (damped RL) and Dey 2006 (RL-TV) was not fetched. The equations above are standard forms from memory and should be verified.
- There are no peer-reviewed benchmarks of RL vs. Wiener on phone-sensor star trails specifically. Iteration counts are heuristic.

---

## Q2. Spatially-varying (rotational) blur: EFF, Whyte et al., Gupta et al., coded exposure / invertibility

### Takeaway
Two families are directly usable:
1. **Patch-wise PSFs ("Efficient Filter Flow", Hirsch et al. CVPR 2010).** Overlapping windows, each with its own convolution done via FFT. This is compatible with Wiener or RL per patch, and with a smooth blend between patches.
2. **Projective-motion / homography-sum models (Whyte et al. 2010/2012; Gupta et al. 2010 MDF).** The blurred image is a weighted sum of homography-warped sharp images. This is exactly the physics of a rotating sky with a fixed camera.

Coded exposure (Raskar 2006) explains *why* a box-shaped trail is poorly invertible: its sinc spectrum has zeros. A phone cannot flutter its shutter within an exposure, but varying sub-exposure lengths across frames can play a similar role (inference).

### Cited Findings
**EFF (patch-wise PSFs):**
- Hirsch, M., Sra, S., Schölkopf, B., Harmeling, S. (2010), "Efficient Filter Flow for Space-Variant Multiframe Blind Deconvolution", *CVPR 2010*, pp. 607–614, DOI 10.1109/CVPR.2010.5540158 — [MPI page](https://is.mpg.de/publications/6335) [V].
- The paper introduces a class of linear transformations "expressive enough for space-variant filters, while being especially designed for efficient matrix-vector multiplications". It was demonstrated on astronomical imaging through atmospheric turbulence. [V via search summary]
- Structure [M, paraphrase of the paper's formulation]: y = Σ_r C_rᵀ ( a^{(r)} ⊛ ( w^{(r)} ⊙ C_r x ) ).
  - C_r crops overlapping patch r, w^{(r)} is a window (a partition of unity, Σ_r w^{(r)} = 1), and a^{(r)} is the local PSF.
  - Each patch convolution is done by FFT, so the cost is O(R·P log P) for R patches of P pixels.
  - The adjoint (needed for RL / gradient methods) has the same structure with flipped PSFs.
- Related survey title seen in search: "Scattering and Gathering for Spatially Varying Blurs" (arXiv [2303.05687](https://arxiv.org/pdf/2303.05687)). It discusses the difference between the scatter (column-wise, Mᵀ-like) and gather (row-wise) interpretations of a varying PSF. Not read in full.

**Whyte et al. (rotational camera model):**
- Whyte, O., Sivic, J., Zisserman, A., Ponce, J. (2010), "Non-uniform Deblurring for Shaken Images", *CVPR 2010* — [PDF](https://www.di.ens.fr/~josef/publications/whyte10.pdf) [V]. Journal version: *IJCV* 98:168–186 (2012), DOI [10.1007/s11263-011-0502-7](https://link.springer.com/article/10.1007/s11263-011-0502-7) [V]; [project page](https://www.di.ens.fr/willow/research/deblurring/) [V].
- Blur from camera shake is mostly due to 3D camera rotation, which produces a non-uniform kernel. The authors parametrize the blur by the camera's rotational velocity during exposure. They apply it to (i) single-image blind deblurring and (ii) deblurring with a blurred + sharp-noisy image pair. [V]
- Model [M, standard form from the paper]: g = Σ_θ w_θ · K_θ f, where K_θ is the warp by homography H_θ = K R_θ K⁻¹ and w_θ ≥ 0 is the time spent at orientation θ.
- Follow-up: Whyte, Sivic, Zisserman (2014), "Deblurring Shaken and Partially Saturated Images", *IJCV* — [ACM DL entry](https://dl.acm.org/doi/10.1007/s11263-014-0727-3) [V title]. It handles saturated pixels inside RL by modelling the clipping nonlinearity, which is directly relevant to bright stars. [M, content]

**Gupta et al. (motion density functions):**
- Gupta, A., Joshi, N., Zitnick, C. L., Cohen, M., Curless, B. (2010), "Single Image Deblurring Using Motion Density Functions", *ECCV 2010*, LNCS 6311, pp. 171–184 — [Springer](https://link.springer.com/chapter/10.1007/978-3-642-15549-9_13) [V].
- The camera motion is a Motion Density Function (MDF): the fraction of exposure time spent at each discretized camera pose. Spatially varying kernels are derived directly from the MDF. [V]

**Coded exposure:**
- Raskar, R., Agrawal, A., Tumblin, J. (2006), "Coded Exposure Photography: Motion Deblurring using Fluttered Shutter", *ACM TOG* 25(3) (SIGGRAPH 2006), pp. 795–804, DOI [10.1145/1141911.1141957](https://doi.org/10.1145/1141911.1141957) [M].
- A box exposure has a sinc spectrum with zeros, which makes deconvolution ill-posed. A pseudo-random binary on/off shutter code makes the PSF spectrum broadband (no zeros), so the inverse is well-conditioned. [M]
- Agrawal, A., Xu, Y., Raskar, R. (2009), "Invertible Motion Blur in Video", *ACM TOG* 28(3) (SIGGRAPH 2009) [M, unverified]. Varying the exposure time between successive video frames makes the joint multi-frame blur invertible, because the PSF nulls differ per frame. This is the version that is realisable on a phone.

### Inferences
- For a rotating sky, the true trail is an arc around the pole, not a line. Its length scales with the angular distance from the pole and its direction is tangential.
  - **Exact on-device option:** implement M and Mᵀ directly as a sum of N rotation warps (Whyte/MDF model with a uniform density along a known 1-DoF path). Cost per RL iteration is about 2N full-frame bilinear warps on GPU. With N ≈ 4–8 for trails of 2–5 px, a 12 MP frame fits in tens of ms per iteration on Apple GPUs (estimate, not benchmarked).
  - **FFT option:** EFF-style patch grid, for example 8×6 patches with 50% overlap. Each patch gets a straight-line PSF (length L_r, angle φ_r tangential to the pole) computed analytically, then Wiener or RL per patch. Locally the arc is approximately a line when the trail is ≪ the distance to the pole. This is the most efficient route.
- **Exploit varying exposures ("coded" in time across sub-frames).** If sub-exposure lengths vary (e.g. 4, 6, 9, 13 s), the PSF zeros fall at different frequencies. A joint multi-frame RL/Wiener can then recover frequencies a single box kernel destroys. This is the Agrawal 2009 principle, which is cheap to adopt in a capture scheduler.
- **Ringing management:** mask saturated star cores (Whyte 2014 idea), apodize patch boundaries, and run deconvolution on the sky region only (via the sky mask; Q5). The foreground has no star motion, so the M operator would corrupt it.

### Gaps
- The EFF formula above is paraphrased. The CVPR PDF was not fetched to confirm the exact notation.
- Agrawal/Xu/Raskar 2009 and Raskar 2006 bibliographic details are from memory [M].
- No published work was found that applies EFF/Whyte-type deblurring specifically to diurnal star trails on smartphones. This appears to be an open niche (absence of evidence from limited searching, not a proof).

---

## Q3. Multi-frame blind deconvolution and learning-based denoising/deconvolution (2018–2026)

### Takeaway
The online multi-frame blind deconvolution of Hirsch et al. 2011 (A&A) is the canonical astronomy method. It processes one frame at a time, which fits a streaming phone pipeline. It handles super-resolution, and it handles saturation by masking clipped pixels.

For learned methods:
- **Peer-reviewed:** Noise2Noise (ICML 2018), ASTRO U-Net (MNRAS 2021), and ASTERIS (self-supervised spatiotemporal, Science 2026 per arXiv metadata).
- **Tools without peer-reviewed papers:** StarNet (star removal) and the GraXpert AI background/denoise models.

### Cited Findings
**Hirsch et al. 2011 (OBD):**
- Hirsch, M., Harmeling, S., Sra, S., Schölkopf, B. (2011), "Online multi-frame blind deconvolution with super-resolution and saturation correction", *A&A* 531, A9, DOI [10.1051/0004-6361/200913955](https://www.aanda.org/articles/aa/pdf/2011/07/aa13955-09.pdf) — [MPI page](https://is.mpg.de/ei/publications/6793) [V].
- It targets ground-based telescope images degraded by atmospheric turbulence. It performs both super-resolution and saturation correction, and produces quality "comparable and often better" than existing approaches. [V via search summary]
- Method sketch [M, not verified against PDF; the A&A PDF returned HTTP 403]:
  - For each incoming frame y_t, first estimate the PSF f_t by non-negative least squares, min_{f≥0} ‖y_t − f ⊛ x‖².
  - Then update the latent image with a multiplicative (ISRA/Lee–Seung-type) step: x ← x ⊙ F_tᵀ y_t ⊘ F_tᵀ F_t x.
  - Super-resolution adds a downsampling operator D (y_t = D(f_t ⊛ x)).
  - Saturation correction excludes saturated pixels from the data term.
  - A related precursor is "Multiframe blind deconvolution, super-resolution, and saturation correction via incremental EM" (Harmeling et al., ICIP 2010 — [ResearchGate](https://www.researchgate.net/publication/224200375_Multiframe_blind_deconvolution_super-resolution_and_saturation_correction_via_incremental_EM), title [V], venue [M]).

**Learning-based methods:**
- **Noise2Noise:** Lehtinen, J., Munkberg, J., Hasselgren, J., Laine, S., Karras, T., Aittala, M., Aila, T. (2018), "Noise2Noise: Learning Image Restoration without Clean Data", *ICML 2018*, arXiv [1803.04189](https://arxiv.org/abs/1803.04189) [M]. A denoiser can be trained on pairs of independent noisy observations of the same scene, with no clean targets needed. Aligned sky sub-frames are such pairs, so a phone could fine-tune or self-supervise from its own stack. [Inference]
- **ASTRO U-Net:** Vojtekova, A., Lieu, M., Valtchanov, I., et al. (2021), "Learning to denoise astronomical images with U-nets", *MNRAS* 503(3):3204–3215, DOI 10.1093/mnras/staa3567 — [ADS](https://ui.adsabs.harvard.edu/abs/2021MNRAS.503.3204V/abstract) [V].
  - Trained on HST WFC3 F555W/F606W data.
  - Output noise is as if exposure time were doubled. The SNR gain is ×1.63 on average, "equivalent to stacking at least 3 input images".
  - It recovers 95.9% of stars with 2.26% mean flux error. [V]
- **ASTERIS:** Guo, Y., Zhang, H., Li, M., … Cai, Z., Dai, Q. (2026), "Deeper detection limits in astronomical imaging using self-supervised spatiotemporal denoising", arXiv [2602.17205](https://arxiv.org/abs/2602.17205) (submitted 19 Feb 2026, revised 30 Apr 2026; arXiv page states publication in *Science*) [V for arXiv; Science volume/page not verified].
  - A transformer exploiting correlated noise across neighbouring pixels and consecutive exposures, trained self-supervised.
  - It gains about 1.0 mag of depth at 90% completeness/purity while preserving the PSF and photometry. On JWST data it finds 3× more z > 9 galaxy candidates. [V]
  - Conceptually the closest to "many phone sub-exposures", but its model size and on-device feasibility are unknown.
- **Other 2025–2026 preprints seen in search (titles only; not verified for venue):**
  - "BGRem: A background noise remover for astronomical images based on a diffusion model" (arXiv [2510.04718](https://arxiv.org/html/2510.04718)).
  - "Astronomical image denoising by self-supervised deep learning and restoration processes" (ResearchGate, 2025).
  - "Accelerating Multiframe Blind Deconvolution via Deep Learning" (Solar Physics 2023, arXiv [2306.12078](https://arxiv.org/html/2306.12078)) — unrolled/learned MFBD for solar imaging.
- **Burst-merging precedent from mobile photography:** Liba, O., Murthy, K., Tsai, Y.-T., Brooks, T., Xue, T., Karnad, N., He, Q., Barron, J. T., Sharlet, D., Geiss, R., Hasinoff, S. W., Pritch, Y., Levoy, M. (2019), "Handheld Mobile Photography in Very Low Light", *ACM TOG* 38(6), Art. 164 (SIGGRAPH Asia 2019), arXiv [1910.11336](https://arxiv.org/abs/1910.11336) [V]. It covers "motion metering" (choosing frame count and exposure from measured motion), robust alignment and merge for high-noise bursts, learned AWB, and tone mapping that "crushes shadows". The Night Sight astro mode builds on this.

**Tools, not peer-reviewed:**
- **StarNet / StarNet++** (Nikita Misiura, started January 2018, PixInsight module from 2019, also integrated in Siril) is a CNN encoder–decoder / GAN that removes stars. It is used for star/nebula separation before stretching. No academic paper was found. Sources: [Siril docs](https://siril.readthedocs.io/en/stable/processing/stars/starnet.html), [Astronomy.com](https://www.astronomy.com/observing/how-to-remove-stars-from-images-with-ai-tools/) [V that no paper was found in search].
- **GraXpert:** see Q6.

### Inferences
- **On-device recommendation:** use non-blind RL on the stacked sky, with the analytically known rotational M. Blind MFBD (Hirsch 2011) is only needed if the trajectory is unknown — e.g. wind shake or tripod creep, where a per-frame PSF must be estimated from bright stars. In that case, bright unsaturated stars give an empirical PSF per patch directly: a "star-as-PSF" estimate, i.e. a crop around isolated stars, normalized.
- **Streaming fit:** OBD's online structure (one frame in, update x, discard frame) bounds memory. That matters on iOS, where a 12 MP float RGB frame is about 144 MB.
- A Noise2Noise-style denoiser trained on pairs of aligned sub-stacks (odd vs. even frames) is a principled, self-supervised fit for this app. Peer-reviewed astronomy-specific DL denoisers were trained on HST/JWST data and will not transfer directly to Bayer phone sensors.

### Gaps
- Exact OBD update equations need confirmation from the A&A full text (fetch was blocked with 403).
- The ASTERIS Science citation (volume, pages, DOI) was not verified.
- No peer-reviewed benchmark of DL denoisers on smartphone astro data was found.

---

## Q4. Calibration on a phone: bias, darks, flats, hot pixels, amp glow, temperature

### Takeaway
Classical calibration is (light − master dark) / normalized master flat, with bias included in the dark at the same exposure, ISO and temperature. It is feasible on iPhone if RAW capture locks the exposure parameters:
- **Darks:** shoot with the lens covered at identical exposure/ISO, ideally interleaved or right after the lights, because dark current is strongly temperature-dependent.
- **Hot pixels:** Google Night Sight shows the darks-free route is viable. It detects outliers by comparing each pixel to its spatial neighbours within the frame and to the same pixel across frames, then conceals them by interpolation.

### Cited Findings
**Google Night Sight astrophotography mode** — Kainz, F. & Murthy, K. (26 Nov 2019), Google Research blog, ["Astrophotography with Night Sight on Pixel Phones"](https://research.google/blog/astrophotography-with-night-sight-on-pixel-phones/) [V]:
- Per-frame exposure is capped at 16 s so that stars do not render as line segments.
- Up to 15 frames, giving about 4 min total on Pixel 4 (1 min on Pixel 3/3a).
- Dark current produces hot/warm pixels, which become significant with multi-second captures.
- Detection: compare "the values of neighboring pixels within the same frame and across the sequence of frames"; outliers are concealed by interpolating neighbours. No dark frames are needed.
- Frames are aligned, compensating for camera shake and in-scene motion, and then averaged.

**Dark current vs. temperature:**
- Dark current grows linearly with exposure time and exponentially with temperature, roughly doubling every ~5–10 °C (commonly quoted as about 6 °C; the doubling interval N is process-dependent, about 6–10 °C). Sources: [Patsnap blog](https://www.patsnap.com/resources/blog/articles/dark-current-noise-in-cmos-sensors-50-patent-strategies/) (secondary source) and US patent [7,787,033](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7787033) (N = 6–10 °C, process-dependent) [V via search snippets].
- Peer-reviewed compensation using in-pixel temperature sensors: "A CMOS Image Sensor Dark Current Compensation Using In-Pixel Temperature Sensors", *Sensors* 23(22):9109, DOI [10.3390/s23229109](https://doi.org/10.3390/s23229109) [V title/DOI only].
- Roger N. Clark (Clarkvision) argues that modern sensors with on-sensor dark current suppression make dark frames less necessary, and that dark subtraction can add noise. [Clarkvision article](https://clarkvision.com/articles/dark-current-suppression-technology/) [V title; content not fetched — treat as practitioner opinion].

**Standard calibration equations [M, textbook CCD/CMOS reduction]:**
- master_bias = median(bias frames at the shortest exposure).
- master_dark(T, t_exp, ISO) = median(dark frames). If darks are scaled to a different exposure: dark_scaled = bias + (master_dark − bias) · t_light / t_dark. Scaling is valid only at the same temperature and only if the sensor has no non-linear amp glow.
- master_flat = median(flat frames − bias − dark_flat), normalised per Bayer channel to a mean of 1.
- calibrated = (light − master_dark) / master_flat.
- Noise added by a master dark built from N_d frames is σ_dark/√N_d. Use N_d ≥ 10–20, or prefer hot-pixel maps over full darks.
- Amp glow is a localized dark-current-like gradient from readout circuitry heating. It scales with exposure time but not necessarily linearly, so it requires matched darks rather than a scaled bias.

### Inferences
**Practical iOS pipeline:**
1. **Capture.** Use AVCapturePhotoOutput Bayer RAW with fixed ISO, exposure duration, white balance gains and focus at infinity. Lock all of them. iPhone max exposure duration is device-dependent and must be checked via `activeFormat.maxExposureDuration`.
2. **Darks.** After the lights, prompt "cover lens" and capture 10–20 frames at identical settings. Optionally capture some before and some after, and average them to bracket the temperature drift.
   - Track thermal state with `ProcessInfo.thermalState`. It is coarse; iOS exposes no public sensor-temperature API (absence noted, not verified exhaustively).
   - Also exploit the "dark" information already in the stack:
     - **Night Sight route (preferred, darks-free):** pixels that are outliers in the *unregistered* frame stack are hot pixels, because hot pixels stay fixed on the sensor while stars move between frames.
     - **Rejection after sky alignment:** fixed-pattern hot pixels become moving streaks after sky alignment and get rejected by sigma-clipping or median stacking — the same mechanism as "dithering" in amateur astro, provided for free by sky rotation.
     - **Caveat:** that free rejection applies only to the sky. The foreground stack is unwarped, so hot pixels stay aligned there and must be fixed by a map or darks.
3. **Hot-pixel map.**
   - Per pixel, compute the temporal median of the raw unaligned frames m(x) and the local spatial median of the same Bayer colour s(x).
   - Flag a pixel if m(x) − s(x) > k·σ (k ≈ 5) in most frames.
   - Replace it with the same-colour neighbour median before demosaicing.
   - Cache maps per ISO and exposure. They drift with temperature, so refresh them per session.
4. **Flats.** Lens vignetting on phone cameras is large. The ISP's lens-shading correction is applied to processed images but not to Bayer RAW (the DNG carries lens-shading metadata/opcodes [M]).
   - Use the DNG GainMap/opcode list (Apple RAW DNGs commonly include OpcodeList data [M]), or shoot "sky flats" / uniform white-screen flats once per device and focus setting.
   - Flats are essential before gradient removal (Q6). Otherwise vignetting is misread as light-pollution gradient.
5. **Bias.** On phones this is the black level, which is given in the DNG metadata (BlackLevel tags). Subtract the black level rather than capturing bias frames. [M]

### Gaps
- No primary source was found for iPhone-specific sensor temperature, amp glow, or dark current figures.
- The Clarkvision content was not fetched.
- The Night Sight blog gives no thresholds or algorithm details for hot-pixel detection beyond the description above.

---

## Q5. Foreground preservation: sky segmentation, separate stacking, horizon detection, Apple APIs

### Takeaway
Rotation-warped stacking blurs the static landscape, and an unwarped stack trails the stars. The standard fix is a sky mask:
- stack the sky with the rotation warp and the foreground without a warp (or with a camera-shake-only warp);
- blend with a feathered mask.

Google Night Sight used an on-device CNN sky segmenter trained on more than 100k hand-labelled images. Apple exposes no public sky-segmentation API. The `semanticSegmentationSkyMatte` property exists in Core Image's CIRAWFilter, but a sky matte is not obtainable via AVCapture for third-party capture, according to developer reports. The app will therefore need its own Core ML sky segmenter, or a non-learned horizon detector built from the frame stack itself.

### Cited Findings
- **Night Sight sky segmenter:** an on-device CNN identifies sky pixels. It was trained on "over 100,000 images that were manually labeled by tracing the outlines of sky regions". Sky-specific processing applies selective darkening, noise reduction and contrast enhancement — [Google Research blog 2019](https://research.google/blog/astrophotography-with-night-sight-on-pixel-phones/) [V].
- **Apple:**
  - [`CIRAWFilter.semanticSegmentationSkyMatte`](https://developer.apple.com/documentation/coreimage/cirawfilter/semanticsegmentationskymatte) exists in Core Image (doc page title [V]).
  - `AVSemanticSegmentationMatte.MatteType` exposes only hair, skin, teeth and glasses. `availableSemanticSegmentationMatteTypes` from `AVCapturePhotoOutput` returns no sky type. A developer asking how to get the sky matte was told on LinkedIn "it's not possible without private libraries". There was no Apple engineer reply. — [Apple Developer Forums thread 735020](https://developer.apple.com/forums/thread/735020) [V].
  - Semantic segmentation mattes (hair, skin, teeth) were introduced in iOS 13 — [WWDC19 session 225](https://developer.apple.com/videos/play/wwdc2019/225/) [V title].
- **Other Apple Vision options [M, not fetched this session]:**
  - `VNGenerateForegroundInstanceMaskRequest` (iOS 17+) gives class-agnostic "salient foreground object" masks. It is not designed for landscape horizons.
  - `VNGeneratePersonSegmentationRequest` covers people only.
  - Apple's Core ML model gallery lists DeepLabV3 (PASCAL VOC 21 classes, no "sky" class).
  - A custom sky model is therefore required: e.g. a small U-Net/MobileNet segmenter trained on sky datasets such as SkyFinder or ADE20K's "sky" class, converted with coremltools.

### Inferences
**Mask without a deep model (works only on a tripod; derived from stack physics):**
- **Temporal-variance cue.** In the *unwarped* stack, sky pixels near stars vary over time as stars drift through them. Foreground pixels are temporally stable apart from noise.
- **Alignment-residual cue.** After applying the sky rotation warp, the sky becomes stable and the foreground becomes variable.
- **Classifier.** Compare per-pixel temporal variance (or the difference from the median) for warped vs. unwarped stacks. A pixel belongs to the sky where var_warped < var_unwarped.
- **Cleanup.** Smooth the result with a guided filter or morphology, then fit a horizon line or curve: a column-wise lowest-sky-pixel, smoothed. This is a cheap, data-driven "horizon detection".
- **Weakness:** dark featureless sky regions without stars (e.g. clouds) give no signal. Fuse with a CNN prior or a brightness/gradient cue such as the horizon glow.

**Blending:**
- final = α · sky_stack_warped + (1 − α) · fg_stack_unwarped, with α the feathered sky mask.
- Use a distance-transform feather of a few pixels, or a guided filter on the luminance edge, to avoid halos at tree lines.
- The deconvolution (Q1/Q2) and the sky-specific denoise and stretch should be applied only where α > 0.
- The foreground stack can use more aggressive temporal denoising, because it has no motion.

**Foreground exposure strategy:**
- The foreground is static, so the unwarped average over all frames gives it the full integration time.
- Optional "blue-hour foreground" capture (common amateur practice; no peer-reviewed source) is out of scope.

**Edge cases:**
- Trees in wind and moving clouds violate both models. Per-pixel robust merge with outlier rejection (as in Liba et al. 2019 robust merging) mitigates this.

### Gaps
- No primary Apple documentation was fetched confirming the exact availability conditions of `semanticSegmentationSkyMatte` (e.g. only on Apple-captured ProRAW from the Camera app).
- No peer-reviewed lightweight night-sky segmentation model for mobile was verified this session. Datasets (SkyFinder, ADE20K) are named from memory [M].

---

## Q6. Light-pollution / gradient removal and final stretch (asinh)

### Takeaway
The background is modelled as a smooth surface fitted to star-free sample points (polynomial of degree 1–4, RBF/thin-plate spline, or kriging) and then subtracted (additive skyglow) or divided (vignetting-like). GraXpert implements RBF, spline and kriging fitting plus an AI model, but it is an open-source tool, not peer-reviewed. The final display stretch should be Lupton et al. 2004's asinh, applied to a common intensity so that colour is preserved.

### Cited Findings
**GraXpert:**
- An "astronomical image processing program for extracting and removing gradients" — [GitHub](https://github.com/Steffenhir/GraXpert/) [V].
- Traditional interpolation methods (RBF, splines, kriging) require user-selected background sample points. A newer AI method needs no user input — [GitHub / search summary](https://github.com/Steffenhir/GraXpert/) [V].
- It is integrated in Siril — [Siril docs](https://siril.readthedocs.io/en/latest/processing/graxpert.html) [V title].
- No peer-reviewed GraXpert paper was found in search [V absence].

**Asinh stretch:**
- Lupton, R., Blanton, M. R., Fekete, G., Hogg, D. W., O'Mullane, W., Szalay, A., Wherry, N. (2004), "Preparing Red-Green-Blue Images from CCD Data", *PASP* 116:133–137, DOI [10.1086/382245](https://iopscience.iop.org/article/10.1086/382245), arXiv [astro-ph/0312483](https://arxiv.org/abs/astro-ph/0312483), ADS [2004PASP..116..133L](https://ui.adsabs.harvard.edu/abs/2004PASP..116..133L/abstract) [V].
- It uses F(x) = arcsinh(x/β), with softening β setting the transition from linear (faint) to logarithmic (bright) [V].
- Its colour-preserving scheme [M, from the paper]: compute I = (R+G+B)/3, then scale every channel by the same factor, (R,G,B)·F(I)/I. An object with a given astronomical colour then has a unique displayed hue and stars do not desaturate to white. Clip by max(R,G,B) rather than per-channel.

### Inferences
**Gradient removal algorithm for the app (cheap and robust):**
1. Work on the linear, calibrated, sky-masked stack, and remove stars first. Options: a sigma-clipped median filter, morphological opening, or StarNet-like ML.
2. Grid-sample the background, e.g. 16×12 cells. Take a sigma-clipped median per cell and reject cells with nebula or Milky Way by robust statistics (e.g. above the median + k·MAD of cell values).
3. Fit a 2D polynomial (degree 2–3) or a thin-plate RBF with smoothing to the cell values, per colour channel. Least squares is cheap (Accelerate/LAPACK).
4. Subtract the model and add back a small pedestal.
5. Restrict the fit to sky-mask pixels. The foreground must not influence it.

**Caution:** the Milky Way is a large-scale structure. Aggressive polynomial or RBF fits (high degree, dense samples) will remove it. Prefer low degree and conservative sample rejection.

**Stretch order:** calibrate → stack → deconvolve (linear) → gradient removal (linear) → colour calibration/white balance → asinh stretch (Lupton, β tuned to the background noise σ, e.g. β ≈ a few σ) → optional local contrast and saturation. Deconvolution and gradient fitting are only valid in linear space.

### Gaps
- No peer-reviewed reference was verified for the RBF/kriging background extraction used in GraXpert, nor for PixInsight's DBE/ABE.
- No details were obtained on GraXpert's AI model architecture.
