# swift-fbx-gltf

A Swift package that converts FBX and Wavefront OBJ files into self-contained GLB (binary glTF 2.0) files, powered by [ufbx](https://github.com/ufbx/ufbx).

## Features

- Converts FBX (binary/ASCII, all versions supported by ufbx) and OBJ to GLB
- Reads an OBJ's materials from its `.mtl` library, falling back to the library named after the OBJ when the `mtllib` path is gone
- Normalizes the scene to glTF conventions: right-handed Y-up, meters
- Node hierarchy with transforms, triangulated meshes (positions/normals/UVs/vertex colors), and vertex deduplication
- Vertex colors are converted from FBX's conventional sRGB to the linear values glTF requires
- Skeletons and skinning (joints, weights, inverse bind matrices)
- Animations, baked from the FBX transform stack (Euler orders, pivots, pre/post rotation) into linear TRS keyframes
- Blend shapes as morph targets, including weight animation, with names viewers read from `extras.targetNames`
- PBR material mapping (base color, metallic/roughness, emissive, normal/occlusion textures, opacity-based alpha blending, double-sided)
- Packs separate FBX metallic and roughness textures into glTF's combined texture, including glossiness inversion; reads Blender's Phong-flattened PBR materials back as authored
- Embeds textures into the GLB; non-PNG/JPEG images are re-encoded to PNG via ImageIO
- Texture wrap modes (repeat/clamp) carry over as glTF samplers

## Usage

```swift
import FBXGLTF

let converter = GLBConverter()
let summary = try converter.convert(
    contentsOf: URL(filePath: "model.fbx"),
    to: URL(filePath: "model.glb")
)
print(summary.warnings)
```

`GLBConverter.supportedFileExtensions` lists the extensions it reads (`fbx`, `obj`), for filtering file pickers. An OBJ is read with the `.mtl` library and textures beside it. OBJ does not record its unit or axes, so it is read as Y-up meters; set `Options.objUnitMeters` when the files come from a tool that writes another unit.

A command line tool is also included:

```sh
swift run model2glb model.fbx [model.glb]
```

## Limitations

- Dual quaternion skinning is approximated with linear blending; vertices with more than 4 bone influences keep the strongest 4
- Procedural and layered textures are approximated by the first image file they reference
- Texture UV transforms are not converted

Every limitation is reported through `Summary.warnings` when it applies to the converted file.


## License

MIT (see [LICENSE](LICENSE)). The vendored [ufbx](https://github.com/ufbx/ufbx) is also MIT licensed (see [Sources/CUfbx/LICENSE](Sources/CUfbx/LICENSE)).
