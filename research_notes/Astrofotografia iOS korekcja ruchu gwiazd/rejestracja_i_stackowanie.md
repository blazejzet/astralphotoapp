# Star-field registration and multi-frame stacking for smartphone astrophotography (iOS, Metal/Accelerate)

Research date: 2026-10-02. Primary texts were read in full-text form (PDF text extraction) for: astroalign (arXiv:1909.02946), Liba et al. 2019 (arXiv:1910.11336), Wronski et al. 2019 (arXiv:1905.03277), Monod/Delon/Veit IPOL 2021 (HDR+ analysis), Lang et al. 2010 (arXiv:0910.2233), Fruchter & Hook (arXiv:astro-ph/9808087). The Google Research blog, Siril docs and SExtractor docs were fetched directly. Marker legend: **[VERIFIED]** = read in the primary source in this session; **[META-ONLY]** = bibliographic metadata confirmed by search/landing page, full text not read; **[UNVERIFIED / textbook]** = standard knowledge stated without a fetched source in this session (only in Inferences).

---

## 1. Star detection and centroiding on noisy low-light frames

### Takeaway
The standard pipeline (SExtractor/SEP) is: a mesh-based background + RMS map (3σ-clipped, mode ≈ 2.5·median − 1.5·mean, median-filtered, spline-interpolated), background subtraction, threshold at k·σ_RMS on a matched-filtered image, connected components, then a centroid (windowed/weighted or PSF fit). For registration you only need about 50 bright, well-centroided stars, so a cheap weighted centroid on a background-subtracted, lightly smoothed frame is enough. Full PSF fitting (Gaussian/Moffat, as in Siril) mainly helps with quality metrics (FWHM, roundness) for frame weighting and selection.

