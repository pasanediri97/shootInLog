QA Report — ShootInLogApp

Tested Builds
- Xcode 16.x, iOS 17–18 (device only)

Devices Tested
- [Pending user validation] Target range: iPhone 15/15 Pro/15 Pro Max through iPhone 17/17 Pro/17 Pro Max

Scenarios
- App launch: opens directly to camera preview
- Capability detection: non‑Log devices show message and disable record
- LUT switching: Off/Subject/Scenery switch during preview and while recording
- Recording: default 4K; if 4K unavailable, falls back to highest, label displays actual resolution
- Save to Photos: permission requested, saved clip appears in Recents
- Camera switching: front/back toggles properly
- Zoom steps: 0.5×, 1×, 2×, 4×, 8× mapped smoothly using rampToVideoZoomFactor

Known Limitations
- Simulator not supported for camera/LUT/HDR testing
- Apple Log encoding support is device/codec dependent; current writer uses HEVC with BT.2020 color properties. For strict Apple Log ProRes workflows, additional device/codec configuration may be required.
- If LUT .cube files are missing from the bundle, LUT buttons still appear; Subject/Scenery apply only when files are present.

Issues Observed
- None recorded yet — pending physical device QA.

Recommendations
- Test on iPhone 15 Pro/Pro Max and latest Pro devices for performance at 4K.
- Verify thermal behavior during extended recording.
- Validate LUT colorimetry against reference footage.

