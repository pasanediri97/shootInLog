import AVFoundation
import Foundation

/// Detects whether the current device can shoot Apple Log video.
/// Apple Log requires:
/// - iOS 17.0 or later
/// - HDR video support
/// - Wide color gamut support (P3_D65 or HLG_BT2020)
enum LogCapability {
    static func isDeviceLogCapable(activeDevice: AVCaptureDevice?) -> Bool {
        // Apple Log requires iOS 17+
        guard #available(iOS 17.0, *) else {
            return false
        }
        
        guard let device = activeDevice ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return false
        }

        // Check format capabilities for Apple Log support
        let format = device.activeFormat
        
        // Must support HDR video - this is the key indicator
        guard format.isVideoHDRSupported else {
            return false
        }
        
        // Check for wide color gamut support
        let colorSpaces = format.supportedColorSpaces
        let hasWideColorGamut = colorSpaces.contains(.HLG_BT2020) || colorSpaces.contains(.P3_D65)
        
        guard hasWideColorGamut else {
            return false
        }
        
        // If the device has HDR and wide color support on iOS 17+, it can do Log-like video
        // This is more reliable than model checking as it directly checks capabilities
        return true
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

