import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Normalizes texture payloads to the image formats allowed in glTF (PNG/JPEG).
enum TextureEncoder {
    struct EncodedTexture {
        var data: Data
        var mimeType: String
    }

    static func normalize(_ data: Data) -> EncodedTexture? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return EncodedTexture(data: data, mimeType: "image/png")
        }
        if data.starts(with: [0xFF, 0xD8]) {
            return EncodedTexture(data: data, mimeType: "image/jpeg")
        }
        guard let reencoded = reencodeAsPNG(data) else { return nil }
        return EncodedTexture(data: reencoded, mimeType: "image/png")
    }

    private static func reencodeAsPNG(_ data: Data) -> Data? {
        guard let image = decode(data) else { return nil }
        return encodeAsPNG(image)
    }

    /// Packs separate metallic and roughness images into the single texture glTF
    /// uses: roughness in the green channel, metallic in the blue channel.
    /// A missing image leaves its channel white so the material factor applies as-is.
    static func packMetallicRoughness(metallic: Data?, roughness: Data?, invertRoughness: Bool) -> EncodedTexture? {
        let metallicImage = metallic.flatMap(decode)
        let roughnessImage = roughness.flatMap(decode)
        guard metallicImage != nil || roughnessImage != nil else { return nil }

        let width = max(metallicImage?.width ?? 0, roughnessImage?.width ?? 0)
        let height = max(metallicImage?.height ?? 0, roughnessImage?.height ?? 0)
        guard width > 0, height > 0,
              let metallicValues = grayscale(metallicImage, width: width, height: height),
              let roughnessValues = grayscale(roughnessImage, width: width, height: height)
        else { return nil }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let roughnessValue = roughnessValues[index]
            pixels[index * 4 + 1] = invertRoughness ? 255 - roughnessValue : roughnessValue
            pixels[index * 4 + 2] = metallicValues[index]
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let packed = context.makeImage(), let encoded = encodeAsPNG(packed) else { return nil }
        return EncodedTexture(data: encoded, mimeType: "image/png")
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The image resampled to `width` x `height` as one byte per pixel;
    /// all-white when there is no image.
    private static func grayscale(_ image: CGImage?, width: Int, height: Int) -> [UInt8]? {
        var values = [UInt8](repeating: 255, count: width * height)
        guard let image else { return values }
        let succeeded = values.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return succeeded ? values : nil
    }

    private static func encodeAsPNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
