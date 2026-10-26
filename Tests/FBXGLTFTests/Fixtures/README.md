# Test fixtures

The FBX files are binary FBX 7.4 and are self-contained: the texture is embedded, so
conversion never touches the filesystem beyond the `.fbx` itself.

## `character_scene.fbx`

One scene holding every trait the converter has a code path for. `FixtureConversionTests`
asserts one behaviour per trait.

| Trait | How it appears |
| --- | --- |
| Skeleton and skinning | 58 bones, exported as a glTF skin with JOINTS_0/WEIGHTS_0 |
| Animation | one 33-frame idle clip, baked into TRS channels |
| Embedded texture | PNG stored inside the FBX, emitted into the GLB binary chunk |
| Several materials on one mesh | the character splits into two primitives |
| Metallic/roughness textures | the accent material carries gradient textures, packed into one glTF texture |
| Texture wrap modes | the accent textures are clamped, emitted as a glTF sampler |
| Vertex colors | `看板` fades red along +X with green pinned at linear 0.25, exported as COLOR_0 |
| Mesh instancing | `CrateA` and `CrateB` share one geometry |
| Polygons with over four corners | `看板` is a 7-gon, triangulated into 5 triangles |
| Non-ASCII names | `看板` / `看板メッシュ` |
| Blend shapes | `BlobMesh` carries a `Bulge` shape key, exported as a morph target |
| Morph weight animation | `Bulge` is keyed 0 → 1 → 0 across the clip, exported as a weights channel |
| Z-up source | the root node carries the -90° X rotation into glTF's Y-up |
| Deep hierarchy | 64 nodes, 14 levels |

## `units_centimeters.fbx`

A 1 m cube authored in centimetres. Unit scale is a per-file global setting, so it
cannot be folded into the scene above. Converting it must put a 0.01 scale on the root.

## `obj/`

Hand-written OBJ scenes for the OBJ path, with their libraries and texture beside them.

| File | Trait |
| --- | --- |
| `props.obj` | two objects (`Crate`, `Pane`), a `map_Kd` texture in `textures/`, a translucent `d 0.5` material, a hexagon without `vn` normals |
| `renamed_library.obj` | `mtllib` names a file that is gone; `renamed_library.mtl` has to be found by the OBJ's name |
| `missing_library.obj` | `mtllib` names a file that is gone and nothing stands in for it |

## Provenance and license

Derived from Kenney's **Animated Characters Protagonists** pack
(<https://kenney.nl/assets/animated-characters-3>), released under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). The character mesh,
rig, idle clip and skin texture come from that pack; the props, the second material
and the centimetre scene were authored in Blender for this test suite.

The OBJ fixtures and their texture were written for this test suite.

These fixtures are therefore CC0 as well. Crediting Kenney is not required, but is
appreciated by the author.
