import Foundation

/// Encodes a glTF JSON chunk and a binary chunk into a GLB (binary glTF) container.
enum GLBContainer {
    private static let magic: UInt32 = 0x46546C67 // "glTF"
    private static let version: UInt32 = 2
    private static let jsonChunkType: UInt32 = 0x4E4F534A // "JSON"
    private static let binaryChunkType: UInt32 = 0x004E4942 // "BIN"

    static func encode(json: Data, binary: Data) -> Data {
        // Chunks must be aligned to 4 bytes: JSON is padded with spaces, binary with zeros.
        let jsonChunkLength = json.count.alignedToFour
        let binaryChunkLength = binary.count.alignedToFour
        let headerLength = 12 + 8 + jsonChunkLength
        let totalLength = headerLength + (binaryChunkLength == 0 ? 0 : 8 + binaryChunkLength)

        var data = Data(capacity: totalLength)
        appendUInt32(&data, magic)
        appendUInt32(&data, version)
        appendUInt32(&data, UInt32(totalLength))
        appendUInt32(&data, UInt32(jsonChunkLength))
        appendUInt32(&data, jsonChunkType)
        appendChunk(&data, json, paddedTo: jsonChunkLength, with: 0x20)
        if binaryChunkLength > 0 {
            appendUInt32(&data, UInt32(binaryChunkLength))
            appendUInt32(&data, binaryChunkType)
            appendChunk(&data, binary, paddedTo: binaryChunkLength, with: 0x00)
        }
        return data
    }

    private static func appendChunk(_ data: inout Data, _ payload: Data, paddedTo length: Int, with byte: UInt8) {
        data.append(payload)
        data.append(contentsOf: repeatElement(byte, count: length - payload.count))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

extension Int {
    /// Rounded up to the 4-byte alignment glTF requires.
    var alignedToFour: Int {
        (self + 3) & ~3
    }
}
