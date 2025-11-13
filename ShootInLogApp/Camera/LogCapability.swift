import AVFoundation
import Foundation

/// Detects whether the current device can shoot Apple Log video.
/// Apple Log requires:
/// - iPhone 15 Pro or newer Pro models
/// - iOS 17.0 or later
/// - HDR video support
/// - HLG_BT2020 color space support
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
        
        // Must support HDR video
        guard format.isVideoHDRSupported else {
            return false
        }
        
        // Must support HLG_BT2020 color space (required for Apple Log)
        let colorSpaces = format.supportedColorSpaces
        guard colorSpaces.contains(.HLG_BT2020) else {
            return false
        }

        // Additionally verify with device model (iPhone 15 Pro and newer)
        let model = platformIdentifier()
        
        // iPhone 15 Pro: iPhone16,1 (15 Pro), iPhone16,2 (15 Pro Max)
        // iPhone 16 Pro: iPhone17,1 (16 Pro), iPhone17,2 (16 Pro Max)
        // Future models: iPhone18,x and beyond
        let isProModel = model.hasPrefix("iPhone16,1") || // 15 Pro
                        model.hasPrefix("iPhone16,2") || // 15 Pro Max
                        model.hasPrefix("iPhone17,") ||  // 16 Pro family
                        model.hasPrefix("iPhone18,")     // Future Pro models
        
        return isProModel
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

