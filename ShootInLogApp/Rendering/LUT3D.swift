import Foundation
import Metal

/// Loads .cube 3D LUT files into a Metal 3D texture.
final class LUT3DLoader {
    enum LUTError: Error { case invalidFile, unsupportedSize, dataMismatch }

    /// Load a .cube LUT from bundle by name (without extension) into a 3D texture.
    static func loadCubeTexture(device: MTLDevice, resourceName: String) throws -> (MTLTexture, Int) {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "cube") else {
            throw LUTError.invalidFile
        }
        let text = try String(contentsOf: url)
        return try parseCube(device: device, text: text)
    }

    /// Parse cube text and create MTLTexture3D
    static func parseCube(device: MTLDevice, text: String) throws -> (MTLTexture, Int) {
        var size: Int = 0
        var values: [Float] = []
        values.reserveCapacity(64*64*64*3)

        let lines = text.split(whereSeparator: { $0.isNewline })
        for raw in lines {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.uppercased().hasPrefix("TITLE") { continue }
            if line.uppercased().hasPrefix("DOMAIN_MIN") { continue }
            if line.uppercased().hasPrefix("DOMAIN_MAX") { continue }
            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                let comps = line.split(separator: " ")
                if let last = comps.last, let s = Int(last) { size = s }
                continue
            }
            // Data line: r g b
            let comps = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if comps.count >= 3,
               let r = Float(comps[0]), let g = Float(comps[1]), let b = Float(comps[2]) {
                values.append(contentsOf: [r, g, b])
            }
        }

        guard size > 1 else { throw LUTError.unsupportedSize }
        guard values.count == size * size * size * 3 else { throw LUTError.dataMismatch }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { throw LUTError.invalidFile }

        // Prepare RGBA16F data
        var lutRGBA = [UInt16](repeating: 0, count: size*size*size*4)
        let maxIndex = size*size*size
        for i in 0..<maxIndex {
            let r = values[i*3 + 0]
            let g = values[i*3 + 1]
            let b = values[i*3 + 2]
            lutRGBA[i*4 + 0] = floatToHalf(r)
            lutRGBA[i*4 + 1] = floatToHalf(g)
            lutRGBA[i*4 + 2] = floatToHalf(b)
            lutRGBA[i*4 + 3] = floatToHalf(1.0)
        }

        lutRGBA.withUnsafeBytes { buf in
            let bytesPerRow = size * 4 * MemoryLayout<UInt16>.size
            let bytesPerImage = bytesPerRow * size
            let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: size, height: size, depth: size))
            texture.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: buf.baseAddress!, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
        }

        return (texture, size)
    }

    /// Convert 32-bit float [0,1] to 16-bit half-float bits
    private static func floatToHalf(_ x: Float) -> UInt16 {
        // Use simd support if desired; manual conversion for portability
        var f = x
        let bitPattern = f.bitPattern
        let sign = UInt16((bitPattern >> 16) & 0x8000)
        var exp = Int((bitPattern >> 23) & 0xFF) - 127 + 15
        var mant = UInt32(bitPattern & 0x7FFFFF)
        if exp <= 0 {
            // Subnormal
            if exp < -10 { return sign }
            mant |= 0x800000
            let shift = UInt32(14 - exp)
            let halfMant = UInt16(mant >> (shift))
            return sign | halfMant
        } else if exp >= 31 {
            // Inf/NaN
            return sign | 0x7C00
        } else {
            let halfExp = UInt16(exp) << 10
            let halfMant = UInt16(mant >> 13)
            return sign | halfExp | halfMant
        }
    }
}

