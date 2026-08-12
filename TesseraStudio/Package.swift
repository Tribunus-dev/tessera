// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Tessera Studio v2 - target layout.
//
//   CLlama            C target: runtime-loaded (dlopen) bridge to libllama
//                     for on-device inference. Compiles against the repo's
//                     llama.h when present; otherwise builds a stub that
//                     reports unavailable (see CLLAMA_NO_HEADERS below).
//   CTesseraFFI       C target: TesseraFFIBridge's FFI surface. Compiles a
//                     stub that reports unavailable when built by SwiftPM
//                     (so swift build / swift test pass standalone). When
//                     tessera.xcframework is linked in the Xcode app the
//                     real C++ implementation takes over and isAvailable
//                     returns true. See Sources/CTesseraFFI/tessera_ffi.c.
//   TesseraCore       Platform-independent models, tool protocol, engine
//                     bridge protocol + CLI bridge, and the shared SwiftUI
//                     views (guarded with #if os() where needed).
//   TesseraStudioMac  macOS app: AppKit integrations, Settings scene,
//                     NSSavePanel export. Depends on TesseraCore.
//   TesseraStudioiOS  iOS app surface. Depends on TesseraCore.
//
// The iOS .app cannot be produced by `swift build` on a macOS host (SPM
// builds for the host platform only), so TesseraStudioiOS is a library
// target whose sources are #if os(iOS)-guarded. On a macOS build it
// compiles to an empty module; the real iOS .app is produced by the
// Xcode project, which embeds tessera.xcframework. This mirrors the
// pattern in docs/tessera-studio-design.md section 2.2.
//
// The native FFI surface (tessera.xcframework) is built by
// TesseraStudio/scripts/build-xcframework.sh and linked in the Xcode app.
// SwiftPM builds the stub in Sources/CTesseraFFI instead; see
// Sources/TesseraCore/tessera_ffi_reference.h for the contract history.

// CLlama compiles against the llama.cpp public headers, which live in the
// enclosing repo (this package is nested inside the fork). Resolve them
// relative to this manifest so the build works from any checkout location.
// When the headers are absent (package built standalone), define
// CLLAMA_NO_HEADERS so the shim compiles to an always-unavailable stub.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // TesseraStudio/
    .deletingLastPathComponent()   // repo root
let llamaHeaderDir = repoRoot.appendingPathComponent("include")
let ggmlHeaderDir = repoRoot.appendingPathComponent("ggml/include")
let commonHeaderDir = repoRoot.appendingPathComponent("common")
let hasLlamaHeaders = FileManager.default
    .fileExists(atPath: llamaHeaderDir.appendingPathComponent("llama.h").path)

let cllamaCSettings: [CSetting] = hasLlamaHeaders
    ? [
        .unsafeFlags(["-I", llamaHeaderDir.path, "-I", ggmlHeaderDir.path, "-I", commonHeaderDir.path]),
    ]
    : [
        .define("CLLAMA_NO_HEADERS"),
    ]

// Homebrew Python 3.14 include path. Formula: <Cellar>/python@3.14/<version>/
// Frameworks/Python.framework/Versions/3.14/include/python3.14.
// python3.14-config --includes prints the authoritative value at build time.
let pythonIncludeDir = "/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/include/python3.14"

