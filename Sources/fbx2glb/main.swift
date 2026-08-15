import FBXGLTF
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard let inputPath = arguments.first, arguments.count <= 2 else {
    FileHandle.standardError.write(Data("usage: fbx2glb <input.fbx> [output.glb]\n".utf8))
    exit(64)
}

let inputURL = URL(fileURLWithPath: inputPath)
let outputURL = arguments.count == 2
    ? URL(fileURLWithPath: arguments[arguments.startIndex + 1])
    : inputURL.deletingPathExtension().appendingPathExtension("glb")

do {
    let summary = try FBXToGLBConverter().convert(contentsOf: inputURL, to: outputURL)
    print("\(inputURL.lastPathComponent) -> \(outputURL.lastPathComponent)")
    print("  nodes: \(summary.nodeCount), meshes: \(summary.meshCount), primitives: \(summary.primitiveCount), triangles: \(summary.triangleCount)")
    print("  materials: \(summary.materialCount), textures: \(summary.textureCount), animations: \(summary.animationCount), size: \(summary.byteCount) bytes")
    for warning in summary.warnings {
        print("  warning: \(warning)")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
