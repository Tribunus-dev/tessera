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

let package = Package(
    name: "TesseraStudio",
    platforms: [
        // 15.2 is the floor the sources actually compile at: the editor's
        // Writing Tools coordinator (TesseraWritingToolsCoordinator) is
        // macOS 15.2+ and TesseraSTTextView stores one unconditionally.
        // The shipping .app targets macOS 26.0 via the Xcode project, so
        // nothing runs at the old .v14 claim; it only broke `swift build`
        // and with it `swift test`.
        .macOS("15.2"),
        .iOS(.v17),
    ],
    products: [
        .library(name: "TesseraCore", targets: ["TesseraCore"]),
        .executable(name: "TesseraStudioMac", targets: ["TesseraStudioMac"]),
        .library(name: "TesseraStudioiOS", targets: ["TesseraStudioiOS"]),
    ],
    dependencies: [
        // DuckDB: columnar analytical database. Originally added for graph
        // analytics ETL (degree centrality, future PageRank - Postgres
        // remains the source of truth there, see docs/linux-data-contracts.md
        // §DuckDB); item 2.16 DatabaseConnector (P2-D) reuses this same
        // dependency for its own, separate purpose - querying user-picked
        // local CSV/Parquet/JSON files read-only, in-process, no network.
        // The two uses open entirely different files; nothing is shared
        // beyond the SPM package itself.
        .package(url: "https://github.com/duckdb/duckdb-swift.git", from: "1.0.0"),
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
        // SwiftMath (mgriebling): maintained Swift port of the iosMath
        // lineage (kostub/iosMath), MIT license. Typesets LaTeX math mode
        // into a raster image via `MTMathImage.asImage()` (a headless,
        // view-free API - no window/NSView required, so it renders the
        // same way in a unit test as in the app). Item 2.14 StarMathEditor:
        // `equation.latex` stays canonical; SwiftMath is display-only. See
        // `BlockRenderer.renderLaTeX` for the shared rendering path.
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.0"),
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
        .target(
            name: "TesseraCore",
            dependencies: [
                "CLlama",
                "CTesseraFFI",
                // DuckDB: analytics ETL layer. See
                // docs/linux-data-contracts.md §DuckDB.
                .product(name: "DuckDB", package: "duckdb-swift"),
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
                // Equation rendering (item 2.14). Lives on TesseraCore, not
                // a UI-layer target: `BlockRenderer`/`DocumentExporter` are
                // both TesseraCore files shared by the macOS AND iOS app
                // surfaces (this target's own header comment), and both
                // need to rasterize a `.equation` block's LaTeX, so the
                // dependency has to be reachable from here, not scoped to
                // TesseraStudioMac the way STTextView (a macOS-only editing
                // widget) is above.
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            path: "Sources/TesseraCore",
            // Exclude agent work-in-progress files (disabled agent implementations).
            exclude: [
                "Agent/UpdateSystemPromptTool.swift.DISABLED",
                "Agent/TesseraCurationCuratorTool.swift.DISABLED",
                "Agent/SystemPromptStore.swift.DISABLED",
                "Agent/TesseraVerdictDrivenOverlayProcessor.swift.DISABLED",
                "Agent/GetSystemPromptContextTool.swift.DISABLED",
            ],
            // Ships the Skills format doc so the target has a resource bundle
            // (Bundle.module); the skill loader looks here for bundled skills.
            resources: [.copy("Skills/README.md")]
        ),
        .executableTarget(
            name: "TesseraStudioMac",
            dependencies: [
                "TesseraCore",
                .product(name: "STTextView", package: "STTextView"),
            ],
            path: "Sources/TesseraStudioMac"
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
