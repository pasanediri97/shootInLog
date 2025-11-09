import AVFoundation
import Foundation

/// Detects whether the current device + active format can shoot Apple Log-like HDR video.
/// Primary: query AVFoundation for HDR/wide color support.
/// Secondary: whitelist by model identifier.
enum LogCapability {
    static func isDeviceLogCapable(activeDevice: AVCaptureDevice?) -> Bool {
        guard let device = activeDevice ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return false
        }

        // Primary: format capabilities
        let format = device.activeFormat
        var hdrOK = false
        if #available(iOS 17.0, *) {
            hdrOK = format.isVideoHDRSupported
        } else {
            hdrOK = format.isVideoHDRSupported
        }
        let colorSpaces = format.supportedColorSpaces
        let wideColorOK = colorSpaces.contains(.P3_D65) || colorSpaces.contains(.HLG_BT2020)

        if hdrOK && wideColorOK { return true }

        // Secondary: model identifier whitelist (best-effort)
        let model = platformIdentifier()
        if model.hasPrefix("iPhone16,") || model.hasPrefix("iPhone17,") || model.hasPrefix("iPhone18,") {
            // iPhone 15/16/17 families and beyond
            return true
        }
        // 15 non-pro still likely lacks Apple Log; leave as false by default
        return false
    }

    static func platformIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machineMirror = Mirror(reflecting: sysinfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
}