### Cited Findings
- **SExtractor**: Bertin, E. & Arnouts, S. 1996, A&AS 117, 393 (canonical reference; cited in Lang et al. 2010 reference list) — [Lang et al. 2010 arXiv PDF](https://arxiv.org/pdf/0910.2233) [META-ONLY for SExtractor paper itself].
- SExtractor background algorithm [VERIFIED]: the image is divided into a grid of meshes. "The local background histogram is clipped iteratively until convergence at ±3σ around its median". The mode estimator is **Mode = 2.5 × Median − 1.5 × Mean**. It "falls back to a simple median … if the mode and the median disagree by more than 30%". A median filter is applied to the background grid "to suppress possible local overestimations due to bright stars", and the final map is "a (natural) bicubic-spline interpolation between the meshes". Recommended BACK_SIZE is "32 to 512 pixels". An RMS (σ) background map is also produced and can be used as a weight map — [SExtractor docs: Background](https://sextractor.readthedocs.io/en/latest/Background.html).
- **SEP**: Barbary, K. 2016, "SEP: Source Extractor as a library", Journal of Open Source Software 1(6), 58, DOI [10.21105/joss.00058](https://doi.org/10.21105/joss.00058). It provides SExtractor's core algorithms as a C library "with no dependencies outside the standard library" plus a NumPy wrapper — [JOSS](https://joss.theoj.org/papers/10.21105/joss.00058); [ADS](https://ui.adsabs.harvard.edu/abs/2016JOSS....1...58B/abstract). The pure-C, dependency-free core makes it directly portable to iOS (C/Swift interop).
- astroalign uses SEP for source detection and keeps "the brightest" sources, because they "have higher chances to be persistent across the images" [VERIFIED] — [Beroiz et al. 2020, arXiv:1909.02946](https://arxiv.org/abs/1909.02946).
- **astrometry.net detector (simplexy)** [VERIFIED]: "First we subtract off a median-smoothed version of the image to 'flatten' it." The noise is estimated robustly by "choosing a few thousand random pairs of pixels separated by five rows and columns, calculating the difference in the fluxes for each pair, and calculating the variance of those differences, which is approximately twice the variance σ²". The authors call this "simpler and generally more robust" than SExtractor's grid-based background for heterogeneous inputs — [Lang et al. 2010, arXiv:0910.2233](https://arxiv.org/abs/0910.2233).
- Siril's registration uses "a very elaborate star detection algorithm" based on its Dynamic PSF analysis (PSF fit). The maximum number of stars fitted defaults to 2,000 (range 100–2,000). Frames can be filtered by FWHM, roundness and background before stacking — [Siril docs: Registration](https://siril.readthedocs.io/en/latest/preprocessing/registration.html).
- Google's astro mode uses a separate hot-pixel step before merging (see Section 3). Liba et al. median-filter (3×3) the AWB thumbnail "to remove hot pixels" [VERIFIED] — [Liba et al. 2019, arXiv:1910.11336](https://arxiv.org/abs/1910.11336).

### Inferences
- [UNVERIFIED / textbook] Detection recipe typical of SExtractor/SEP:
  1. Background B(x,y) and RMS σ(x,y) from the mesh (as above).
  2. Convolve (I − B) with a small Gaussian kernel matched to the PSF (FWHM about 2–3 px on phone frames).
  3. Threshold at about 3–5 σ, plus a minimum area of a few pixels to reject single hot pixels and cosmic rays.
  4. Find local maxima and connected components.
  5. Compute the intensity-weighted (first-moment) centroid x̄ = Σ wᵢ(Iᵢ−B)xᵢ / Σ wᵢ(Iᵢ−B)ᵢ over a window, or SExtractor's iterative Gaussian-windowed centroid (XWIN/YWIN).

  These details are standard SExtractor behaviour, but I did not fetch the SExtractor position-measurement page in this session.
- [UNVERIFIED / textbook] For registration, a 2D Gaussian or Moffat PSF fit is at best marginally more accurate than a well-windowed weighted centroid on S/N > 20 stars, and it costs much more (Levenberg–Marquardt per star). On a phone, a reasonable split is a weighted centroid for alignment plus an optional Gaussian fit on about 20 stars for FWHM-based frame weighting.
- Hot pixels: on uncooled phone sensors, warm or hot pixels look like "stars" that do **not** move with the sky. They should be removed first: a per-session dark/hot-pixel map, a temporal consistency check like Google's, or a test that a candidate is wider than one pixel. Otherwise they bias pattern matching toward the identity transform.
- Foreground (trees, horizon, buildings): detection should be masked to the sky region, using a sky segmentation mask (Google uses a CNN; see Section 3) or a simple luminance/gradient horizon heuristic. This stops foreground lights from being treated as stars.
- Metal implementation: the background mesh (per-tile sort or histogram), Gaussian convolution (MPSImageGaussianBlur), thresholding and local-max detection are all embarrassingly parallel. Connected components and centroiding on the few hundred to 2,000 candidates are cheap on the CPU (Accelerate/vDSP) after GPU compaction.

### Gaps
- I did not find a 2018–2026 peer-reviewed paper benchmarking weighted centroid vs. PSF fit specifically on smartphone (Bayer, high-read-noise, small-pixel) star frames.
- I did not open the SExtractor docs pages on windowed centroid (XWIN_IMAGE) or detection thresholds in this session. The parameters listed above come from general knowledge.

---

## 2. Star-pattern matching for registration (triangles, quads, RANSAC); robustness with few stars and foreground

### Takeaway
Triangle-invariant matching (Groth 1986 → Valdes et al. 1995 → astroalign 2020, Siril's `match`-derived implementation) plus RANSAC is the de facto method for frame-to-frame star registration. astroalign's version is compact and well documented: the 50 brightest stars, the 4 nearest neighbours per star (10 triangles), invariants (L2/L1, L1/L0), k-d tree matching with a 0.1 tolerance, and a similarity transform verified within RANSAC. It works in principle with only 3 stars. Quad hashing (astrometry.net) is designed for blind solving against a catalog and is overkill for frame-to-frame alignment, but useful if absolute pointing is needed. Feature detectors such as SIFT and ORB "generally fail" on star fields.

### Cited Findings
- **Groth, E. J. 1986**, "A pattern-matching algorithm for two-dimensional coordinate lists", AJ 91, 1244–1248. It matches points by triangles formed from triplets and is "insensitive to coordinate translation, rotation, magnification, or inversion" — [NASA NTRS](https://ntrs.nasa.gov/search.jsp?R=19860052962) [META-ONLY]; reference implementation: [guaix-ucm/gmatch](https://github.com/guaix-ucm/gmatch).
- **Valdes, F. G., Campusano, L. E., Velasquez, J. D. & Stetson, P. B. 1995**, "FOCAS Automatic Catalog Matching Algorithms", PASP 107, 1119, DOI [10.1086/133667](https://iopscience.iop.org/article/10.1086/133667). It handles catalogs that are partially overlapping, at a different scale, rotated, or flipped — [ADS](https://ui.adsabs.harvard.edu/abs/1995PASP..107.1119V/abstract) [META-ONLY].
- **astroalign**: Beroiz, M., Cabral, J. B. & Sanchez, B. 2020, "Astroalign: A Python module for astronomical image registration", *Astronomy and Computing* 32, 100384, DOI [10.1016/j.ascom.2020.100384](https://doi.org/10.1016/j.ascom.2020.100384); arXiv:[1909.02946](https://arxiv.org/abs/1909.02946); [ADS](https://ui.adsabs.harvard.edu/abs/2020A&C....3200384B/abstract); code [quatrope/astroalign](https://github.com/quatrope/astroalign). Algorithm [VERIFIED from full text]:
  - Make a catalog "of a few brightest sources", push it to a 2D k-d tree, and "for each star, select its four nearest neighbors. Create all the C(5,3) = 10 possible triangles".
  - Invariant map: **M({Lᵢ}) = (L2/L1, L1/L0) with L2 ≥ L1 ≥ L0**. This is invariant to "translation, rotation, scaling, and coordinate flipping". Equilateral triangles map to (1,1), and the collinear limit is the curve y = 1/(x−1).
  - The invariant tuples go into a second k-d tree. "Every triangle that has a partner in the other image less than 0.1 units away (about 5% error) is considered a matched triangle. One triangle match is enough to completely characterize the four parameters of the transformation".
  - The transform is a similarity with parameters {λ (scale), α (rotation), tx, ty}. The authors note sources are effectively "at infinity", so they "do not use perspective deformations parameters".
  - Verification uses the Sampson distance (via scikit-image). A correspondence is accepted if its residual is < 3, and "a transformation that matches 80% of the triangle matches or 10 (whichever is lower) is accepted", all "within a RANSAC process" (Fischler & Bolles).
  - Source cap: "capping the number of sources at the brightest 50 on both images is a good empirical compromise between robustness and efficiency … Astroalign is designed to work with as few as three sources". Too few sources make it "very sensitive to outliers"; too many make it "prone to fail because of spurious mismatches".
  - On SIFT/SURF/ORB: they "generally fail for stellar astronomical images, since stars are effectively point sources that have very little distinct structure".
  - Benchmark: execution time grows roughly linearly with image size (images 256²–1024², 10,000 sources, λ = 1,000 counts background) and is roughly insensitive to number of stars and noise. The plotted times are under about 1 s for these sizes (read off a figure, so approximate).
- **Astrometry.net**: Lang, D., Hogg, D. W., Mierle, K., Blanton, M. & Roweis, S. 2010, AJ 139(5), 1782, DOI [10.1088/0004-6256/139/5/1782](https://iopscience.iop.org/article/10.1088/0004-6256/139/5/1782/meta); arXiv:[0910.2233](https://arxiv.org/abs/0910.2233). Quad hash [VERIFIED]:
  - In each 4-star quad, "the most widely-separated pair" A, B defines a local frame. The hash code is "simply the 4-vector (xC, yC, xD, yD)", with C and D required to lie in the circle with AB as diameter.
  - Symmetries are broken by requiring xC ≤ xD and xC + xD ≤ 1. The code is "invariant to translation, rotation and scaling" and "smooth".
  - Why quads and not triangles: "the positional noise level in typical astronomical images is sufficiently high that triangles are not distinctive enough". Note this applies to matching against a huge sky index, not two frames.
  - Hypotheses are accepted only via a "Bayesian decision theory test against a null hypothesis". Reported success rate is ">99.9% … with no false positives" on survey data.
- **Siril** global star alignment [VERIFIED docs]: "based on triangle similarity method", referencing Valdes et al. (1995), with an implementation derived from Michael Richmond's `match` program. RANSAC then "filters outliers and determines the projection matrix". Transformations and minimum pairs: shift (2 DOF, 3 pairs), similarity (4 DOF, 3), affine (6 DOF, 3), homography (8 DOF, 4). **Homography is the default for wide-field images.** Frames below a "minimum star pairs" threshold are excluded. There is a 2-pass mode that lets the reference frame be chosen from star statistics — [Siril docs: Registration](https://siril.readthedocs.io/en/latest/preprocessing/registration.html).

### Inferences
- **Transform model for phone astro on a tripod.** The sky rotates about the celestial pole, and phone lenses are wide-angle (iPhone main camera about 26 mm-equivalent, ultrawide 13 mm), with visible distortion. A pure similarity (astroalign default) is fine for short sequences over small fields, which is the astroalign authors' assumption. For wide-field phone frames over several minutes, Siril's choice of a homography (or affine plus lens-distortion pre-correction) is more appropriate. Without distortion correction, residuals grow toward the edges. iOS exposes lens distortion lookup tables via AVCameraCalibrationData (the scratchpad had AVFoundation doc dumps from a sibling researcher, which I did not verify here).
- **Better for a tripod phone: a rotation model.** The camera is fixed and the sky moves, so for an ideal pinhole camera the inter-frame mapping of stars (points at infinity) is exactly a homography induced by a 3D rotation, H = K R K⁻¹. That gives only 3 DOF (rotation), which is more robust with few stars than an 8-DOF homography. This is my inference from projective geometry [UNVERIFIED / textbook]. It is consistent with astroalign's "sources at infinity" remark, but no paper here tests it on phones.
- **Few stars.** Triangle matching needs ≥ 3 matched stars, and RANSAC verification needs more for confidence. With under about 8–10 stars (light pollution, a short exposure, or a mostly foreground frame), mismatches become likely. Practical mitigations:
  - (a) use the gyroscope or device attitude as a prior on rotation, shrinking the RANSAC search;
  - (b) use the previous frame's transform as a prior (frames are sequential);
  - (c) fall back to phase correlation or tile alignment on the sky region.
- **Foreground.** Foreground is static in pixel coordinates while stars move, so a single global star transform will mis-register the foreground. This is exactly why Google segments the sky (Section 3), and why consumer apps align and merge sky and foreground separately and then blend. Foreground lights must be excluded from star detection (mask) or RANSAC will produce a second "identity" consensus set.
- **Computational cost.** About 50 stars × 10 triangles gives about 500 invariants per frame, and a k-d tree on 2D invariants is microseconds to milliseconds on the CPU. The registration math is negligible compared with the per-pixel warp and merge. Warping is natural on the GPU (Metal sampler with bilinear filtering, or a custom Lanczos kernel). Siril warns that bicubic/Lanczos-4 "usually require the Clamping interpolation option … to avoid ring artifacts".

### Gaps
- I could not fetch the full text of Groth 1986 or Valdes 1995, so their exact invariants (Groth uses ratio of longest to shortest side and cosine of angle at a vertex; Valdes uses side-length ratios) are from memory and **unverified** here.
- I found no published quantitative study of triangle-matching failure rate versus number of stars for smartphone frames.
- I found no paper that evaluates gyroscope-aided star registration on phones. This would be novel engineering, not literature-backed.

---

## 3. Google Night Sight / astrophotography mode, HDR+, Handheld Super-Resolution, and newer mobile burst work

### Takeaway
Google's astro mode (2019) captures up to 15 frames × up to 16 s (Pixel 4 total ≤ 4 min; Pixel 3/3a ≤ 1 min). It removes hot pixels by spatio-temporal outlier detection, segments the sky with an on-device CNN, aligns and averages frames with handling for alignment failures, then darkens and denoises the sky selectively. The underlying merge is HDR+'s tile-based coarse-to-fine alignment with a pairwise frequency-domain Wiener-like merge (Hasinoff 2016). Liba 2019 adds a spatially varying "temporal strength" from mismatch maps. Wronski 2019 replaces it with kernel-regression merging with a statistical robustness term and runs online (memory independent of frame count).

### Cited Findings
- **Kainz, F. & Murthy, K. (Nov 26, 2019), "Astrophotography with Night Sight on Pixel Phones"**, Google AI/Research blog [VERIFIED] — [Google Research blog](https://research.google/blog/astrophotography-with-night-sight-on-pixel-phones/):
  - Per-frame exposure is at most 16 s, with up to 15 frames per image. Total is at most 4 min on Pixel 4 and 1 min on Pixel 3/3a.
  - Why 16 s: longer exposures make stars appear as "short line segments".
  - Hot/warm pixels are found by "comparing the values of neighboring pixels within the same frame and across the sequence of frames" and replaced "with the average of its neighbors".
  - Sky segmentation uses an "on-device convolutional neural network, trained on over 100,000 images that were manually labeled", classifying each pixel as sky or not. It drives selective sky darkening, noise reduction and contrast enhancement.
  - Frames are "aligned, compensating for both camera shake and in-scene motion, and then averaged, with careful treatment of cases where perfect alignment is not possible".
  - Autofocus: post-shutter autofocus with "two autofocus frames with exposure times up to one second", falling back to infinity focus.
  - A "post-shutter viewfinder" shows each frame as it is captured.
- **Hasinoff, S. W., Sharlet, D., Geiss, R., Adams, A., Barron, J. T., Kainz, F., Chen, J. & Levoy, M. 2016**, "Burst photography for high dynamic range and low-light imaging on mobile cameras", ACM TOG 35(6), Art. 192 (SIGGRAPH Asia 2016), DOI [10.1145/2980179.2980254](https://doi.org/10.1145/2980179.2980254) [META-ONLY]. The algorithm details below come from the peer-reviewed reimplementation and analysis [VERIFIED]: **Monod, A., Delon, J. & Veit, T. 2021, "An Analysis and Implementation of the HDR+ Burst Denoising Method", IPOL 11, DOI [10.5201/ipol.2021.336](https://doi.org/10.5201/ipol.2021.336)** — [IPOL](https://www.ipol.im/pub/art/2021/336/):
  - Alignment: Gaussian pyramids, "typically 4-level, with successive downsampling factors of 2, 4 and 4". Tiles are "8×8 at the coarsest level and 16×16 at other levels", with search radius "+ or − 4 pixels" around the upsampled coarser estimate.
  - Distance: **D_p(u,v) = Σᵢ Σⱼ |T(i,j) − I(i+u+u₀, j+v+v₀)|ᵖ, p ∈ {1,2}**. The L2 version is expanded as ΣT² + ΣI² − 2ΣT·I, so the cross-term can be computed via FFT or box filters.
  - Subpixel: fit "a bivariate quadratic polynomial to the 3×3 window surrounding the L2 distance minimum", D₂ ≈ ½[u v]ᵀA[u v] + bᵀ[u v] + c, and solve for its minimum.
  - Noise model: **σ²(x) = λ_s·x + λ_r** (shot plus read noise). The parameters can come from the DNG `NoiseProfile` tag.
  - Merge (per channel, per 16×16 tile, in the 2D DFT domain): **T̃₀(ω) = (1/N) Σ_{z=0}^{N−1} [ (1 − A_z(ω))·T_z(ω) + A_z(ω)·T₀(ω) ]**, with **A_z(ω) = |D_z(ω)|² / (|D_z(ω)|² + c·σ²(ρ(T₀)))** and D_z = T₀ − T_z. In the original, c = k·τ with k = n²·(1/4²)·2 (the IPOL authors call this justification "questionable").
  - Spatial post-denoise: T̂₀(ω) = |T̃₀|² / (|T̃₀|² + f(ω)·σ²/N) · T̃₀, with f(ω) = γ|ω| in the IPOL reimplementation.
  - Tiles overlap by half and are blended with a modified raised-cosine window w(x) = ½ − ½cos(2π(x+½)/n), which sums to 1 at half-overlap.
  - The IPOL paper notes the alignment is "sensitive to noise" and to occlusions, and that it is "designed to run quickly on … smartphone systems on a chip".
- **Liba, O., Murthy, K., Tsai, Y.-T., Brooks, T., Xue, T., Karnad, N., He, Q., Barron, J. T., Sharlet, D., Geiss, R., Hasinoff, S. W., Pritch, Y. & Levoy, M. 2019**, "Handheld Mobile Photography in Very Low Light", ACM TOG 38(6), Art. 164 (SIGGRAPH Asia 2019), DOI [10.1145/3355089.3356508](https://doi.org/10.1145/3355089.3356508); arXiv:[1910.11336](https://arxiv.org/abs/1910.11336). [VERIFIED full text]:
  - Total capture time "≤6 seconds for our system". Number of frames = 6 s ÷ exposure, "limited to a maximum number of frames set by the device's memory constraints".
  - "When the device is handheld, we capture up to 333 ms exposures; when we detect the device is stabilized, we capture up to 1 s exposures", with stability detected from the gyroscope.
  - Motion metering uses a CDF-based prediction: find v_min such that Pr[v_min ≥ min_{k=1..K} v_k | {v_i}] ≥ P_conf.
  - The reference frame is "chosen as the sharpest frame in the burst". Alignment uses 4-level pyramids with tile size **16, 32 or 64 px depending on noise** ("in the dark it is 64 pixels").
  - Merging uses the HDR+ Fourier merge on 16×16 tiles with a spatially varying "temporal strength" c·f_tz. Here f_tz is derived from a mismatch map **m_tz = d²_tz / (d²_tz + s·σ²_tz)** (shrinkage form), and spatial denoising is increased where merging was limited.
  - It runs within about 2 s on device and works down to about 0.3 lux.
  - The paper's own limitation: night skies get brightened by global tone mapping, so "one would need to apply a different tonal adjustment specifically to the sky" (later addressed by the astro-mode sky segmentation).
- **Wronski, B., Garcia-Dorado, I., Ernst, M., Kelly, D., Krainin, M., Liang, C.-K., Levoy, M. & Milanfar, P. 2019**, "Handheld Multi-Frame Super-Resolution", ACM TOG 38(4), Art. 28 (SIGGRAPH 2019), DOI [10.1145/3306346.3323024](https://doi.org/10.1145/3306346.3323024); arXiv:[1905.03277](https://arxiv.org/abs/1905.03277). [VERIFIED full text]:
  - Raw Bayer frames are aligned locally to a base frame. Each frame's contribution is accumulated per color channel through kernel regression, with anisotropic kernels whose covariance comes from the local gradient structure tensor (computed on half-resolution luminance made from 2×2 Bayer quads). The accumulated result is normalized at the end.
  - Robustness: compute the local standard deviation σ and the color difference d between base and aligned frame, then **R = s·exp(−d²/σ²) − t** (clamped), with tuned s and t. Differences below σ are merged (denoise), differences near a fraction of σ are merged (aliasing, so super-resolution), and larger differences are rejected (misalignment).
  - Performance on Adreno 630 (Pixel 3): 15.4 ms fixed cost + 7.8 ms/MPix per frame, 22 MB/MPix memory. "Because our algorithm merges the input images in an online fashion, the memory consumption is not dependent on the frame count."
  - Implemented in OpenGL ES pixel shaders. The abstract states 100 ms per 12-MP frame.
- Liba et al. cite Wronski et al. as usable for low-light denoising and give details in Appendix B [VERIFIED] — [arXiv:1910.11336](https://arxiv.org/abs/1910.11336).
- Survey (title confirmed only via search result): Delbracio, M. et al. 2021, "Mobile Computational Photography: A Tour", arXiv:[2102.09000](https://arxiv.org/abs/2102.09000) [META-ONLY; authors not checked].
- Newer 2024–2026 work checked:
  - "Lucky High Dynamic Range Smartphone Imaging" (Li, Yan, Tseng, Zhang, Finkelstein, Chen, Heide; arXiv:[2604.19976](https://arxiv.org/abs/2604.19976), Apr 2026). It is a bracketed-HDR merge using lightweight networks producing per-pixel convex combinations of input pixels. **It does not address astrophotography or star alignment** [VERIFIED abstract].
  - "NTIRE 2026 Low-light Enhancement" challenge (arXiv:2608.09782) appeared in search but was not opened; it is not astro-specific.

### Inferences
- **Google's tile-based HDR+ alignment is not ideal for star fields.** Pure-sky tiles contain mostly noise plus a few point sources, and the IPOL analysis notes alignment is "sensitive to noise". This explains why star-specific methods (global star transform) are preferred for the sky. A plausible design is a hybrid: a global star-based transform for the sky mask and tile alignment (or identity on a tripod) for the foreground. The Kainz & Murthy blog does not disclose whether Google uses star-based registration for the sky.
- The **frequency-domain pairwise Wiener merge** (HDR+) and the **robustness-weighted kernel accumulation** (Wronski) are both well suited to Metal. They work per tile or per pixel with no global sorting. Wronski's online accumulation (Σ w·x and Σ w per pixel and channel) gives memory independent of N, which is ideal for the long astro sequences (15+ frames, 12–48 MP) where keeping all raw frames is infeasible.
- With a 16 s per-frame limit and a tripod, phone frame-to-frame shifts are deterministic sky rotation plus small tripod settling. Motion metering (Liba) matters less in astro mode; gyroscope stability detection is still useful to pick the exposure schedule.
- Apple-side: I found no published Apple paper describing the iPhone Night mode/astro pipeline. Treat any claims about it as unverified.

### Gaps
- I did not read the HDR+ 2016 paper itself (only the IPOL reimplementation), so exact original parameter values (e.g. the precise noise-shaping function f(ω)) are not verified. IPOL explicitly states "we do not know the specifics" of f(ω).
- I found **no peer-reviewed 2020–2026 paper specifically on on-device smartphone astrophotography stacking** (star registration plus merge) despite targeted searches. Search results returned consumer blogs and app pages only. This should be reported as a literature gap, not an absence of practice.
- Google has not published how astro mode registers stars vs. foreground beyond the blog's general statement.

---

## 4. Robust stacking with outlier rejection, noise weighting, SNR, and streaming/online variants

### Takeaway
Stacking software (Siril, PixInsight, DeepSkyStacker) offers a ladder of rejection estimators chosen by stack size:
- percentile clipping for ≤ about 6 frames;
- sigma / MAD / winsorized sigma clipping for medium stacks;
- linear-fit clipping for large stacks with gradients;
- generalized ESD for very large stacks (Siril suggests over 50).

Weights are typically 1/σ²_noise (or FWHM/star-count based). For a phone, the exact versions need the full per-pixel stack. Bounded-memory alternatives:
- a two-pass approach (pass 1 computes a robust reference such as a running median approximation or the mean and σ from Welford; pass 2 re-reads frames from flash and clips);
- a single-pass "reference-relative" clipping as in HDR+ and Wronski (compare each new frame against the reference or current estimate and down-weight large deviations).

### Cited Findings
- **Siril pixel rejection algorithms** [VERIFIED docs] — [Siril docs: Stacking](https://siril.readthedocs.io/en/latest/preprocessing/stacking.html):
  - Percentile clipping: "a one step rejection algorithm ideal for small sets of data (up to 6 images)".
  - Sigma clipping: "an iterative algorithm which will reject pixels whose distance from median will be farthest than two given values in sigma units" (σ_low, σ_high).
  - MAD clipping: the same as sigma clipping but uses the Median Absolute Deviation. It is "generally used for noisy infrared image processing" and is "most effective" for drizzled CFA images.
  - Median sigma clipping: rejected pixels "are replaced by the median value".
  - Winsorized sigma clipping: "very similar to Sigma Clipping method, except it is supposed to be more robust for outliers detection".
  - Linear fit clipping: "fits the best straight line (y=ax+b) of the pixel stack and rejects outliers". It "performs very well with large stacks and images containing sky gradients".
  - Generalized Extreme Studentized Deviate Test: "used to detect one or more outliers in a univariate data set that follows an approximately normal distribution", recommended for "more [than] 50 images".
  - Weighting options: number of stars, weighted FWHM (wFWHM), noise (background noise), number of images/integration time.
  - Normalization: additive / multiplicative, with or without scaling. The default is additive with IKSS estimators.
  - Rejection maps can be output, and the docs show **satellite trail removal** as the example.
- Winsorized sigma clipping replaces outliers with "the nearest pixel value within the sigma thresholds" (winsorizing) instead of discarding them, then applies the sigma criteria to the modified stack. GESD's "ESD outliers" parameter bounds the outlier fraction (e.g. 0.3 for 10 pixels means 0–3 outliers) — [PixInsight forum thread](https://pixinsight.com/forum/index.php?threads/image-integeration-winsorized-sigma-clipping-and-nuances.16768/), plus a secondary blog snippet (search result only; the blog host did not resolve at fetch time) [secondary source, lower confidence]. The official PixInsight ImageIntegration documentation URL returned 404 in this session.
- The HDR+ merge is itself a robust per-frequency weighting relative to a reference frame. Its weight A_z → 1 (keep reference) when |D_z|² ≫ cσ², which acts as soft outlier rejection without a full stack [VERIFIED] — [Monod et al. 2021, IPOL](https://doi.org/10.5201/ipol.2021.336).
- Wronski's robustness R = s·exp(−d²/σ²) − t is applied per frame in an online accumulation whose memory "is not dependent on the frame count" [VERIFIED] — [arXiv:1905.03277](https://arxiv.org/abs/1905.03277).
- Kainz & Murthy (Google) also use a spatio-temporal neighbour comparison for hot-pixel rejection across the frame sequence [VERIFIED] — [Google Research blog](https://research.google/blog/astrophotography-with-night-sight-on-pixel-phones/).

### Inferences (formulas are textbook; marked where not verified against a fetched source)
- [UNVERIFIED / textbook] **SNR gain.** For N frames with independent noise σ and equal weights, the mean has σ/√N, so SNR improves by √N (e.g. 15 frames ≈ 3.9×). Read noise is paid N times compared with one long exposure of the same total time, so with high read noise and dark skies, fewer, longer frames (≤ 16 s per Google) are preferable.
- [UNVERIFIED / textbook] **Noise-weighted mean**: x̂ = Σ wᵢxᵢ / Σ wᵢ with wᵢ = 1/σᵢ², and resulting variance 1/Σ(1/σᵢ²). This is optimal (minimum-variance unbiased) for Gaussian noise.
- [UNVERIFIED / textbook] **Median.** For large N under Gaussian noise its asymptotic efficiency is 2/π ≈ 0.64 relative to the mean, i.e. noise about 1.25× higher than the mean for the same N. This is the reason clipping-then-averaging is preferred over a plain median.
- [UNVERIFIED / textbook] **κ-σ clipping (per pixel stack)**: iterate { m = median; s = std (or 1.4826·MAD); reject xᵢ with xᵢ < m − κ_low·s or xᵢ > m + κ_high·s } until no change. Typical κ is about 2.5–3.
  - Winsorized variant: before computing s, clamp values outside m ± 1.5s to those bounds, iterate to convergence, then clip.
  - Linear fit clipping: fit xᵢ (sorted) ≈ a + b·i by least squares and reject points whose residual exceeds κ·(mean absolute deviation).
  - GESD (Rosner 1983): for r = 1..r_max, Rᵢ = max|x − x̄|/s and remove that point. Compare with λᵢ = (n−i)·t_{p,n−i−1} / sqrt((n−i−1+t²)(n−i+1)), p = 1 − α/(2(n−i+1)). The number of outliers is the largest i with Rᵢ > λᵢ.
  - These are the standard definitions, but I could not retrieve the official PixInsight or Siril math pages in this session.
- [UNVERIFIED / textbook] **Welford's online algorithm (Welford 1962, Technometrics 4(3):419–420)**: for each new value x, with n ← n+1: δ = x − μ; μ ← μ + δ/n; M2 ← M2 + δ·(x − μ); variance = M2/(n−1). The weighted variant (West 1979) uses W ← W + w; μ ← μ + (w/W)·δ. On Metal this means 3 float32 buffers per channel (μ, M2, n or W). For 12 MP RGB that is about 3 × 12M × 3 × 4 B ≈ 430 MB. On 48 MP it would not fit comfortably, so it should be done on the 12 MP binned output or in half precision.
- **Bounded-memory strategies for a phone** (my design inference):
  - (a) **Single pass, reference-relative**: keep the running weighted mean (and optionally Welford M2). For each new aligned frame, compute z = (x − μ)/max(σ_pred, sqrt(M2/(n−1))), where σ_pred comes from the sensor noise model σ²(x) = λ_s x + λ_r. Reject or soft-weight pixels with |z| > κ (or use the Wronski-style exp(−d²/σ²) weight).
    - This kills satellite/plane trails and hot pixels after a few frames.
    - It is weak on the first 2–3 frames, so seed the reference with the median of the first 3 frames held in memory.
  - (b) **Two pass**: pass 1 streams frames to compute μ and σ (Welford); frames are stored compressed or written to disk (raw or HEIF). Pass 2 re-reads them for true κ-σ clipping. This is more exact, but needs storage and doubles processing time.
  - (c) **Small-N exact**: with ≤ about 15 frames (Google-like), you can keep all aligned frames downsampled or in half-float tiles and do exact sigma or winsorized clipping per tile. Tile-wise processing bounds peak memory.
- Using the **sensor noise model** (λ_s, λ_r from the DNG NoiseProfile, or calibrated) as σ instead of the sample σ makes rejection usable with very small N. This is how HDR+ handles it.

### Gaps
- The official PixInsight ImageIntegration reference page (formulas, recommended stack sizes per algorithm) returned 404, and the blog source was unreachable. PixInsight-specific recommendations are therefore **not verified** here.
- The Siril docs page did not expose the exact math for winsorized and linear-fit clipping (descriptions only). DeepSkyStacker documentation was not fetched.
- The Welford 1962 citation is from memory (not fetched).

---

## 5. Drizzle and its relevance to undersampled phone sensors

### Takeaway
Drizzle (Fruchter & Hook 2002) linearly reconstructs a finer-grid image from dithered, undersampled frames by "shrinking" each input pixel to a drop (pixfrac) and adding its overlap-weighted flux to output pixels. It needs sub-pixel dithers and many frames, and it produces correlated noise. Phone star images are often near-critically sampled or undersampled, and sky rotation plus tripod jitter provides natural dithering. Bayer/CFA drizzle (as in Siril) can replace demosaicing, analogous to Wronski et al.'s kernel-regression super-resolution, which is the mobile-optimized relative of the idea.

### Cited Findings
- **Fruchter, A. S. & Hook, R. N. 2002**, "Drizzle: A Method for the Linear Reconstruction of Undersampled Images", PASP 114(792), 144, DOI [10.1086/338393](https://iopscience.iop.org/article/10.1086/338393); arXiv:[astro-ph/9808087](https://arxiv.org/abs/astro-ph/9808087). [VERIFIED full text]:
  - The method "preserves photometry and resolution, can weight input images according to the statistical significance of each pixel, and removes the effects of geometric distortion".
  - pixfrac is "the ratio of the linear size of the drop to the input pixel". Interlacing is the limit pixfrac → 0 and shift-and-add is pixfrac = 1. The scale s is output pixel size divided by input pixel size.
  - Update equations: **W′_{xo,yo} = a_{xi,yi,xo,yo}·w_{xi,yi} + W_{xo,yo}** and **I′_{xo,yo} = (d_{xi,yi}·a·w·s² + I_{xo,yo}·W_{xo,yo}) / W′_{xo,yo}**. Here a is the fractional overlap of the drop with the output pixel, and s² conserves surface intensity.
  - "After each input image is processed, there is a usable output image and weight", so it is inherently **online/streaming**.
  - Noise: "the noise in adjacent pixels will be correlated", so a measurement of noise on the output pixel scale "underestimates the noise on larger scales".
  - The paper also covers drizzling with cosmic-ray rejection.
- Siril offers drizzle as a registration-output alternative. Memory and disk "needed to create and process drizzled images [is multiplied] by the square of the Drizzle scale factor". MAD clipping is noted as "most effective" for drizzled CFA images — [Siril registration docs](https://siril.readthedocs.io/en/latest/preprocessing/registration.html); [Siril stacking docs](https://siril.readthedocs.io/en/latest/preprocessing/stacking.html).
- Wronski et al. 2019 show that natural hand tremor provides enough sub-pixel coverage for super-resolution on phones. Their kernel-regression merge directly on Bayer data "eliminat[es] separate demosaicing" and runs in real time on a mobile GPU [VERIFIED] — [arXiv:1905.03277](https://arxiv.org/abs/1905.03277).

### Inferences
- The drizzle update is a scatter-add per input pixel (each drop touches 1–4 output pixels for pixfrac ≤ 1 and s ≤ 1). On Metal this is better implemented as a **gather**: for each output pixel, inverse-map to the input and integrate the overlap. Alternatively, use a Gaussian-kernel splat (Wronski-style), which avoids atomics. Memory is (I, W) at s⁻² resolution, independent of N.
- **Practical value on iPhone:**
  - Main-camera stars typically span a few pixels after demosaic and lens blur, so 2× drizzle gives limited gains unless frames are numerous (tens or more) and well dithered.
  - **CFA (Bayer) drizzle**, which avoids interpolating missing colors, is likely the bigger win: it improves star color and removes demosaic artifacts on point sources.
  - Sky rotation between frames provides sub-pixel dither for free on a tripod.
- Because drizzle is linear and weighted, it combines poorly with median-type rejection unless rejection is done first (e.g. a pass-1 reference and pass-2 drizzle with masked outliers, as in HST pipelines). Alternatively, use per-drop robustness weights (Wronski's R).

### Gaps
- I found no peer-reviewed evaluation of drizzle (or Bayer drizzle) specifically for smartphone sensors on star fields.
- I did not verify iPhone sensor pixel pitch or typical star FWHM in pixels in this session. A sibling researcher may cover camera specs.

---

## 6. Satellite and plane trail rejection

### Takeaway
With ≥ about 5–10 registered frames, per-pixel statistical rejection (sigma, winsorized or GESD) removes most satellite and plane trails automatically, because a trail occupies a given pixel in only one frame. Siril demonstrates this with rejection maps. With few frames (phone: 6–15), explicit line detection helps: Hough or probabilistic Hough, Line Segment Detector, or U-Net plus Hough (ASTA) on the difference between the frame and the running reference, then masking the detected trail in that frame before merging. Plane trails (blinking lights, dashed) are harder for line detectors but still transient, so temporal rejection handles them.

### Cited Findings
- Siril rejection maps show satellite trail removal by stacking rejection [VERIFIED docs] — [Siril docs: Stacking](https://siril.readthedocs.io/en/latest/preprocessing/stacking.html).
- **Stoppa, F., Groot, P. J., Stuik, R., Vreeswijk, P., Bloemen, S., Pieterse, D. L. A. & Woudt, P. A. 2024**, "Automated Detection of Satellite Trails in Ground-Based Observations Using U-Net and Hough Transform", A&A 692, A199, DOI [10.1051/0004-6361/202451663](https://doi.org/10.1051/0004-6361/202451663); arXiv:[2407.19461](https://arxiv.org/abs/2407.19461). ASTA is a U-Net first stage followed by a Probabilistic Hough Transform refinement. It was validated on 20,000 patches and run on about 200,000 MeerLICHT images [VERIFIED abstract].
- Search-result summaries (not opened in full) state that classical Hough is "highly sensitive to background noise" and often needs per-image tuning, and that the Line Segment Detector (LSD) is more automatic — [arXiv:2509.16771 "Artificial Satellite Trails Detection Using U-Net Deep Neural Network and Line Segment Detector Algorithm"](https://arxiv.org/abs/2509.16771) [snippet only; authors and venue not verified].
- **STARLINC**: Kim, S., Lee, H., Kwon, D., Choi, K., Park, S., Kim, M.-R., Lee, J.-E. & Lee, J. (submitted Aug 29, 2026), "STARLINC: Satellite Trail Artifact Removal using Inter-Frame Correlation", arXiv:[2608.29145](https://arxiv.org/abs/2608.29145). The abstract page says it was accepted at ECCV 2026. It uses synthetic trail generation for training, **differential maps from consecutive (temporally adjacent) exposures** to isolate transients, and heatmaps for localization in pixel-level segmentation [VERIFIED abstract; venue claim taken from arXiv page, not independently confirmed].
- Other 2025–2026 items surfaced by search but not opened: "Using Deep Learning to Identify Artificial Satellite Trails…" (arXiv:2509.04081) and "StreakMind" (arXiv:2605.03429) [titles only; unverified content].

### Inferences
- For an on-device pipeline, a cheap and robust approach is:
  1. Compute a difference image Δ = aligned_frame − running_reference.
  2. Threshold at k·σ_noise using the sensor noise model.
  3. Run a Hough transform or LSD on the binary mask, restricted to the sky mask. OpenCV is available on iOS but adds size; a small custom Hough is about 100 lines of code.
  4. Dilate the detected line by a few pixels.
  5. Set the merge weights to 0 along it.

  This is what STARLINC's "differential maps" idea formalizes with learning. For N ≥ about 8, plain per-pixel κ-σ clipping relative to the reference is probably enough, and line detection becomes an optional quality improvement.
- Stars themselves move between frames before alignment, so trail detection must run **after** registration, on the sky region. Otherwise star motion and foreground mismatch create false linear features.

### Gaps
- No smartphone-specific trail-rejection evaluation was found.
- arXiv:2509.16771, 2509.04081 and 2605.03429 were not read in full, so their methods and results are unverified beyond search snippets.

---

## 7. Assessment: which methods are practical on-device (iPhone, Metal/Accelerate) for real-time or near-real-time stacking

### Takeaway
All core components are feasible on-device. The bottleneck is per-pixel work (calibration, warp, merge) and memory, not the registration math. Recommended stack, in order of value and feasibility:
1. hot-pixel map and sky mask;
2. SEP-like detection plus weighted centroid (GPU detection, CPU centroid);
3. astroalign-style triangle matching plus RANSAC with a homography or rotation model, with gyroscope and previous-frame priors;
4. GPU warp;
5. online weighted accumulation with reference-relative robust weighting (Wronski-style R or HDR+-style Wiener) using the sensor noise model;
6. optional second pass of exact κ-σ or winsorized clipping if frames are stored;
7. optional Bayer drizzle or kernel-regression output.

### Cited Findings
- Wronski-style merge: 7.8 ms/MPix per frame plus 15.4 ms fixed on a 2018 mobile GPU (Adreno 630), with memory 22 MB/MPix independent of frame count [VERIFIED] — [arXiv:1905.03277](https://arxiv.org/abs/1905.03277).
- HDR+-style alignment is "designed to run quickly on … smartphone systems on a chip" [VERIFIED] — [Monod et al. 2021](https://doi.org/10.5201/ipol.2021.336). Liba et al.'s whole low-light pipeline runs in about 2 s on device [VERIFIED] — [arXiv:1910.11336](https://arxiv.org/abs/1910.11336).
- astroalign caps at 50 stars and does O(n log n) k-d tree matching. Runtime is dominated by image size (i.e. source extraction), not by the number of stars [VERIFIED] — [arXiv:1909.02946](https://arxiv.org/abs/1909.02946).
- SEP is a dependency-free C library and can be compiled for iOS [VERIFIED claim of no external dependencies] — [JOSS 10.21105/joss.00058](https://doi.org/10.21105/joss.00058).
- Google astro mode shows that a 15 × 16 s capture with hot-pixel removal, an on-device sky CNN, alignment and merge ships on Pixel 3/3a/4-class hardware [VERIFIED] — [Google Research blog](https://research.google/blog/astrophotography-with-night-sight-on-pixel-phones/).
- Drizzle can run online (usable output after each frame) [VERIFIED] — [Fruchter & Hook 2002](https://arxiv.org/abs/astro-ph/9808087). Memory scales with the square of the drizzle scale factor [VERIFIED] — [Siril registration docs](https://siril.readthedocs.io/en/latest/preprocessing/registration.html).

### Inferences (practicality matrix — my assessment)

| Component | Method | On-device fit | Notes |
|---|---|---|---|
| Hot pixels | Dark-frame map, or spatio-temporal outlier test (Google) | Excellent (GPU, per pixel) | Do before detection |
| Background | Mesh 3σ-clip + mode (SExtractor), or median-flatten (astrometry.net) | Excellent | Use a downsampled mesh (e.g. 64 px) on GPU; bilinear upsample is fine |
| Detection | Gaussian matched filter + kσ threshold + local max | Excellent (MPS blur + compute kernel) | Restrict to sky mask |
| Centroid | Weighted/windowed centroid; optional Gaussian fit on about 20 stars for FWHM | Excellent (CPU/vDSP, few hundred stars) | PSF fit only for quality weights |
| Matching | astroalign triangles (4-NN, (L2/L1, L1/L0), k-d tree, tol 0.1) + RANSAC | Excellent (< about 1 ms on CPU for 50 stars, my estimate) | Port directly to Swift; use the previous transform as prior |
| Model | Similarity (short/narrow) → rotation-only K R K⁻¹ (tripod, inferred) → homography (Siril default, wide field) | Excellent | Apply lens-distortion correction first for wide/ultrawide lenses |
| Quad hashing | astrometry.net | Poor for frame-to-frame (needs large index files) | Only if plate-solving or absolute pointing is required |
| Warp | Bilinear/bicubic/Lanczos on GPU | Excellent | Clamp to avoid Lanczos ringing (Siril note) |
| Merge (streaming) | Weighted mean + reference-relative robust weight (Wronski R / HDR+ Wiener / κσ vs noise model) | Excellent; memory O(1) in N | Seed the reference with the median of the first 3 frames |
| Merge (exact) | κ-σ / winsorized / linear-fit / GESD over the full stack | Good only for small N or tiled two-pass | GESD needs N > 50 (Siril), so not relevant for phones |
| Foreground | Separate tile-based (HDR+) or identity alignment; blend with sky mask | Good | Needs a sky segmentation model (Core ML) or heuristic |
| Trails | Per-pixel rejection (N ≥ about 8); Hough/LSD on difference image for small N | Good | Learning-based (STARLINC/ASTA) only if a Core ML port is available |
| Drizzle | Online drizzle / Bayer drizzle / kernel-regression super-resolution | Moderate (memory s²; correlated noise) | Most value as CFA drizzle for star color |

- **Real-time preview**: a "live stack" that updates after each 4–16 s frame is easily achievable. Per-frame budget is detection (tens of ms) + matching (about 1 ms) + warp and accumulate (tens of ms at 12 MP, extrapolated from Wronski's 7.8 ms/MPix on 2018 hardware). That is far below the exposure time.

### Gaps
- No published benchmark of these specific algorithms on Apple GPUs (Metal) was found. All iPhone timings above are extrapolations from Adreno 630 numbers and are **not verified**.
- No literature validates the rotation-only (K R K⁻¹) star registration model or gyroscope-aided star matching on phones. These are engineering proposals.
