import CoreGraphics
import Foundation
import ImageIO

/// Decoded RGBA pixels of an encoded image, for asserting on texture contents.
struct RGBA8Image {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(png: Data) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        pixels = buffer
    }

    /// One channel of the pixel at (x, y): 0 = red, 1 = green, 2 = blue.
    func channel(_ channel: Int, x: Int, y: Int) -> UInt8 {
        pixels[(y * width + x) * 4 + channel]
    }
}

/// Minimal independent GLB reader, so the tests parse the container by the spec
/// rather than through the code that produced it.
extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        precondition(offset + 4 <= count)
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    var jsonChunkLength: Int { Int(readUInt32(at: 12)) }

    func jsonChunk() -> [String: Any]? {
        let json = subdata(in: 20..<(20 + jsonChunkLength))
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    /// The BIN chunk payload, or nil when the GLB carries no binary chunk.
    func binaryChunk() -> (length: Int, type: UInt32, payload: Data)? {
        let header = 20 + jsonChunkLength
        guard header + 8 <= count else { return nil }
        let length = Int(readUInt32(at: header))
        return (length, readUInt32(at: header + 4), subdata(in: (header + 8)..<(header + 8 + length)))
    }

    /// The bytes an accessor or image reads, resolved through its buffer view.
    func bytes(ofBufferView index: Int, in json: [String: Any]) -> Data? {
        guard let bufferViews = json["bufferViews"] as? [[String: Any]],
              bufferViews.indices.contains(index),
              let offset = bufferViews[index]["byteOffset"] as? Int,
              let length = bufferViews[index]["byteLength"] as? Int,
              let payload = binaryChunk()?.payload,
              offset + length <= payload.count
        else { return nil }
        return payload.subdata(in: offset..<(offset + length))
    }
}
