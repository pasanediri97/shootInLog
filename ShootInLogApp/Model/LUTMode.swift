import Foundation

/// LUT selection modes for preview and recording
enum LUTMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case subject = "Subject"
    case scenery = "Scenery"

    var id: String { rawValue }
}

