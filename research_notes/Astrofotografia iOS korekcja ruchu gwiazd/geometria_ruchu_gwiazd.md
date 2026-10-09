# Geometria pozornego ruchu gwiazd na matrycy smartfona (iOS): model ruchu dla sumowania wielu klatek z korekcją

Research context: October 2026. Notes in English, written for direct implementation. Everything marked **[derived]** is my own derivation from the cited building blocks. I checked these derivations numerically with a short NumPy script (Rodrigues rotation plus pinhole projection, φ=50°, f=2796 px). The script results are quoted where they matter. Everything marked **[verify on device]** is an Apple convention that no primary source pins down unambiguously.

Notation used throughout:
- φ = geographic latitude, λ = longitude (east +), A = azimuth (from N through E), h = altitude, δ = declination, α = right ascension, H = local hour angle = LST − α.
- ENU = local East-North-Up frame. NWU = North-West-Up = CoreMotion `xTrueNorthZVertical` frame (X = true north, Z = up, so right-handed ⇒ Y = west).
- ω = ω_sid = Earth's rotation rate relative to the stars.
- K = 3×3 intrinsic matrix (pixels). Camera frame = OpenCV convention (x right, y down, z forward along the optical axis).

---

## 1. Sidereal rate and the rotation of the celestial sphere in a local frame

### Takeaway
Use ω = 7.292115×10⁻⁵ rad/s (≈ 15.041″/s ≈ 15.041°/h). In a local horizon frame the sky is a rigid rotation about the fixed celestial-pole unit vector p = (0, cos φ, sin φ) in ENU, or (cos φ, 0, sin φ) in NWU. The rotation angle is **−ω·t**, which makes stars rise in the east and set in the west. The rotation is exact for distant stars apart from refraction, aberration and precession, all of which are negligible over a single night.

