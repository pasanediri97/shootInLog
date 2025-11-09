ShootInLogApp — SwiftUI Log Video Recorder with LUTs

Overview
- Single‑purpose iOS app for recording Apple Log video with real‑time LUT preview and baked output. Built with Swift + SwiftUI, AVFoundation, and Metal.
- Targets iPhone 15/15 Pro/15 Pro Max through iPhone 17/17 Pro/17 Pro Max (and newer, where available).

Attribution
- This project is based on and informed by Apple’s open‑source AVCam sample from the iOS SDK sample code. Portions of the capture pipeline design, session configuration patterns, and camera switching behavior follow AVCam’s architecture.
- Original sample: AVCam (Apple Inc.). Use is under Apple’s sample code license; attribution retained here.

Tech Stack
- Swift 5+, SwiftUI for UI
- AVFoundation for capture (AVCaptureSession/Device/Outputs)
- Metal + custom compute shader for 3D LUT application
- AVAssetWriter for recording, Photos framework for library save

Capture Pipeline
- AVCaptureSession → AVCaptureDeviceInput → AVCaptureVideoDataOutput → Metal LUT Processing → AVAssetWriter → Photos Library

Features
- Launches directly into video mode; no photo UI
- Log capability detection on boot (AVFoundation checks + model fallback)
- Real‑time LUT switching: Off, Subject, Scenery
- 4K recording default (3840×2160) with graceful fallback and live resolution label
- Front/back camera toggle
- Back camera zoom steps: 0.5×, 1×, 2×, 4×, 8× mapped to available zoom factors with smooth ramp
- Auto‑save to Photos with permissions flow
- Minimal SwiftUI UI with large controls + info modal

Structure
- ShootInLogApp/
  - Model/
    - LUTMode.swift
  - Camera/
    - CaptureManager.swift (session config, camera controls, video/audio outputs)
    - LogCapability.swift (Log/HDR detection + model fallback)
  - Rendering/
    - LUT3D.swift (parse .cube into 3D MTLTexture)
    - LUTRenderer.swift (Metal compute + preview blit)
    - Shaders/LUTKernel.metal (compute kernel + simple textured render pipeline)
  - Recording/
    - VideoRecorder.swift (AVAssetWriter + Photos save)
  - UI/
    - CameraView.swift (preview + controls)
    - CameraViewModel.swift (orchestration of capture → render → record)

LUT Integration
- Place your LUT files as `Subject.cube` and `Scenery.cube` in the app bundle. For Xcode:
  1) Create a folder `LUTs` (or use `Rendering/Shaders` siblings) and add `Subject.cube` and `Scenery.cube`.
  2) In Xcode, ensure both files are in the app target’s “Copy Bundle Resources”.
  3) The app loads them by name; no code changes are required.
- Format: Standard .cube with `LUT_3D_SIZE` (e.g., 33, 64). Values expected in 0–1 range.

Compatibility Detection
- Primary: `AVCaptureDevice.activeFormat.isVideoHDRSupported` and `supportedColorSpaces` includes `.P3_D65` or `.HLG_BT2020`.
- Secondary: Device identifier prefix check (`hw.machine`) to allow iPhone 15/16/17 families (prefixes `iPhone16,` `iPhone17,` `iPhone18,`).
- Incompatible devices display a message and disable recording.

Adding New Presets
- To prefer a specific resolution/frame rate, update `selectBestFormatAndFrameRate` in `CaptureManager` to match your target dimensions and FPS. The current logic prefers 3840×2160@30 and falls back to the highest available.

Build & Run
- Requirements: Xcode 16+, iOS 17+ deployment, a physical iPhone (simulator lacks camera hardware)
- Open `ShootInLogApp.xcodeproj` and build the `ShootInLogApp` target on a device.
- Permissions:
  - Camera (NSCameraUsageDescription)
  - Microphone (NSMicrophoneUsageDescription)
  - Photos Add (NSPhotoLibraryAddUsageDescription)
- The project sets these with `INFOPLIST_KEY_…` build settings so no Info.plist edits are needed.

Usage
- The app opens directly to the camera preview.
- Pick LUT (Off/Subject/Scenery). Switchable during preview and while recording.
- Use zoom step buttons for quick lens/zoom changes with smooth ramps.
- Tap the center button to start/stop recording. Result is saved to Photos.
- Tap the “i” button for quick instructions and a YouTube tutorial link.

Simulator Limitations
- The iOS Simulator does not emulate camera hardware or HDR/Log capture. Test on-device.

Known Models
- Tested/expected compatible: iPhone 15 Pro / 15 Pro Max and newer Pro models. The whitelist also allows 16/17 families. Non‑Pro models may not support Apple Log.

Notes on Color/Log
- When LUT mode is “Off”, the app records the processed frames without LUT applied. The writer requests BT.2020 primaries; actual Log transfer function availability varies by device/codec. For Apple Log–specific workflows (ProRes/Apple Log), further customization may be required.

License
- App code © 2025. Portions inspired by Apple’s AVCam sample (Apple Inc.) under its sample code license. This repository retains attribution to AVCam in accordance with that license.

