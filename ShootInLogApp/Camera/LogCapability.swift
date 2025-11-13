import AVFoundation
import Foundation

/// Detects whether the current device can shoot Log-style video with wide dynamic range.
/// Uses a permissive approach - if the device has HDR enabled on iOS 17+, we enable Log mode
enum LogCapability {
    static func isDeviceLogCapable(activeDevice: AVCaptureDevice?) -> Bool {
        print("🔍 === CHECKING LOG CAPABILITY ===")
        
        // Require iOS 17+ for modern HDR/Log features
        guard #available(iOS 17.0, *) else {
            print("❌ iOS version < 17.0 - Log requires iOS 17+")
            return false
        }
        print("✅ iOS 17.0+ ✓")
        
        guard let device = activeDevice ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("❌ No camera device found")
            return false
        }
        print("✅ Camera device: \(device.localizedName)")

        let format = device.activeFormat
        let hdrSupported = format.isVideoHDRSupported
        print("📹 Format HDR Support: \(hdrSupported)")
        
        // Check if HDR is actually enabled (not just supported)
        let hdrEnabled = device.isVideoHDREnabled
        print("📹 HDR Actually Enabled: \(hdrEnabled)")
        
        // Simple check: If HDR is supported on the format, we can do Log-like recording
        // The CaptureManager will have already enabled HDR if supported
        if hdrSupported || hdrEnabled {
            print("✅ LOG CAPABLE - Reason: HDR is supported/enabled")
            print("🔍 ================================")
            return true
        }
        
        print("❌ NOT LOG CAPABLE - HDR not available")
        print("🔍 ================================")
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