### Cited Findings
- IERS mean angular velocity of the Earth: Ω = 7.292 115 0(1)×10⁻⁵ rad/s (0.014 ppm uncertainty). The nominal value Ω_N = 7.292 115 146 706 4×10⁻⁵ rad/s is exact by definition (epoch 1820) — [IERS EOP-PC Useful Constants](https://hpiers.obspm.fr/eop-pc/index.php?index=constants&lang=en)
- From the same source: the ratio of mean solar day to stellar day is k′ = 1.002 737 811 911 354 48 (IERS Conventions 2003). The stellar day is 2π/Ω_N = 86 164.098 903 691 s. The sidereal day (equinox-referred, so it includes precession) is 86 164.090 530 832 88 s — [IERS EOP-PC Useful Constants](https://hpiers.obspm.fr/eop-pc/index.php?index=constants&lang=en)
- The same value 7.292115×10⁻⁵ rad/s appears in IERS96/2003/2010 and WGS84 — [search summary of IERS/WGS84 references](https://ahrs.readthedocs.io/en/stable/geodesy/wgs84.html)
- The Earth rotation rate used in the field-rotation literature is 15.04106858°/h (360° per sidereal day) — [RASC Calgary, Field Rotation](https://calgary.rasc.ca/field_rotation.htm)

### Inferences
- **Numerical values [derived]:** ω = 7.2921150e-5 rad/s = 4.17807e-3 °/s = **15.04107 arcsec/s** = 15.04107 °/h. 1/ω = 13 713.44 s, which is the "13713" constant in the NPF formula (section 4). The stellar/sidereal difference is about 0.0084 s/day (≈1×10⁻⁷ relative), which is irrelevant here.
- **Hour-angle → ENU unit vector [derived, standard spherical astronomy]:**
  ```
  s_ENU(H, δ; φ) = [ −cos δ · sin H,
                      cos φ · sin δ − sin φ · cos δ · cos H,
                      sin φ · sin δ + cos φ · cos δ · cos H ]
  H(t) = LST(t) − α,   dH/dt = ω  (in sidereal-rate units)
  ```
  Checks: H=0, δ=φ gives the zenith. H=+90° gives a point west of the meridian.
- **Rotation form [derived, numerically verified to 2e-16]:** for any star, s(t) = R_p(−ω·(t−t₀)) · s(t₀). Here R_p(θ) is the right-handed Rodrigues rotation about the unit pole vector p:
  ```
  R_p(θ) = I + sin θ·[p]ₓ + (1 − cos θ)·[p]ₓ²,     [p]ₓ = [[0,−p_z,p_y],[p_z,0,−p_x],[−p_y,p_x,0]]
  p_ENU = (0, cos φ, sin φ)      p_NWU = (cos φ, 0, sin φ)      (northern and southern hemisphere alike; φ<0 puts p below the horizon on the north side, and the visible SCP is −p)
  ```
  The sign check: at φ=0 the zenith star is s=(0,0,1). R_p(+θ) would move it toward east (y×z = x), so the physical motion is −θ (toward west).
- Absolute time (UTC/UT1) and longitude are needed only if you want to place named stars (α,δ) or compute H. The **relative** motion between sub-exposures depends only on p (that is, φ and the camera attitude) and on Δt. This is the key simplification for stacking.

### Gaps
- I did not fetch Meeus "Astronomical Algorithms" or the USNO/Astronomical Almanac GMST/ERA formulas. For absolute LST use the IERS 2010 ERA formula, ERA = 2π(0.7790572732640 + 1.00273781191135448·D_UT1). This is from the IERS Conventions; I did not re-open the primary document in this session, so the formula should be checked against the IERS Conventions 2010, ch. 5.

---

## 2. From sky rotation to camera pixels: CoreMotion attitude, device→camera axes, homography H = K·R·K⁻¹, and the J = M·I model

### Takeaway
On a tripod the camera attitude is constant. The inter-frame warp is therefore a *conjugate rotation*: H(Δt) = K · R_c(−ω·Δt) · K⁻¹, where R_c is the sky rotation expressed in camera coordinates. It is a rotation about the pole vector **p_cam = C · A · p_ref**, where A is the CoreMotion attitude and C is the fixed device→camera axis permutation. So the whole model has only 2 unknown degrees of freedom (the pole direction in the camera frame) plus K. The sign/transpose convention of `CMAttitude.rotationMatrix` is **not documented** and must be verified on the device using gravity.

### Cited Findings
- `xTrueNorthZVertical`: "a reference frame where the Z axis is vertical and the X axis points to the geographic north pole". Yaw is 0 when the device X axis is aligned with true north. It requires an available magnetometer **and** Location Services (to compute magnetic→true north). If the magnetometer is uncalibrated, Core Motion prompts the user to move the device — [Apple: xTrueNorthZVertical](https://developer.apple.com/documentation/coremotion/cmattitudereferenceframe/xtruenorthzvertical); the iOS SDK header `CMAttitude.h` adds "may require device movement to calibrate the magnetometer" — [Apple: CMAttitudeReferenceFrame](https://developer.apple.com/documentation/coremotion/cmattitudereferenceframe)
- `CMAttitude` offers a rotation matrix, a quaternion and Euler angles. The header defines `CMRotationMatrix` as m11…m33 and `CMQuaternion` as q.x·i + q.y·j + q.z·k + q.w. The docs describe the output as "a direction cosine matrix (DCM)" — [Apple: CMAttitude](https://developer.apple.com/documentation/coremotion/cmattitude); `rotationMatrix` is described only as "a rotation matrix representing the device's attitude" — [Apple: rotationMatrix](https://developer.apple.com/documentation/coremotion/cmattitude/rotationmatrix)
- `multiply(byInverseOf:)` replaces the receiver with "the attitude change relative to" the given attitude — [Apple: multiply(byInverseOf:)](https://developer.apple.com/documentation/coremotion/cmattitude/multiply(byinverseof:))
- Device-motion update frequency is hardware dependent, "usually at least 100 Hz". Roll, pitch and yaw are 0 when the device orientation matches the reference frame, and lie in −π..π — [Apple: Getting processed device-motion data](https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data)
- Device axes (iPhone, portrait): X runs across the width (left − → right +), Y along the height (bottom − → top +), and Z perpendicular through the screen (back − → front +) — [NSHipster: CMDeviceMotion](https://nshipster.com/cmdevicemotion/); Apple shows the same axes as a figure — [Apple: CMMotionManager](https://developer.apple.com/documentation/coremotion/cmmotionmanager)
- ARKit camera space is "constant with respect to device orientation". The x-axis "points along the long axis of the device, from the front-facing camera toward the Home button". The y-axis points up in `landscapeLeft`, and z points away from the device on the screen side — [Apple: ARCamera.transform](https://developer.apple.com/documentation/arkit/arcamera/transform)
- For pure rotation (t₀ = t₁ = 0) the homography between two views is H₁₀ = K₁R₁R₀⁻¹K₀⁻¹. Estimating a 3D rotation (± focal) is "intrinsically more stable than estimating a full 8-d.o.f. homography" — [Szeliski, Image Alignment and Stitching: A Tutorial, MSR-TR-2004-92](https://www.microsoft.com/en-us/research/wp-content/uploads/2004/10/tr-2004-92.pdf)
- The intrinsic matrix K = [[fx,0,ox],[0,fy,oy],[0,0,1]] is given in pixels, with origin at the upper-left of the frame — [Apple: intrinsicMatrix](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/intrinsicmatrix)

### Inferences

**2a. Frames and the chain of transforms [derived]**

1. **Sky (reference) frame.** Use NWU = CoreMotion `xTrueNorthZVertical`. The pole is p_ref = (cos φ, 0, sin φ). ENU→NWU: (E,N,U) ↦ (N, −E, U).
2. **Device attitude A (3×3).** Define A so that v_dev = A · v_ref, mapping reference coordinates into device coordinates. Apple does not say whether `rotationMatrix` is A or Aᵀ, so **[verify on device]**:
   - Read `CMDeviceMotion.gravity` (expressed in the device frame, units of g). Gravity points down, i.e. (0,0,−1) in the reference frame.
   - If gravity_dev ≈ M·(0,0,−1) = −(m13, m23, m33), then M = A (ref→device).
   - If instead gravity_dev ≈ −(m31, m32, m33), then M = Aᵀ (device→ref).
   - The quaternion must be consistent with the matrix; check it the same way.

   This one-line test removes the ambiguity. A recent open-source PR on a sky-view app makes the same point: a wrong guess mirrors every bearing, "gravity decides it" — [GitHub bergeronK/Twilight PR #108, search snippet](https://github.com/bergeronK/Twilight/pull/108).
3. **Device → camera C (constant, back camera, native landscape sensor buffer).** From the ARKit definition, convert ARKit camera space (x toward Home button = −Y_dev, y up in landscapeLeft = +X_dev, z toward screen = +Z_dev) to OpenCV camera space (x right, y down, z forward = −z_ARKit):
   ```
   x_cam = −Y_dev,   y_cam = −X_dev,   z_cam = −Z_dev
   C = [[ 0,−1, 0],
        [−1, 0, 0],
        [ 0, 0,−1]]          det(C) = +1 (proper rotation)
   ```
   **[verify on device]**: this assumes your pixel buffer has the sensor's native (landscape) orientation, as with ARKit's `capturedImage`. If AVCaptureConnection rotates the buffer (videoRotationAngle / videoOrientation) or mirrors it, compose C with that 90°/180° in-plane rotation. Lenses are also not perfectly aligned to the IMU (a few tenths of a degree). Image-based refinement (section 6) absorbs this.
4. **Pole in the camera frame:** p_cam = C · A · p_ref (unit vector). Its image is the homogeneous point e = K · p_cam. When e₃ > 0, the pole projects to pixel (e₁/e₃, e₂/e₃), which may be far outside the frame. When e₃ < 0, the pole is behind the camera and the anti-pole is the fixed point.

**2b. Per-pixel motion for any t [derived, numerically verified]**

Pixel u₀ = (x,y,1)ᵀ at time t₀ (undistorted pixel coordinates; see section 3). At time t:
```
d₀   = K⁻¹ u₀                                 (bearing ray in camera frame)
d(t) = R_{p_cam}(−ω (t − t₀)) · d₀              (Rodrigues about p_cam)
u(t) ~ K · d(t)          → (x_t, y_t) = (u₁/u₃, u₂/u₃)
H(t) = K · R_{p_cam}(−ω Δt) · K⁻¹  =  K · C · A · R_{p_ref}(−ω Δt) · Aᵀ · Cᵀ · K⁻¹
```
- This is Szeliski's K₁R₁R₀⁻¹K₀⁻¹ with K₀=K₁ and R₁R₀⁻¹ = the conjugated sky rotation. Hartley & Zisserman call this a "conjugate rotation" homography, H = K R K⁻¹; its eigenvectors are the image of the rotation axis plus the two circular points (I did not fetch H&Z, see Gaps).
- The fixed point of H is the pole image e (the eigenvector of H with real eigenvalue). Star trails are the images of small circles about p: conics, which are circles only if p_cam ∥ optical axis.
- Velocity field (first order, small Δt): u̇ ≈ −ω · J_π(d) · (p_cam × d)·f-scaling. In practice just evaluate H(t) on the GPU per frame; it is one 3×3 matrix per sub-exposure.
- Numeric check at φ=50°, f=2796 px (iPhone main camera at 12 MP), Δt=60 s. The image-centre displacement equals ω·Δt·cos δ_c·f to 0.01 px in all 6 tested pointings (e.g. 12.05 px when looking south at h=30°). Here δ_c is the declination of the optical axis.

**2c. Image-formation model J = M·I [derived]**

- Continuous: the sub-exposure of length τ starting at t_k is
  ```
  J_k(u) = ∫_{t_k}^{t_k+τ} I( W_{t−t_ref}^{-1}(u) ) dt / τ  ⊛ PSF_optics(u)  + n_k(u)
  ```
  Here I is the true sky expressed at reference epoch t_ref, and W_Δt(u) = π(K R_{p_cam}(−ωΔt) K⁻¹ u) is the warp from 2b, composed with the lens distortion D (section 3) when working in raw pixels: W̃ = D ∘ W ∘ D⁻¹.
- Discrete linear operator: J_k = M_k · I + n_k with M_k = B_k · S_k, where:
  - S_k is the warp (resampling) operator for Δt_k = t_k − t_ref.
  - B_k is the spatially varying motion-blur operator. It is a line integral along the local trail, with length L(u) = ω·τ·|∂π/∂d · (p_cam × d)| ≈ ω·τ·cos δ(u)·f_px near the centre, and direction tangent to the small circle about the pole.
- The stacking estimate is then Î = (Σ_k S_kᵀ W_k J_k) / (Σ_k S_kᵀ W_k 1) (inverse-warp then average, with weights or masks). An optional deconvolution of the residual B (the blur within one sub-exposure) is possible. For B ≪ PSF (section 4) B can be ignored.
- The foreground (landscape) does **not** follow M. It has the identity warp, so the model must be applied only to the sky mask. This is the "two-layer" J = M_sky·I_sky + I_ground. *(This is an inference; the segmentation is out of my scope.)*

### Gaps
- **Apple does not document** whether `CMAttitude.rotationMatrix` maps reference→device or device→reference, nor its row/column layout semantics. Only the gravity test above resolves this. I found no primary Apple statement.
- I found no Apple document giving the exact angular misalignment between the IMU axes and the back-camera optical axis, or the native sensor buffer orientation for AVCapture (as opposed to ARKit). Treat the C above as a starting guess and refine it from stars.
- Hartley & Zisserman 2nd ed. (Ch. 8, "conjugate rotation") was not accessible online; the formula is confirmed via Szeliski's tutorial.

---

## 3. Camera intrinsics K, lens distortion, and how to get them on iOS

### Takeaway
Take K per frame from `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` (video data output), or from `AVCameraCalibrationData.intrinsicMatrix` (photo output). Rescale it to your buffer size using `intrinsicMatrixReferenceDimensions`. Apply Apple's 1-D radial lookup table about `lensDistortionCenter`. Note that calibration-data delivery requires **disabling** geometric distortion correction (GDC). As a fallback, f_px = (W/2)/tan(HFOV/2) from `videoFieldOfView`.

### Cited Findings
- K = [[fx,0,ox],[0,fy,oy],[0,0,1]], "all values are expressed in pixels". fx = fy for square pixels. ox, oy is the principal point, with origin at the upper-left of the frame (relative to the top-left corner of the top-left pixel; pixel values sample pixel centres) — [Apple: intrinsicMatrix](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/intrinsicmatrix)
- The values are meaningful only relative to `intrinsicMatrixReferenceDimensions` — [Apple: intrinsicMatrixReferenceDimensions](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/intrinsicmatrixreferencedimensions)
- `pixelSize`: "the size of one pixel at intrinsicMatrixReferenceDimensions in millimeters" — [Apple: pixelSize](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/pixelsize)
- `extrinsicMatrix` is a 4×3 [R|t] (t in mm), pose relative to a reference camera (camera-to-world), column-major — [Apple: extrinsicMatrix](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/extrinsicmatrix)
- Per-frame K on video: set `isCameraIntrinsicMatrixDeliveryEnabled` before `startRunning()`. Each sample buffer then carries `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` — [Apple: isCameraIntrinsicMatrixDeliveryEnabled](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled). The CoreMedia header (`CMSampleBuffer.h`) states it is a CFData holding a **column-major** matrix_float3x3 [[fx,0,ox],[0,fy,oy],[0,0,1]], fx and fy in pixels, origin at the upper left (iOS SDK header, verified locally in Xcode SDK).
- Distortion model: "a one-dimensional lookup table of 32-bit float values evenly distributed along a radius from the center of the distortion to a corner, with each value representing a magnification of the radius", assuming symmetric (radial) distortion — [Apple: lensDistortionLookupTable](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/lensdistortionlookuptable)
- `inverseLensDistortionLookupTable` re-applies the distortion to a rectified image — [Apple: inverseLensDistortionLookupTable](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/inverselensdistortionlookuptable)
- `lensDistortionCenter`: offset from the top-left in reference dimensions. "When making an image rectilinear, use the distortion center rather than the optical center" — [Apple: lensDistortionCenter](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/lensdistortioncenter)
- Apple's reference implementation (`AVCameraCalibrationData.h`, iOS SDK) does the following:
  - r_max = √(max(cx, W−cx)² + max(cy, H−cy)²).
  - For a point at radius r: val = r·(n−1)/r_max, linearly interpolate mag between table[⌊val⌋] and table[⌊val⌋+1] (use table[n−1] if r ≥ r_max).
  - Output = c + (1 + mag)·(p − c).
  - **To rectify:** for each output (undistorted) pixel, call it with `lensDistortionLookupTable` to find where to sample in the distorted image. To map a distorted point to undistorted space, use `inverseLensDistortionLookupTable`.
  - All inputs must be in the same coordinate system/resolution.

  (Header text read from the local Xcode iPhoneOS SDK; the same text is summarised at [Apple: lensDistortionLookupTable](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/lensdistortionlookuptable).)
- `isCameraCalibrationDataDeliverySupported` is true only when `isVirtualDeviceConstituentPhotoDeliveryEnabled` is true **and** `isContentAwareDistortionCorrectionEnabled` is false, **and** the device's `isGeometricDistortionCorrectionEnabled` is false — [Apple: isCameraCalibrationDataDeliverySupported](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/iscameracalibrationdatadeliverysupported)
- GDC defaults to **true** when supported — [Apple: isGeometricDistortionCorrectionEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isgeometricdistortioncorrectionenabled)
- `videoFieldOfView` = the format's horizontal FOV in degrees, 0 if unknown — [Apple: videoFieldOfView](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/videofieldofview). `geometricDistortionCorrectedVideoFieldOfView` = the HFOV after GDC — [Apple: geometricDistortionCorrectedVideoFieldOfView](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/geometricdistortioncorrectedvideofieldofview)
- `lensPosition` is 0.0–1.0, "doesn't correspond to an exact physical distance", and "1.0 doesn't represent focus at infinity" — [Apple: lensPosition](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensposition)
- iPhone 16 Pro rear cameras: 48 MP Fusion 24 mm (35 mm-equiv) f/1.78; 48 MP Ultra Wide 13 mm f/2.2, 120° FOV; 12 MP 5× Telephoto 120 mm f/2.8, 20° FOV. The spec page gives **no pixel pitch** — [Apple Support: iPhone 16 Pro tech specs](https://support.apple.com/en-us/121031)

### Inferences
- **Fallback K [derived]:** f_px = (W_px/2) / tan(HFOV/2), with HFOV = `videoFieldOfView` (or the GDC-corrected value if GDC is on), and principal point ≈ ((W−1)/2, (H−1)/2).
- From 35 mm-equivalent focal F_eq on a 4:3 sensor [derived]: f_px ≈ (diag_px/2)·F_eq/21.63 mm, where 21.63 = half-diagonal of 36×24 mm.

  | Camera (iPhone 16 Pro) | Resolution | f_px |
  |---|---|---|
  | 13 mm ultra-wide | 4032×3024 | ≈ 1514 px |
  | 24 mm main | 4032×3024 | ≈ 2796 px |
  | 24 mm main | 8064×6048 | ≈ 5591 px |
  | 120 mm tele | 4032×3024 | ≈ 13 978 px |

  These are estimates only, because "equivalent focal length" is a marketing rounding; replace them with the intrinsicMatrix.
- Physical focal length = f_px · pixelSize (mm). Assuming a 1.22 µm pixel at 48 MP (an assumption; Apple does not publish it on the spec page), the main camera has f ≈ 6.8 mm.
- **Focus breathing:** set focus to infinity manually. Because `lensPosition`=1.0 is not guaranteed to be infinity, focus on a bright star and lock it. f_px changes slightly with lensPosition, so read K per frame or re-estimate it from stars.
- **The ultra-wide lens has strong barrel distortion.** The H = K R K⁻¹ model is valid only in **undistorted** coordinates: W̃ = D ∘ (K R K⁻¹) ∘ D⁻¹. Either rectify every frame first, or warp the distorted grid directly with the composite mapping.
- If you keep Apple's GDC enabled (to get "pretty" frames), the calibration LUT no longer applies. Either disable GDC and do your own rectification, or estimate distortion from stars yourself (e.g. radial polynomial k₁,k₂ fitted during registration).

### Gaps
- No primary Apple source lists per-device pixel pitch, the true physical focal length, or whether `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` reflects lensPosition changes frame by frame (assumed but not verified).
- I did not verify whether AVCameraCalibrationData is available for single (non-virtual) back cameras with long manual exposures on current iOS. The doc ties photo-output delivery to virtual-device constituent delivery.

---

## 4. Star trail length per sub-exposure; 500 rule; NPF rule; max sub-exposure for smartphones

### Takeaway
Near the optical axis the trail length is L ≈ ω · τ · cos δ · f_px pixels. That is ≈0.20 px/s for a 24 mm-equivalent phone camera at 12 MP and δ=0, ≈0.41 px/s at 48 MP, and ≈0.11 px/s for the 13 mm ultra-wide. Applying the full NPF formula with k=1–2 to a phone main camera gives ~7–14 s at the celestial equator. The 500 rule (~21 s for 24 mm equivalent) yields ~4 px trails at 12 MP, which is too long for "pinpoint" stars.

### Cited Findings
- NPF rule by "fred_76" (Frédéric Michaud), Société d'Astronomie du Havre, published 28 March 2013 — [sahavre.fr: Les coulisses de la règle NPF](https://sahavre.fr/wp/les-coulisses-de-la-regle-npf/). Formulas from that page:
  - **Simple:** t ≈ (35·N + 30·p_µm) / f_mm, assuming k=2, δ=0, negligible seeing.
  - **Complete:** t ≈ (k/2)·(d_Airy + d_seeing + d_Bayer) / v_sensor = **k·(16.9·N + 13.7·p_µm + 0.1·f_mm) / (f_mm·cos δ)**.
  - Components: d_Airy = 4.47·λ·N (λ=550 nm), d_seeing = f·tan α ≈ f·α (α≈3″ typical), d_Bayer = 2p, v_sensor ≈ f·cos δ / 13713 (m/s).
  - k = 1 round star, 2 slight trail ("moves by one diameter", acceptable), 3 visible trail.
- On the same page:
  - The 500 rule derives from a film-era CoC of 0.029 mm: t ≈ 13713·0.029/(f·crop·cos δ) ≈ 400–600/(f·crop).
  - A "4-crop" simplified rule exists but is "absolutely not applicable to small smartphone sensors". The author states NPF supersedes the 500 rule.

  — [sahavre.fr](https://sahavre.fr/wp/les-coulisses-de-la-regle-npf/)
- NPF is implemented in PhotoPills ("Spot Stars" calculator) — [PhotoPills Spot Stars calculator](http://www.photopills.com/calculators/spotstars) (search-result level)

### Inferences
- **Pixel-domain trail formula [derived, numerically verified at image centre]:** L_px(τ) = ω·τ·cos δ·f_px, with ω=7.2921e-5 rad/s. Off-axis the factor is |∂π/∂d·(p_cam×d)|/|p_cam×d|, which grows ~1/cos²θ toward the edge for a rectilinear lens. Edges move faster in pixels, which matters for the ultra-wide.
- **Equivalent NPF in pixels [derived]:** v_sensor/p = ω·cos δ·f_px. With k=1 the tolerance ≈ (d_Airy + d_seeing + 2p)/2. So τ_max(k) ≈ k·(d_Airy/p + d_seeing/p + 2)/(2·ω·cos δ·f_px).
- Worked example, 24 mm-equivalent main camera, f/1.78, assumed p=1.22 µm (48 MP), f≈6.82 mm:
  - d_Airy = 4.47·0.55·1.78 ≈ 4.38 µm (≈3.6 px).
  - Seeing ≈ 0.1 µm, negligible at this f.
  - Simple NPF: (35·1.78 + 30·1.22)/6.82 ≈ **14.5 s**.
  - Full NPF: k=1 → **7.0 s**, k=2 → 13.9 s (δ=0).
- At δ=60° the limits double (1/cos δ). Near the pole they diverge, but the field still rotates (section 5).
- The 500 rule for 24 mm equivalent gives 20.8 s → trail 4.2 px at 12 MP / 8.5 px at 48 MP (δ=0). For 13 mm it gives 38.5 s → 4.2 px at 12 MP.
- **Implication for the app:** with motion-corrected stacking, the per-frame limit applies only to the *intra-frame* blur B_k (section 2c). Choose τ ≈ 2–10 s on main/UW cameras (trail ≤1–2 px) and let the warp S_k handle the inter-frame motion. If τ must exceed NPF, deblurring with the known linear kernel B_k is possible because its direction and length are known per pixel.

### Gaps
- No primary source for iPhone pixel pitch or physical focal length (see section 3). The NPF numbers above depend on that assumption.
- The NPF author's own statement on smartphones is only that the "4-crop" shortcut doesn't apply. The full formula is general, but I found no published validation of NPF on phone sensors with Quad-Bayer binning.

---

## 5. Field rotation: why it happens and the rate formula; what it means for a fixed phone

### Takeaway
The classic formula ω_fr = ω·cos φ·cos A / cos h gives the rotation of the star field relative to the *alt-az* frame (local vertical) at the target. It applies to alt-az mounts that track the target. For a **fixed** tripod camera the relevant motion is the rigid sky rotation about the pole image e. Locally, a star patch near the image centre rotates in the image at **ω·sin δ_c** (δ_c = declination of the optical axis) while translating at ω·cos δ_c·f_px. Both come out of H(t) automatically.

### Cited Findings
- Field rotation rate (deg/h) = K·cos(az)/cos(alt), where K = 15.04106858°/h·cos(latitude). It is maximal at the equator and zero at the poles — [RASC Calgary: Field Rotation with an Alt-Az Telescope Mount](https://calgary.rasc.ca/field_rotation.htm); a detailed analysis is in [Frey, JDSO vol. 7 no. 4, "An Analysis of Field Rotation Associated with Altitude-Azimuth Mounts"](http://www.jdso.org/volume7/number4/Frey_216_226.pdf) (found via search, not fetched in full)

### Inferences
- **Why [derived]:** the sky rotates about p (the polar axis), but an alt-az system keeps "up" = zenith. The angle between the zenith direction and the pole direction at the target (the parallactic angle q) changes with time: dq/dt = ω·cos φ·cos A/cos h.
- **Example values at φ=50°:**

  | Pointing | Rate |
  |---|---|
  | A=0, h=10° | 0.164°/min |
  | A=0, h=50° (pointing at the pole) | 0.251°/min |
  | A=180°, h=30° | −0.186°/min |
  | A=90° (east) | 0 |

- **Fixed camera [derived and numerically verified]:** compute the local rotation of the image Jacobian of H(t) at the image centre (polar decomposition). The result equals ω·Δt·sin δ_c exactly in 6 test pointings, and differs from the alt-az formula (e.g. looking south at h=30°, φ=50°: 0.044° per minute vs. the alt-az formula's 0.186°). Reason: the fixed camera does not counter-rotate to keep the zenith up; it is a rigid rotation about p, whose component along the line of sight is ω·(p·z_cam) = ω·sin δ_c.
  - Translation at the centre = ω·cos δ_c·f_px.
  - Pointing at the pole: pure rotation about the frame centre (ω = 0.25°/min = 15°/h).
  - Pointing at the equator (δ_c=0): pure local translation plus perspective curvature.
- The **pole image e = K·p_cam** may be far outside the frame, or behind the camera. The warp is still exactly H(t). Do **not** approximate as "rotation about an in-frame point + translation" over long sequences; use the 3×3 homography (or the full rotation on the sphere for the ultra-wide).
- Rotation of the frame edges over a 1-hour session can be large. Pointing at the NCP gives 15°, which at 2000 px from centre is ≈ 520 px of arc. Corners rotate out of the field, so the stacked field of full coverage shrinks: plan the crop/mosaic accordingly.

### Gaps
- I did not fetch the full Frey JDSO paper. The RASC page is a secondary (club) source, though the formula is standard.

---

## 6. Accuracy: attitude/heading error, refraction, image-based refinement, fitting the pole from star correspondences

### Takeaway
CoreMotion heading can be off by ~5–10° (or worse) in true-north mode, which would put the predicted pole in the wrong place. The sensor model should therefore only be the **initialisation**: estimate the pole direction p_cam (2 DOF) and optionally f_px and distortion from star matches across the whole sequence. Use a constrained rotation fit (angle fixed to ω·Δt), or Wahba/Kabsch/SVD per pair and then extract the axis. Refraction below ~20° altitude causes non-rigid, altitude-dependent deviations (arcminutes) that a rigid rotation cannot absorb.

### Cited Findings
- `CLHeading.headingAccuracy` = "maximum deviation (measured in degrees) between the reported heading and the true geomagnetic heading". A negative value means invalid (uncalibrated or strong interference) — [Apple: headingAccuracy](https://developer.apple.com/documentation/corelocation/clheading/headingaccuracy)
- `CMDeviceMotion.heading` (0–360°) is available only in the magnetic/true-north frames; negative otherwise — [Apple: CMDeviceMotion.heading](https://developer.apple.com/documentation/coremotion/cmdevicemotion/heading). `CMDeviceMotion.magneticField` carries a calibration `accuracy` field — [Apple: magneticField](https://developer.apple.com/documentation/coremotion/cmdevicemotion/magneticfield)
- Studies of mobile compass deviation typically found errors of 5–10°, with 9–18° "not uncommon" on iPhone even after calibration. Calibration was transient (< 1 h) — [Open University ORO: "Compass Errors in Mobile Augmented Reality Navigation Apps"](https://oro.open.ac.uk/84729/1/84729AAM.pdf) (seen via search snippet only; the PDF returned 403 so I could not verify details or authors)
- A student study reports 1.37° heading accuracy with an improved calibration algorithm — [Journal of Emerging Investigators](https://emerginginvestigators.org/articles/23-153/pdf) (search-level; low-tier source)
- **Bennett (1982):** R[arcmin] = cot(h_a + 7.31/(h_a + 4.4)), with h_a the apparent altitude in degrees; used in USNO's Vector Astrometry Software. **Saemundsson:** R[arcmin] = 1.02·cot(h + 10.3/(h + 5.11)), with h the true altitude; it agrees with Bennett to about 0.4″ (the source does not specify over what altitude range, and the two disagree by about 5′ at the horizon, see table below) — [Atmospheric refraction (encyclopedia mirror)](https://www.hellenicaworld.com/Science/Physics/en/AtmosphericRefraction.html); [Özlem 2016, Impact of Atmospheric Refraction on Asr Time](https://astronomycenter.net/pdf/ozlem_2016.pdf)
- Wahba's problem (1965): find the rotation that best maps a set of unit vectors (e.g. star directions) to another. Davenport's q-method and SVD are the most robust solutions; QUEST/ESOQ are fast variants for star trackers — [Markley & Mortari, "How to Estimate Attitude from Vector Observations", NASA NTRS](https://ntrs.nasa.gov/archive/nasa/casi.ntrs.nasa.gov/19990104598.pdf); [Markley, "Equivalence of Two Solutions of Wahba's Problem"](https://www.researchgate.net/publication/265009277_Equivalence_of_Two_Solutions_of_Wahba's_Problem); [An Analytic Solution to Wahba's Problem, arXiv:1309.5679](https://arxiv.org/pdf/1309.5679)
- Rotation-only models (3–5 params) are more stable than a full 8-DOF homography — [Szeliski MSR-TR-2004-92](https://www.microsoft.com/en-us/research/wp-content/uploads/2004/10/tr-2004-92.pdf)

### Inferences
- **Effect of attitude error [derived]:**
  - A heading error ε_A rotates p_ref about the vertical by ε_A. A pitch/roll error moves it about horizontal axes. CoreMotion pitch/roll come from gravity and are typically far better than heading.
  - The resulting error in the predicted per-frame displacement is ≈ ω·Δt·f_px·|Δp_cam|. Example: Δt=60 s, f_px=2796 (12.2 px total motion), ε=5° (0.087 rad) gives ~1.1 px error per minute of sequence. That accumulates: ~64 px after an hour. So sensor-only prediction is not sufficient for multi-minute stacks, but it is an excellent search window for matching.
- **Refraction [derived from Bennett]:**

  | Apparent altitude | R | dR/dh |
  |---|---|---|
  | 5° | 9.9′ | −1.58′/° |
  | 10° | 5.4′ | −0.51′/° |
  | 20° | 2.7′ | −0.14′/° |
  | 45° | 1.0′ | −0.035′/° |

  Consequences:
  - The sky near the horizon is compressed vertically: over a 1° tall patch at h=10° the differential is ~0.5′ ≈ 0.4 px for f_px=2796 (1 px ≈ 1.23′). At h=5° it is ~1.3 px/°.
  - As a star sinks over an hour its refraction changes by several arcminutes, which equals several pixels at 12 MP.
  - Model: apply refraction to the *true* direction s(t) before projection: h_app = h_true + R(h_true) (Saemundsson). Even better, let a low-order residual field be fitted per frame.
- **Recommended pole/rotation estimation from stars [derived]:**
  1. Detect stars (centroids) per frame. Undistort with the LUT (section 3). Convert to unit bearings b = normalize(K⁻¹u).
  2. Match frame k to the reference frame using the sensor-predicted H(t) as an initial guess (gating radius ≈ a few % of f·ω·Δt + attitude uncertainty).
  3. **Constrained global fit (recommended):**
     - Unknowns: p_cam (2 DOF, parameterised on S²), optionally a time offset t₀ and focal scale s (fx=fy=s·f₀), plus radial distortion k₁.
     - Residual: r_ik = π(K R_{p}(−ω(t_k−t_ref)) K⁻¹ u_i,ref) − u_i,k.
     - Solve by Levenberg–Marquardt with a robust (Huber/Cauchy) loss over all frames simultaneously.
     - The known angular rate ω is a very strong constraint: one direction parameter pair explains every frame.
  4. **Unconstrained alternative:**
     - For each frame pair, solve Wahba/Kabsch: B = Σ w_i b′_i b_iᵀ, B = UΣVᵀ, R = U·diag(1,1,det(UVᵀ))·Vᵀ.
     - Then axis = eigenvector of R with eigenvalue 1 (or vee(R−Rᵀ)/(2 sin θ)), angle θ = acos((tr R − 1)/2).
     - Check θ ≈ ω·Δt. A mismatch means a focal-length error, because a wrong f scales the bearings non-rigidly.
     - The axis from a single short-Δt pair is ill-conditioned (θ is tiny, e.g. 0.25° per minute). Use the longest baseline available (first↔latest frame) or the global fit.
  5. Add a per-frame small residual homography or polynomial (e.g. 2nd-order) for refraction, lens-model error and thermal focus drift. Reject frames with clouds, aircraft or satellites via the RANSAC inlier ratio.
  6. With p_cam estimated, recover the true pointing without any magnetometer: p_cam gives the pole direction in the camera, and gravity (accelerometer) gives "up". Together they fix the full camera→NWU attitude, including true north. This can be used to **re-calibrate the heading** and to compute δ, cos δ and the trail lengths per pixel.
- Plate solving against a catalogue (e.g. astrometry.net-style) is an alternative absolute solution. It is out of scope here but compatible: it yields A directly.

### Gaps
- No Apple primary source quantifies CoreMotion attitude accuracy (heading or tilt) in degrees. The compass-error numbers come from third-party studies I could only see at snippet level.
- I did not find a published paper specifically on "fitting rotation about an unknown axis from star trails for smartphone stacking". The method above combines Wahba/Kabsch (sourced) with the known-rate constraint (my inference).
- The refraction formulas were cited from secondary mirrors. The primary sources (Bennett, J. Navigation 1982; Saemundsson, Sky & Telescope 1986; Meeus ch. 16) were not fetched.

---

## 7. Rolling shutter in long sub-exposures

### Takeaway
Negligible for star motion. A smartphone sensor's readout skew is milliseconds to tens of milliseconds, while stars move ≤ ~1 px/s even on the 120 mm tele. So the row-dependent time offset produces ≪ 0.1 px of distortion per frame. Use the mid-exposure timestamp per frame. Row-time correction only matters if the phone is moving (vibration), not for sky drift.

### Cited Findings
- Readout (scan) time is the time difference between recording the top and bottom of the frame, measured in ms. An example 24 MP sensor reads out in ~50 ms — [search summary; Horshack Rolling Shutter database](https://github.com/horshack-dpreview/RollingShutter); [gyroflow rollingshutter tools](https://github.com/gyroflow/rollingshutter)

### Inferences
- **[derived]** Max sky-induced skew = v_px·T_readout. For the 120 mm tele (≈1.0 px/s) with T=50 ms that is 0.05 px. For the main camera at 12 MP (0.2 px/s) it is 0.01 px. Negligible.
- Timestamping: use the presentation timestamp of each frame plus τ/2 (and the row offset if you want to be pedantic) as t_k in H(t_k − t_ref). Sync CoreMotion timestamps (seconds since boot) with sample-buffer timestamps (host clock).

### Gaps
- No primary source for iPhone sensor readout times was found. The value above is a generic example, not an iPhone measurement.
