// swift-tools-version:5.10
//
// Broadcast Browser — a macOS web browser that outputs tabs as video
// (Blackmagic DeckLink SDI/HDMI, NDI, Syphon, fullscreen display, recording).
//
// Build the app bundle with `scripts/build_app.sh` (it also enables the
// DeckLink backend when the Blackmagic SDK headers are present in
// ThirdParty/DeckLinkSDK/include).

import PackageDescription

let syphonDirectory = "\(Context.packageDirectory)/ThirdParty/Syphon"

let package = Package(
    name: "BroadcastBrowser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BroadcastBrowser", targets: ["BroadcastBrowser"]),
    ],
    targets: [
        // Syphon (BSD) compiled from source — see ThirdParty/Syphon/README-BroadcastBrowser.md
        .target(
            name: "Syphon",
            path: "ThirdParty/Syphon",
            exclude: ["License.txt", "README-BroadcastBrowser.md", "SyphonMetalShaders.metal.txt", "headers"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SYPHON_CORE_SHARE"),
                .define("GL_SILENCE_DEPRECATION"),
                .headerSearchPath("headers"),
                .unsafeFlags(["-include", "\(syphonDirectory)/Syphon_Prefix.h", "-w"]),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("OpenGL"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
            ]
        ),
        .target(
            name: "BBBridge",
            dependencies: ["Syphon"],
            path: "Sources/BBBridge",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "BroadcastBrowser",
            dependencies: ["BBBridge"],
            path: "Sources/BroadcastBrowser",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Metal"),
                .linkedFramework("IOKit"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
