# Syphon (vendored)

Source: https://github.com/Syphon/Syphon-Framework at commit
f4761677a45b8034a3c2069ec0f3d2553da81fba (2026-09-21). BSD license, see License.txt.

Changes for Broadcast Browser:

* `SyphonServerRendererMetal.m` compiles its shader from source at runtime
  (`newLibraryWithSource:`) instead of loading a precompiled `default.metallib`,
  so the code builds with the Command Line Tools (no offline Metal compiler).
  The original shader is kept as `SyphonMetalShaders.metal.txt`.
* `Syphon_Prefix.pch` is used as `Syphon_Prefix.h` (forced include).
* `headers/Syphon/` holds symlinks so `#import <Syphon/...>` resolves.
* `SyphonBuiltIn.{h,m}` added to keep the classes linked.

The code is compiled straight into the app (SwiftPM target `Syphon`), so no
separate Syphon.framework is needed.
