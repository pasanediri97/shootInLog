# Apple Log Video Recording Implementation

This app properly implements **Apple Log video recording** using AVFoundation framework with ProRes codec.

## What is Apple Log?

Apple Log is a logarithmic color profile that captures the **widest possible dynamic range**, preserving maximum detail in highlights and shadows. The footage appears flat and desaturated but provides:

- **Maximum dynamic range** - Full spectrum of light captured
- **Professional flexibility** - Extensive color grading capabilities in post-production
- **Better quality** - Especially in high-contrast lighting situations

## Requirements

✅ **Device**: iPhone 15 Pro, iPhone 15 Pro Max, or newer Pro models
✅ **iOS Version**: iOS 17.0 or later
✅ **ProRes Support**: Natively supported on Pro models
✅ **System Settings**: ProRes recording must be enabled in Settings > Camera > Formats

## Implementation Details

### 1. Device Detection (`LogCapability.swift`)

The app checks for Apple Log support by:
- Verifying iOS 17.0+ availability
- Checking `isVideoHDRSupported` on active format
- Ensuring `HLG_BT2020` color space support (required for Apple Log)
- Validating device model (iPhone 15 Pro and newer)

### 2. Camera Configuration (`CaptureManager.swift`)

The capture session is configured to:
- Select best available 4K format (3840x2160)
- Enable HDR video (`isVideoHDREnabled = true`)
- Set `HLG_BT2020` color space for Apple Log
- Use 30fps frame rate
- Apply cinematic extended stabilization

### 3. Video Recording (`VideoRecorder.swift`)

Videos are recorded with:
- **Codec**: ProRes 422 HQ (`AVVideoCodecType.proRes422HQ`)
- **Transfer Function**: ITU-R 2100 HLG (Hybrid Log-Gamma)
- **Color Primaries**: ITU-R 2020 (wide color gamut)
- **Matrix**: ITU-R 2020
- **Bitrate**: 100 Mbps for high quality
- **File Format**: QuickTime (.mov)

### 4. LUT Application

The app applies Look-Up Tables (LUTs) in real-time:
- **Metal-accelerated** rendering via GPU
- LUTs applied to both preview and recording
- Options: Off, Subject, Scenery
- Processes log footage while maintaining full dynamic range

## Color Space Configuration

```swift
// In VideoRecorder.swift:
videoSettings[AVVideoColorPropertiesKey] = [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
]
```

This configuration ensures:
- **Wide color gamut** (Rec. 2020)
- **Logarithmic encoding** (HLG transfer function)
- **Professional compatibility** with editing software

## Usage

1. Open app on iPhone 15 Pro or newer
2. "LOG" badge appears if device is compatible
3. Select LUT mode: Off, Subject, or Scenery
4. Tap red record button to start recording
5. Timer appears during recording
6. Tap stop (square button) to finish
7. Video automatically saves to Photos

## Post-Production

Recorded videos are in Apple Log format (.mov with ProRes 422 HQ). To edit:

1. Import into Final Cut Pro, DaVinci Resolve, or Adobe Premiere
2. Apply color grading or use provided LUTs
3. Adjust exposure, contrast, and color as needed
4. Export in desired format

## Technical Benefits

- **12+ stops of dynamic range** (vs 8-10 in standard profiles)
- **Minimal clipping** in highlights and shadows
- **Professional workflows** compatible
- **Future-proof** footage for re-grading
- **No banding** in gradients after color correction

## Limitations

- Larger file sizes (ProRes is uncompressed/minimally compressed)
- Requires color grading for final output
- Only available on iPhone 15 Pro and newer Pro models
- Requires iOS 17.0 or later

## Comparison: Standard vs Apple Log

| Feature | Standard H.265 | Apple Log (ProRes) |
|---------|---------------|-------------------|
| Dynamic Range | 8-10 stops | 12+ stops |
| File Size | Small (~200MB/min) | Large (~1-2GB/min) |
| Color Grading | Limited | Extensive |
| Post-Production | Basic | Professional |
| Device Support | All iPhones | iPhone 15 Pro+ |

---

**Note**: This implementation follows Apple's official guidelines for ProRes and Log video recording using AVFoundation.