let package = Package(
    name: "TesseraStudio",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "TesseraCore", targets: ["TesseraCore"]),
        .executable(name: "TesseraStudioMac", targets: ["TesseraStudioMac"]),
        .library(name: "TesseraStudioiOS", targets: ["TesseraStudioiOS"]),
    ],
    dependencies: [
        // Pure-Swift HTML parser used by the keyless web-search providers
        // (DuckDuckGo HTML endpoint). No WebKit, works headless in tests.
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        // Postgres client (SwiftNIO-based, maintained by Vapor). Used by
        // TesseraDataStore for the durable knowledge-graph + receipts store.
        // Pinned 1.21.x because the PostgresClient API stabilized there;
        // see docs/tessera-data-layer-design.md §6.1 for the dependency
        // choice and the alternatives considered.
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.2"),
        // Redis / Valkey client (SwiftNIO-based, maintained by swift-server).
        // Used by TesseraCache for the ephemeral scratchpad / decay windows.
        .package(url: "https://github.com/swift-server/RediStack.git", from: "1.6.2"),
        // Splash (JohnSundell): Swift-native syntax highlighter. Used by
        // the Phase 2 editor for highlighting `.codeBlock` blocks. Splash
        // is grammar-driven and ships a Swift grammar; other languages use
        // a small regex highlighter. See docs/tessera-productivity-editor-design.md
        // §10 for the rationale and the language list.
        .package(url: "https://github.com/JohnSundell/Splash.git", from: "0.16.0"),
        // Force-directed graph visualization (SwiftUI-native, 2D simd, KDTree).
        // Used by the Graph view (Phase 6 productivity surface). Pinned at
        // 1.1.0+ per docs/tessera-productivity-contacts-graph-design.md §14.
        .package(url: "https://github.com/SwiftGraphs/Grape.git", from: "1.1.0"),
        // STTextView (krzyzanowskim): TextKit 2 text view with built-in gutter,
        // line numbers, syntax highlighting support, and a cleaner NSTextView
        // surface. We subclass it (TesseraSTTextView) to inject our custom
        // TesseraTextContentManager; see TesseraEditorView.swift §TesseraSTTextView.
        .package(url: "https://github.com/krzyzanowskim/STTextView.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "CLlama",
            path: "Sources/CLlama",
            publicHeadersPath: "include",
            cSettings: cllamaCSettings
        ),
        .target(
            name: "CTesseraFFI",
            path: "Sources/CTesseraFFI",
            publicHeadersPath: "include"
        ),
        // CPythonBridge: C library that provides linkable wrappers for Python's
        // C API macros (PyDict_Check etc.) and renamed globals (Py_None/True/False
        // in Python 3.14). Swift imports these via @_silgen_name; the compiled
        // symbols are linked into TesseraCore via the target dependency.
        .target(
            name: "CPythonBridge",
            dependencies: [],
            path: "Sources/CPythonBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I", pythonIncludeDir]),
                // PythonBridge.h lives at Sources/CPythonBridge/include/CPythonBridge/.
                .unsafeFlags(["-I", repoRoot.appendingPathComponent("TesseraStudio/Sources/CPythonBridge/include").path]),
            ],
            linkerSettings: [
                .linkedFramework("Python"),
            ]
        ),
        .target(
            name: "TesseraCore",
            dependencies: [
                "CLlama",
                "CTesseraFFI",
                "CPythonBridge",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                // Data layer: Postgres (durable graph + receipts) and
                // RediStack (Valkey/Redis cache). Only TesseraDataStore /
                // TesseraCache import these; TesseraDataLayer is the
                // facade the rest of the app depends on. See
                // docs/tessera-data-layer-design.md §6 for the
                // hexagonal boundary rationale.
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "RediStack", package: "RediStack"),
                // Splash: Swift-native syntax highlighter for code blocks.
                // The CodeBlockHighlighter consumes it on macOS; the
                // regex fallback path is used on Linux/CI.
                .product(name: "Splash", package: "Splash"),
                // Graph view (Phase 6 productivity surface). Only the
                // Productivity/Graph viewmodel and view import these.
                .product(name: "Grape", package: "Grape"),
                .product(name: "ForceSimulation", package: "Grape"),
            ],
            path: "Sources/TesseraCore",
            // Exclude agent work-in-progress files and the Python service script
            // (loaded at runtime via dlopen, not compiled into the module).
            exclude: [
                // Agent work-in-progress files (disabled agent implementations).
                "Agent/UpdateSystemPromptTool.swift.DISABLED",
                "Agent/TesseraCurationCuratorTool.swift.DISABLED",
                "Agent/SystemPromptStore.swift.DISABLED",
                "Agent/TesseraVerdictDrivenOverlayProcessor.swift.DISABLED",
                "Agent/GetSystemPromptContextTool.swift.DISABLED",
                // Python service loaded at runtime via dlopen, not compiled in.
                "DocumentProcessing/LibreOffice/tessera_lo_service.py",
            ],
            // Ships the Skills format doc so the target has a resource bundle
            // (Bundle.module); the skill loader looks here for bundled skills.
            resources: [.copy("Skills/README.md")],
            // Python bridging is handled by the CPythonBridge target (C library).
            // The compiled symbols (bridge_PyDict_Check etc.) are linked into
            // TesseraCore via the CPythonBridge dependency. No local cSettings needed.
        ),
        .executableTarget(
            name: "TesseraStudioMac",
            dependencies: [
                "TesseraCore",
                .product(name: "STTextView", package: "STTextView"),
            ],
            path: "Sources/TesseraStudioMac",
            // CPythonBridge links Python.framework. Add a framework search path so
            // the linker can resolve Python at link time (Homebrew installs to a
            // non-standard location that SPM doesn't know about by default).
            linkerSettings: [
                // Python.framework is at a non-standard Homebrew path; SPM needs
                // the framework search path to find it at link time.
                // NOTE: SPM defaults to macOS 14.0, but Python.framework was built
                // targeting macOS 26.0. The linker warning "built for newer version"
                // is harmless at runtime. The .pkg pipeline uses xcodebuild which
                // has MACOSX_DEPLOYMENT_TARGET = 26.0 in the .xcodeproj (no warning).
                .unsafeFlags(["-F", "/opt/homebrew/opt/python@3.14/Frameworks"]),
            ]
        ),
        .target(
            name: "TesseraStudioiOS",
            dependencies: ["TesseraCore"],
            path: "Sources/TesseraStudioiOS"
        ),
        .testTarget(
            name: "TesseraCoreTests",
            dependencies: ["TesseraCore"],
            path: "Tests/TesseraCoreTests",
            // Copied verbatim so the loader's `<name>/SKILL.md` nesting is
            // preserved when the fixtures are read back via Bundle.module.
            resources: [.copy("Fixtures")]
        ),
    ]
)
