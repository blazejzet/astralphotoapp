# iOS platform constraints & existing apps for a stacking astrophotography camera (AstralCamera) — state as of Oct 2026

Legend: **[DOC]** = Apple documentation / WWDC / Apple newsroom; **[DEV-FORUM]** = developer report (measured/anecdotal); **[VENDOR]** = third-party app vendor claim; **[PRESS]** = press/journalism. Apple doc links below point at developer.apple.com pages; their content was read via the documentation JSON endpoints on 2026-10-02.

---

## 1. Max manual exposure duration, ISO range, custom exposure behaviour, Night mode (is ">1 s" possible?)

### Takeaway
Third-party apps get **at most ~1 s per single sub-exposure** on modern iPhones (older ones 1/2–1/3 s; exact value is per-`AVCaptureDevice.Format` and must be read at runtime from `activeFormat.maxExposureDuration`). Apple DTS explicitly says there is **no supported way** for an app to reproduce the Camera app's 30 s Night mode; so AstralCamera must stack many ≤1 s frames itself. Critically, with `AVCapturePhotoOutput` you must set `photoQualityPrioritization = .speed`, otherwise the system may silently override your custom duration/ISO with multi-frame fusion.

### Cited Findings
- `exposureDuration` must lie between the active format's `minExposureDuration` and `maxExposureDuration`; it is set only via `setExposureModeCustom(duration:iso:completionHandler:)`. **[DOC]** — [exposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration)
- `setExposureModeCustom` throws if duration/ISO are out of range; **"photoQualityPrioritization … defaults to balanced, which allows photo capture to temporarily override the capture device's exposure duration and ISO if the scene is dark enough to require multi-image fusion … To ensure that the system honors the device exposure duration and ISO values while in custom or locked mode, you must set photo quality prioritization to speed."** **[DOC]** — [setExposureModeCustom(duration:iso:completionHandler:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))
- `exposureTargetBias`: in `.custom` exposure mode it **only affects metering** (`exposureTargetOffset`), not the actual duration/ISO. **[DOC]** — [exposureTargetBias](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuretargetbias)
- `activeMaxExposureDuration` only caps the *auto*-exposure algorithm (can be raised up to format `maxExposureDuration`); it resets when `activeFormat`/`sessionPreset` change. **[DOC]** — [activeMaxExposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemaxexposureduration)
- Developer report: raising `activeMaxExposureDuration` alone did nothing — auto-exposed frames were still capped at `activeVideoMaxFrameDuration`; setting both worked but the viewfinder became "terribly slow" in low light. **[DEV-FORUM, 2019, unanswered]** — [Apple Dev Forums 124228](https://developer.apple.com/forums/thread/124228)
- Developer report: `ContinuousAutoExposure` limits exposure to ~1/30 s; custom mode with `activeFormat.maxExposureDuration` + `maxISO` gives a 1 s exposure; `isLowLightBoostSupported` always returned false. **[DEV-FORUM, 2023]** — [Apple Dev Forums 736856](https://developer.apple.com/forums/thread/736856)
- Lux Optics (Halide) support article title + search snippet: max shutter is 1 s because "the latest iPhones have hardware that is limited to a duration of one second. Old iPhones have limited durations of 1/2 a second, or 1/3 a second." **[VENDOR]** — [Halide support: Why is the maximum shutter speed limited to one second?](https://luxoptics.zendesk.com/hc/en-us/articles/360000998412-Why-is-the-maximum-shutter-speed-limited-to-one-second) (page returned 403 to direct fetch; content seen only via search snippet)
- Cocologics (LowLight Plus) support: "On some formats, the longest exposure is 1 second, on others it's half a second or a third of a second"; longer exposures are achieved by fusing multiple captures. **[VENDOR, snippet only]** — [Cocologics help](https://cocologicshelp.zendesk.com/hc/en-us/articles/360012889357-How-can-I-set-exposure-to-more-than-1-second-LowLight-Plus)
- NightCap version 9.6 (2019) note: doubled very-low-light performance with "1 second exposure times" on iPhone XS/XR. **[VENDOR]** — [NightCap App Store](https://apps.apple.com/us/app/nightcap-camera/id754105884)
- Measured latency: after `setExposureModeCustom` with a long duration, the completion handler fires after ~3× the exposure (iPhone 14 Pro, ~3 s) to ~4× (iPhone 8, ~1.3 s) — i.e. 2–3 frames are lost every time exposure/ISO/focus changes. **[DEV-FORUM, May 2024, unanswered]** — [Apple Dev Forums 751112](https://developer.apple.com/forums/thread/751112)
- Example ISO range for one iPhone 15 Pro format: `minISO` 55, `maxISO` 12320 (crash report from react-native-vision-camera). **[DEV-REPORT, single format]** — [VisionCamera issue #2640](https://github.com/margelo/react-native-vision-camera/issues/2640)
- Apple DTS (Greg) answering "How can I implement the 30-second long exposure of the built-in night mode?" (asker had stacked 30× 1 s RAW and found it "far inferior"): **"There is no supported way for an app to implement this functionality, please file an enhancement request."** **[DOC-equivalent: Apple DTS]** — [Apple Dev Forums 769970](https://developer.apple.com/forums/thread/769970)
- Halide publicly asked for "A Night Mode API" (2022) — i.e. not exposed to third parties. **[VENDOR]** — [Halide on X](https://x.com/halidecamera/status/1527728518582239232); unanswered 2020 forum question on using Night mode via AVFoundation — [Apple Dev Forums 665022](https://developer.apple.com/forums/thread/665022)
- Night mode: iPhone 11 and later; capture time shown next to the icon; "Max" slider extends capture time; tripod/solid surface recommended; Night mode Time‑lapse with tripod. No astrophotography specifics on the page (dated Feb 18, 2026). **[DOC]** — [Apple Support: Use Night mode on your iPhone](https://support.apple.com/en-us/102519)
- Night mode on tripod: "works in 1 to 30 second intervals depending on conditions like steadiness and ambient lighting"; handheld typically 1/3/5 s (iPhone 11 era; ultra‑wide not supported on iPhone 11/11 Pro; gyroscope-based tripod detection). **[PRESS]** — [MacRumors Night mode guide](https://www.macrumors.com/guide/night-mode/)
- Conflicting press claim: a 2025/26 article says iOS 26 "Night Mode Max" raised the ceiling "from 10 seconds to 30 seconds" on tripod. **[PRESS]** — [Yahoo Tech](https://tech.yahoo.com/ai/apple-intelligence/articles/hidden-ios-26-feature-transformed-190000555.html); **contradicted** by MacRumors (30 s on tripod since iPhone 11 / iOS 13) — [MacRumors](https://www.macrumors.com/guide/night-mode/). Treat the "new in iOS 26" claim as unreliable.
- Night mode, flash and macro photos are always saved at 12 MP in the Camera app. **[PRESS/forum]** — [MacRumors forum: ProRAW 48MP](https://forums.macrumors.com/threads/enable-proraw-48mp-or-just-normal-photos.2366587/)
- `isLowLightBoostEnabled` indicates the device "switched into a special mode in which it perceives more light"; `automaticallyEnablesLowLightBoostWhenAvailable` is settable only if `isLowLightBoostSupported` (which developers report as false on modern iPhones). **[DOC]** — [isLowLightBoostEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/islowlightboostenabled), [isLowLightBoostSupported](https://developer.apple.com/documentation/avfoundation/avcapturedevice/islowlightboostsupported); **[DEV-FORUM]** [736856](https://developer.apple.com/forums/thread/736856)
- iPhone 18 Pro (Sept 2026): 48 MP Main with **variable aperture ƒ/1.48–ƒ/4** (six blades, four settings); "An API is available to developers for even more control across the aperture range in their apps." **[DOC/Apple newsroom]** — [Apple Newsroom: iPhone 18 Pro](https://www.apple.com/newsroom/2026/09/apple-debuts-iphone-18-pro-and-iphone-18-pro-max/); aperture opens to let in ~50% more light in the dark **[PRESS]** — [MacRumors](https://www.macrumors.com/2026/09/09/both-iphone-18-pro-models-variable-aperture-camera/). NightCap 10.1 already adds "manual aperture control on iPhone 18 Pro" — [NightCap App Store](https://apps.apple.com/us/app/nightcap-camera/id754105884)
- Legacy `lensAperture` property: "This value doesn't change" (fixed f-number on older devices). **[DOC]** — [lensAperture](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensaperture)

### Inferences
- Design for **N × (≤1 s) sub-exposures**; read `activeFormat.maxExposureDuration`, `minISO`, `maxISO` per format/lens at runtime and pick the format that gives 1 s (some video/high-res formats may give less). Always use `.custom` mode (never `continuousAutoExposure`) and, for photo output, `photoQualityPrioritization = .speed` with `maxPhotoQualityPrioritization` ≥ `.speed`.
- Never change exposure/ISO/focus mid-sequence: each change costs ~2–3 frame periods (≈2–3 s at 1 s exposures).
- Stacking 30×1 s does not equal one 30 s exposure in read-noise terms (read noise accumulates per frame), consistent with the DTS thread asker's complaint; Apple's own Night mode is itself multi-frame, so the gap is mostly Apple's tuned fusion/denoising, not a hidden long single exposure — but the exact frame lengths Apple uses internally are not public.
- On iPhone 18 Pro, use the new aperture API to force ƒ/1.48 (widest) for astro; verify the API name in the iOS 27 SDK (not confirmed here).

### Gaps
- No authoritative table of `maxExposureDuration` / `maxISO` per iPhone 12–18 model and per format was found; must be measured on-device (dump `device.formats`). Whether any 2024–2026 format exceeds 1.0 s was not found in any source.
- Exact name/semantics of the iPhone 18 Pro aperture API were not verified (`isLensApertureControlSupported` doc page did not resolve).
- Apple's internal Night mode frame duration/ISO for 30 s astro shots is undocumented.

---

## 2. RAW capture vs. video data output — best path for hundreds of sub-frames; RAW video (ProRes RAW / Apple Log 2)

### Takeaway
Two viable paths: (a) **`AVCapturePhotoOutput` Bayer RAW** (single-frame, unprocessed, DNG, 1 s max), issued as a loop of captures with `.speed` prioritization — best data quality but per-shot overhead and only ≤4-ish frames per bracket; (b) **`AVCaptureVideoDataOutput`** at the longest frame duration a format allows (processed YUV/BGRA, ISP denoise/tonemapping baked in), giving a continuous gapless stream plus per-frame intrinsics. ProRAW is *not* suitable (it is already multi-frame fused). iOS 26 added `AVVideoCodecType.proResRAW`, and iPhone 17 Pro+ record ProRes RAW with APIs for developers — potentially a continuous raw-ish stream, but frame-duration limits for long exposure are unverified.

### Cited Findings
- Bayer RAW: iOS 10+, single-camera only, `.photo` preset, **single capture only (no fusion)**, DNG. ProRAW: iOS 14.3+, iPhone 12 Pro+, demosaiced linear RGB, **"generated from multiple demosaiced exposures with image fusion"**, 12-bit companded, ~14 stops, 10–40 MB/file; supports Night mode/Deep Fusion with `.balanced`/`.quality`. Detect formats via `availableRawPhotoPixelFormatTypes` + `AVCapturePhotoOutput.isBayerRAWPixelFormat(_:)` / `isAppleProRAWPixelFormat(_:)`; ProRAW pixel format example `l64r`; bit depth can be lowered to 10/8 via `AVVideoAppleProRAWBitDepthKey`. **[DOC/WWDC21]** — [WWDC21 "Capture and process ProRAW images"](https://developer.apple.com/videos/play/wwdc2021/10160/)
- `isAppleProRAWEnabled`: ProRAW allows RAW "in modes that don't have a traditional Bayer RAW format available, such as modes that rely on fusing multiple captures"; must be set before `startRunning()` (else lengthy reconfiguration). **[DOC]** — [isAppleProRAWEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isappleprorawenabled)
- `CIRAWFilter` can produce linear scene-referred output (set `baselineExposure`, `shadowBias`, `boostAmount`, `localToneMapAmount` to 0, disable gamut mapping). **[DOC/WWDC21]** — [WWDC21 10160](https://developer.apple.com/videos/play/wwdc2021/10160/); WWDC26 also has "Enhance RAW image processing with Core Image" (session 305) — [wwdc.ai summary](https://wwdc.ai/2026/305) (not read in detail)
- `maxBracketedCapturePhotoCount`: max per bracket "depends on the size and format of images"; 0 if unsupported; changes with preset/format. Search results cite 4 as the typical max. **[DOC]** — [maxBracketedCapturePhotoCount](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxbracketedcapturephotocount); value 4 per a search-result snippet only (not verified; source likely [Medium: Notes About the iOS Camera API](https://medium.com/@karti/notes-about-the-ios-camera-api-e0183a6f9937) / [WWDC16 511](https://developer.apple.com/videos/play/wwdc2016/511/)) — measure on device
- `AVCapturePhotoBracketSettings` + `AVCaptureManualExposureBracketedStillImageSettings` (per-frame duration/ISO), works with RAW pixel format; no flash, no auto stabilization, no Live Photos; has `isLensStabilizationEnabled`. **[DOC]** — [AVCapturePhotoBracketSettings](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings)
- WWDC26 "Implement high resolution photo capture": 12/24/48 MP options (24 MP = fused; 48 MP = single frame full-res); **48 MP only at `.balanced`/`.quality`**, 18/24 MP only at `.quality`; only `.photo` preset supports 24/48 MP; set `maxPhotoDimensions` from `activeFormat.supportedMaxPhotoDimensions`; shot-to-shot delay until previous photo finishes processing; responsive capture (`captureReadiness`, overlapping captures), deferred processing (`didFinishCapturingDeferredPhotoProxy`), `setPreparedPhotoSettingsArray` for preallocation, `photoProcessingTimeRange`. Ultra Wide 48 MP on iPhone 17, Tele 48 MP on iPhone 16 Pro. **[DOC/WWDC26]** — [WWDC26 session 304](https://developer.apple.com/videos/play/wwdc2026/304/)
- `isResponsiveCaptureEnabled`, `isFastCapturePrioritizationEnabled` (iOS 17+), `isAutoDeferredPhotoDeliveryEnabled` (iOS 17+, set before `startRunning`). **[DOC]** — [isResponsiveCaptureEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isresponsivecaptureenabled), [isFastCapturePrioritizationEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isfastcaptureprioritizationenabled), [isAutoDeferredPhotoDeliveryEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isautodeferredphotodeliveryenabled)
- Developer report: with `maxPhotoDimensions = 8064×6048` ProRAW always comes back 48 MP; omitted → always 12 MP; no API to let iOS pick binning automatically (unanswered, Jan 2026). **[DEV-FORUM]** — [Apple Dev Forums 811832](https://developer.apple.com/forums/thread/811832)
- WWDC21 "Capture high-quality photos using video formats": `photoQualityPrioritization` `.speed` = WYSIWYG, light NR; `.balanced`/`.quality` apply fusion; `isHighPhotoQualitySupported` marks video formats (720p/1080p/1440p/4K@30) with improved stills; default `.balanced`. **[DOC/WWDC21]** — [WWDC21 10247](https://developer.apple.com/videos/play/wwdc2021/10247/)
- `activeVideoMaxFrameDuration` = reciprocal of min frame rate; must be within the format's `videoSupportedFrameRateRanges` (else exception); reset by preset change. **[DOC]** — [activeVideoMaxFrameDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideomaxframeduration)
- Camera intrinsics per video frame: `AVCaptureConnection.isCameraIntrinsicMatrixDeliveryEnabled` (set before `startRunning`) makes `AVCaptureVideoDataOutput` attach `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` to each sample buffer. **[DOC]** — [isCameraIntrinsicMatrixDeliveryEnabled](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled)
- iPhone 17 Pro/Pro Max: "first smartphones to support ProRes RAW, Log 2, and genlock … ProRes RAW is supported by Final Cut Camera and Blackmagic Camera, with APIs available to developers"; three 48 MP cameras; tele sensor 56% larger; vapor chamber. **[DOC/Apple newsroom]** — [Apple Newsroom: iPhone 17 Pro](https://www.apple.com/newsroom/2025/09/apple-unveils-iphone-17-pro-and-iphone-17-pro-max/)
- `AVVideoCodecType.proResRAW` exists from iOS 26.0. **[DOC]** — [AVVideoCodecType.proResRAW](https://developer.apple.com/documentation/avfoundation/avvideocodectype/proresraw)
- Xcode 26.1 API diff notes: with ProRes RAW and `AVCaptureVideoDataOutput`, set `videoRotationAngle` to 0 (no rotation for RAW buffers); for ProRes RAW, stabilization metadata is attached to *unstabilized* buffers. **[DEV/API-diff]** — [dotnet/macios wiki AVFoundation iOS xcode26.1 b1](https://github.com/dotnet/macios/wiki/AVFoundation-iOS-xcode26.1-b1); developers report problems writing ProRes RAW via `AVAssetWriter` — [Apple Dev Forums 807734](https://developer.apple.com/forums/thread/807734)
- A Bayer pixel format constant (`kCVPixelFormatType_96VersatileBayerPacked12`) exists in CoreVideo. **[DOC]** — [kCVPixelFormatType_96VersatileBayerPacked12](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_96versatilebayerpacked12)
- Spectre (Lux) "takes hundreds of frames during the exposure time and merges them" — i.e. video-rate frame merging, handheld up to 9 s. **[PRESS]** — [DPReview](https://www.dpreview.com/news/5372004032/halide-s-spectre-is-an-ai-powered-long-exposure-app-for-the-iphone)

### Inferences
- For astro (where each sub-frame should be as long as possible, ~1 s, at fixed ISO), the **Bayer RAW photo loop** (`.speed`, `isLensStabilizationEnabled=false`, single capture per request, or manual-exposure brackets of up to `maxBracketedCapturePhotoCount`) gives the cleanest linear data; budget ~12 MP × 2 B ≈ 24 MB/frame RAW (48 MP ≈ 96 MB) — hundreds of frames must be accumulated on the fly, not kept.
- The **video data output** path is attractive for continuous capture and gives per-frame intrinsics, but frames are ISP-processed (temporal NR, tone mapping) which harms linear stacking; whether frame durations up to 1 s are allowed depends on `videoSupportedFrameRateRanges` (min frame rate) per format — must be checked on device.
- ProRes RAW via `AVCaptureVideoDataOutput` (iPhone 17 Pro+, iOS 26+) could become the best "continuous raw" source, but long frame durations (≥1/2 s) in ProRes RAW formats are unverified.
- Avoid 48 MP/ProRAW for sub-frames: 48 MP requires `.balanced`/`.quality` (which may override manual exposure per the `setExposureModeCustom` doc) and ProRAW is fused.

### Gaps
- Real measured shot-to-shot interval for consecutive 1 s Bayer RAW captures on iPhone 15–18 (overhead/gaps) — no source found.
- Whether Bayer RAW can be captured at 48 MP (quad-Bayer full-res) with `.speed` on 2024–2026 devices — not verified.
- Minimum frame rate (max frame duration) of video/ProRes RAW formats on iPhone 17/18 — not found.

---

## 3. Focus to infinity, stabilization, distortion correction, lens choice, calibration data

### Takeaway
`lensPosition` is a unitless 0–1 value and Apple explicitly documents that **1.0 is not infinity**; infinity must be found per device/lens (and may drift with temperature) — e.g. via a star-FWHM autofocus sweep at session start. Disable OIS/lens stabilization and geometric distortion correction (also required for calibration-data delivery), and use per-frame intrinsics/AVCameraCalibrationData for the star-motion warp model.

### Cited Findings
- "A lens position value doesn't correspond to an exact physical distance, nor does it represent a consistent focus distance from device to device. The range … 0.0 to 1.0 … Note that 1.0 doesn't represent focus at infinity. The default value is 1.0." **[DOC]** — [lensPosition](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensposition)
- `setFocusModeLocked(lensPosition:)` is the only way to set `lensPosition`; check `isLockingFocusWithCustomLensPositionSupported` first (else exception). **[DOC]** — [setFocusModeLocked](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setfocusmodelocked(lensposition:completionhandler:)), [isLockingFocusWithCustomLensPositionSupported](https://developer.apple.com/documentation/avfoundation/avcapturedevice/islockingfocuswithcustomlenspositionsupported)
- Measured (iPhone 13 "Max"): 1.0 gave blurry images; best infinity ≈ **0.808** (wide & tele), **≈0.84** (ultra-wide); "optimal lensPosition changes over time", suspected temperature dependence. **[DEV-FORUM, unanswered]** — [Apple Dev Forums 706755](https://developer.apple.com/forums/thread/706755)
- NightCap users: best infinity focus "usually found somewhere near 82" on NightCap's 0–100 scale. **[USER-FORUM]** — [Cloudy Nights (search snippet)](https://www.cloudynights.com/forums/topic/892249-achieving-best-focus-with-iphone-13/)
- `minimumFocusDistance` (mm, iOS 15+) is available per device. **[DOC]** — [minimumFocusDistance](https://developer.apple.com/documentation/avfoundation/avcapturedevice/minimumfocusdistance)
- Bracketed and photo settings expose `isLensStabilizationEnabled` (OIS during capture). **[DOC]** — [AVCapturePhotoBracketSettings](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings)
- Video stabilization modes: `off, standard, cinematic, cinematicExtended, previewOptimized, cinematicExtendedEnhanced, auto, lowLatency`; `preferredVideoStabilizationMode` defaults to `.off`, adds latency/memory when enabled. **[DOC]** — [AVCaptureVideoStabilizationMode](https://developer.apple.com/documentation/avfoundation/avcapturevideostabilizationmode), [preferredVideoStabilizationMode](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/preferredvideostabilizationmode)
- `isGeometricDistortionCorrectionEnabled` defaults to true where supported. **[DOC]** — [isGeometricDistortionCorrectionEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isgeometricdistortioncorrectionenabled)
- `isCameraCalibrationDataDeliverySupported` is true only when `isVirtualDeviceConstituentPhotoDeliveryEnabled == true`, `isContentAwareDistortionCorrectionEnabled == false`, and device `isGeometricDistortionCorrectionEnabled == false`. **[DOC]** — [isCameraCalibrationDataDeliverySupported](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/iscameracalibrationdatadeliverysupported)
- `AVCameraCalibrationData` provides `intrinsicMatrix`, `intrinsicMatrixReferenceDimensions`, `extrinsicMatrix`, `pixelSize`, `lensDistortionLookupTable`, `inverseLensDistortionLookupTable`, `lensDistortionCenter`. **[DOC]** — [AVCameraCalibrationData](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata)
- ProRAW/Bayer RAW: no content-aware distortion correction applied. **[DOC/WWDC21]** — [WWDC21 10160](https://developer.apple.com/videos/play/wwdc2021/10160/)
- `activeColorSpace` (sRGB / P3 / etc.) should be chosen before `startRunning`; changing while running is disruptive. **[DOC]** — [activeColorSpace](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activecolorspace)
- Night mode lens support historically: ultra-wide not supported on iPhone 11/11 Pro. **[PRESS]** — [MacRumors](https://www.macrumors.com/guide/night-mode/)
- iPhone 17 Pro: all three rear cameras 48 MP; tele 4×/100 mm and 8×/200 mm crop. **[DOC]** — [Apple Newsroom iPhone 17 Pro](https://www.apple.com/newsroom/2025/09/apple-unveils-iphone-17-pro-and-iphone-17-pro-max/)

### Inferences
- Implement a **star-based autofocus**: sweep `lensPosition` around a per-lens prior (~0.8) on a bright star, minimize FWHM/HFR, and periodically re-check (thermal drift). Store per-device-model priors.
- Use the **Main (wide) camera** by default (largest sensor, widest aperture; ƒ/1.48 on 18 Pro); ultra-wide for Milky Way framing; avoid the virtual multi-camera device (use a specific physical `builtInWideAngleCamera`) to prevent lens switching.
- Disable: `isLensStabilizationEnabled`, video stabilization (`.off`), `isGeometricDistortionCorrectionEnabled` (so star-motion model + calibration LUTs are consistent), auto low-light boost, auto white balance (lock WB gains).

### Gaps
- Direct API to turn OIS fully off/"locked centered" for video data output on tripod (beyond `.off` stabilization mode) — not documented; whether OIS still floats on a tripod was not verified.
- Whether `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` reflects focus-dependent focal length changes (focus breathing) — not documented.

---

## 4. CoreMotion / CoreLocation: true-north attitude, latitude, tripod stillness

### Takeaway
`CMAttitudeReferenceFrame.xTrueNorthZVertical` gives camera orientation relative to true north (needs magnetometer + Location Services), which with GPS latitude/longitude and time is enough to predict apparent star motion (rotation about the celestial pole) — but magnetometer heading accuracy (degrees) is far coarser than pixel-level alignment, so image-based registration must refine it. Bias-corrected `CMDeviceMotion.rotationRate` is the right stillness signal.

### Cited Findings
- `.xTrueNorthZVertical`: Z vertical, X toward geographic north; "The device must have a magnetometer … Location services must also be available to calculate the difference between magnetic and true north. If the magnetometer isn't currently calibrated, Core Motion prompts the person to move the device to calibrate it." **[DOC]** — [xTrueNorthZVertical](https://developer.apple.com/documentation/coremotion/cmattitudereferenceframe/xtruenorthzvertical)
- `startDeviceMotionUpdates(using:to:withHandler:)` — specify reference frame; must call `stopDeviceMotionUpdates()`. **[DOC]** — [startDeviceMotionUpdates](https://developer.apple.com/documentation/coremotion/cmmotionmanager/startdevicemotionupdates(using:to:withhandler:))
- `CMDeviceMotion.rotationRate` is gyroscope data "whose bias has been removed by Core Motion algorithms" (vs raw `CMGyroData`). **[DOC]** — [rotationRate](https://developer.apple.com/documentation/coremotion/cmdevicemotion/rotationrate)
- `CLHeading.headingAccuracy` = maximum deviation in degrees; negative = invalid (uncalibrated or magnetic interference). **[DOC]** — [headingAccuracy](https://developer.apple.com/documentation/corelocation/clheading/headingaccuracy)
- Apple's Night mode uses gyroscope to detect tripod and then offers longer (up to 30 s) times. **[PRESS]** — [MacRumors Night mode guide](https://www.macrumors.com/guide/night-mode/)

### Inferences
- Use attitude (true north) + latitude (CLLocation) + timestamps only as a **prior** for the rotation centre (celestial pole position in the frame) and rotation rate (15.04°/h sidereal); refine per-frame with star-centroid matching. Metal tripods / mounts near the phone may disturb the magnetometer (headingAccuracy will show this).
- Tripod detection: threshold on |rotationRate| (e.g. < ~0.01 rad/s, tune empirically) over a window; also pause/flag frames when motion spikes (touches, wind).

### Gaps
- Typical real-world `headingAccuracy` values on iPhone and attitude drift over 30–60 min were not found.
- Apple's exact tripod-detection thresholds are not public.

---

## 5. Processing: Metal / Accelerate / Core Image, memory, background, thermal, battery, screen

### Takeaway
Do warp+accumulate on the GPU (Metal compute, float32 accumulators) as frames arrive, keeping only running sums; respect per-app memory limits (`os_proc_available_memory`, optional `increased-memory-limit` entitlement) and `MTLDevice.recommendedMaxWorkingSetSize`. Capture must happen in the foreground (keep screen on via `isIdleTimerDisabled`); iOS 26's `BGContinuedProcessingTask` can let post-capture processing continue in the background with a Live Activity progress UI. Monitor `ProcessInfo.thermalState` and throttle.

### Cited Findings
- vImage: geometric transforms (Lanczos-3 default, `kvImageHighQualityResampling` → Lanczos-5), not in-place; suited for large images/scientific accuracy on CPU vector units. **[DOC]** — [Applying geometric transforms to images](https://developer.apple.com/documentation/accelerate/applying-geometric-transforms-to-images), [vImage](https://developer.apple.com/documentation/accelerate/vimage-library)
- vImage sample "Finding the sharpest image in a sequence of captured images" (useful for frame rejection). **[DOC]** — [vImage topics](https://developer.apple.com/documentation/accelerate/vimage-library)
- vDSP Fourier transforms: prefer DFT API; `FFT`, `FFT2D` Swift objects; sample "Halftone descreening with 2D FFT" (template for deconvolution/frequency filtering). **[DOC]** — [Fast Fourier transforms](https://developer.apple.com/documentation/accelerate/fast-fourier-transforms)
- Core Image `CIPerspectiveTransform` filter available. **[DOC]** — [CIPerspectiveTransform](https://developer.apple.com/documentation/coreimage/ciperspectivetransform)
- `MTLDevice.recommendedMaxWorkingSetSize` (iOS 16+): keep GPU resource footprint below it. **[DOC]** — [recommendedMaxWorkingSetSize](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize)
- `os_proc_available_memory()` returns bytes until the app's limit; limits change over lifecycle. `com.apple.developer.kernel.increased-memory-limit` (iOS 15+) raises limit on some models only. **[DOC]** — [os_proc_available_memory](https://developer.apple.com/documentation/os/os_proc_available_memory), [increased-memory-limit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
- `BGContinuedProcessingTask` (iOS 26.0+): starts in foreground and may continue in background; progress shown in a Live Activity, user-cancellable; system may terminate under resource constraints, prioritising tasks with little progress; must report progress. **[DOC]** — [BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- `ProcessInfo.thermalState`: `.serious` → reduce CPU/GPU, defer work; `.critical` → minimal resource use, "If possible, stop using peripherals such as the camera". **[DOC]** — [serious](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/serious), [critical](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/critical)
- `UIApplication.isIdleTimerDisabled = true` prevents dimming/sleep; reset when no longer needed. **[DOC]** — [isIdleTimerDisabled](https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled)
- iPhone 18 Pro A20 Pro: next-gen vapor chamber, "up to a 40 percent gain over the previous generation" sustained performance; iPhone 17 Pro introduced a vapor chamber. **[DOC/Apple newsroom]** — [iPhone 18 Pro](https://www.apple.com/newsroom/2026/09/apple-debuts-iphone-18-pro-and-iphone-18-pro-max/), [iPhone 17 Pro](https://www.apple.com/newsroom/2025/09/apple-unveils-iphone-17-pro-and-iphone-17-pro-max/)

### Inferences
- Memory budget: a 12 MP RGBA float32 accumulator = 12e6×16 B ≈ 192 MB (float16 ≈ 96 MB); 48 MP float32 RGBA ≈ 768 MB — too large for many devices; prefer accumulating raw Bayer/mono planes at 12 MP in float32 (≈48 MB/plane) plus a weight/count plane, and dark/flat frames. Use `MTLStorageMode.shared` buffers wrapping `CVPixelBuffer`s (IOSurface) to avoid copies.
- Accumulate in float32 (float16 loses precision after ~hundreds of additions of small values); use sigma-clipping only with a two-pass or running-statistics (Welford) approach since you cannot keep all frames.
- Camera capture cannot run in background; long sessions need the app in foreground with screen on → implement a dimmed **red-on-black** UI (and reduce brightness) to save power and preserve night vision; consider `BGContinuedProcessingTask` only for final post-processing/export.

### Gaps
- No Apple-documented numeric per-app memory limits per device; must be probed with `os_proc_available_memory`.
- No published battery-drain figures for continuous 1 s camera capture over 30–60 min.
- Programmatic screen brightness (`UIScreen.brightness`) was not re-verified for iOS 26/27.

---

## 6. Existing apps: Apple Night mode, NightCap, Spectre, Halide, ProCamera — how they do long exposure / astro

### Takeaway
All third-party "long exposure" apps synthesize long exposures by **combining many short (≤1 s) frames** — NightCap (Stars mode = 10 s total, ISO Boost "4×", star trails by real-time frame combination, meteor mode = photo every 5 s), Spectre (hundreds of frames, AI stabilization, ≤9 s handheld), Halide (stops at 1 s, no Night mode). Apple's Night mode (up to 30 s on tripod) is a private, multi-frame pipeline unavailable to third parties.

### Cited Findings
- NightCap Stars mode: "10 second exposure", 3 s self-timer; Star Trails ≥15 min (example 90 min) with on-screen trail build-up; Meteor mode: "photo every 5 seconds", auto-scan for meteors, "typically between 30 and 150 per hour". **[VENDOR]** — [NightCap: Photograph Stars, Meteors…](https://www.nightcapcamera.com/photograph-stars-meteors-satellites-even-nebulas-iphone-nightcap-camera/)
- NightCap: "ISO Boost for up to 4x beyond the standard camera range", handheld long exposure that "steadies and aligns every frame"; light-trails mode "combines lots of photos in realtime"; modes Stars, Star Trails, Meteors, ISS, Aurora; requires iOS 18.6+; saves TIFF (per user reviews); manual aperture on iPhone 18 Pro (v10.1). **[VENDOR]** — [NightCap App Store](https://apps.apple.com/us/app/nightcap-camera/id754105884), [NightCap AU App Store](https://apps.apple.com/au/app/nightcap-camera/id754105884)
- Spectre (Lux Optics, 2019): computational shutter; "takes hundreds of frames during the exposure time and merges them"; ML scene detection; AI stabilization enables handheld exposures up to 9 s; outputs Live Photo (still + video). **[PRESS]** — [DPReview](https://www.dpreview.com/news/5372004032/halide-s-spectre-is-an-ai-powered-long-exposure-app-for-the-iphone), [9to5Mac](https://9to5mac.com/2019/02/28/spectre-long-exposure-camera-app/), [spectre.cam](https://spectre.cam/)
- Halide: manual shutter up to 1 s (hardware limit), no software long-exposure stacking prioritized; Process Zero = single RAW frame, minimal processing, "does not work with Night mode … because of iOS limitations". **[VENDOR/PRESS]** — [Halide support (snippet)](https://luxoptics.zendesk.com/hc/en-us/articles/360000998412-Why-is-the-maximum-shutter-speed-limited-to-one-second), [Lux: Process Zero](https://www.lux.camera/introducing-process-zero-for-iphone/), [DPReview Process Zero](https://www.dpreview.com/news/5101705770/halide-process-zero-ai-computational-photograpy-phones-raw/)
- ProCamera offers RAW exposure bracketing (multi-RAW captures). **[VENDOR]** — [ProCamera blog: RAW Exposure Bracketing](https://procamera-app.com/en/blog/raw-exposure-bracketing-in-procamera/)
- Apple Night mode: iPhone 11+; tripod → up to 30 s; Night mode Time-lapse on tripod; with iOS 14+ motion crosshair alignment guidance. **[DOC]** — [Apple Support 102519](https://support.apple.com/en-us/102519); **[PRESS]** — [MacRumors](https://www.macrumors.com/guide/night-mode/); Milky Way examples on iPhone 14 Pro — [MacRumors 2022](https://www.macrumors.com/2022/09/27/astrophotography-examples-on-iphone-14-pro/)
- Third-party stacking of 30× 1 s RAW reported as "far inferior" to Apple's 30 s Night mode by one developer; Apple: no supported way to replicate. **[DEV-FORUM + DTS]** — [Apple Dev Forums 769970](https://developer.apple.com/forums/thread/769970)
- Academic reference for computational long exposure on phones (Google, 2023). **[PAPER]** — [arXiv 2308.01379](https://arxiv.org/pdf/2308.01379)

### Inferences
- AstralCamera's differentiators vs NightCap/Spectre: (1) true **linear RAW** sub-frames (NightCap appears to output TIFF from processed frames; Spectre outputs Live Photos), (2) explicit **sidereal-rotation-aware** registration (field rotation around celestial pole, using CoreMotion/GPS priors + star matching) enabling minutes-long integrations without trails, (3) dark-frame subtraction and sigma-clip rejection (satellites/planes), (4) DNG/linear TIFF output.
- To approach Apple Night mode quality, invest in denoising (temporal + spatial) and hot-pixel/dark-frame handling, since Apple's advantage is the tuned fusion pipeline.

### Gaps
- No public technical write-up from NightCap on its frame duration, ISO Boost implementation (likely sum of frames → digital gain), or alignment algorithm; Cloudy Nights threads with developer comments were inaccessible (403).
- No public Apple technical paper/WWDC session describing Night mode's astrophotography fusion; Apple Support page does not mention astrophotography.
- Halide/Lux has not (as far as found) shipped an astro stacking mode; Lumina-type apps not researched (no sources found in budget).

---

### Note on OS versions (Oct 2026)
- WWDC26 (June 2026) sessions exist (e.g. 304 "Implement high resolution photo capture", 305 "Enhance RAW image processing with Core Image") — [WWDC26 304](https://developer.apple.com/videos/play/wwdc2026/304/), [wwdcnotes](https://wwdcnotes.com/documentation/wwdc26-304-implement-high-resolution-photo-capture/). A third-party summary of 304 attributed fast capture prioritization to "iOS 27+", but Apple docs show `isFastCapturePrioritizationEnabled` since iOS 17 — treat the summary's version claims as unreliable. The current release naming (iOS 27 shipping with iPhone 18) was not directly verified here.
