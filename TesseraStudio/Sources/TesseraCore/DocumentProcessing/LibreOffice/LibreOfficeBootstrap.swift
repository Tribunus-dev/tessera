import Foundation

// MARK: - LibreOfficeBootstrap

/// Locates the LibreOffice headless bundle for in-process UNO embedding.
///
/// Discovery priority (top = highest):
///   1. Contents/Resources/LibreOffice-Headless/LibreOffice.app
///      Bundled in the app bundle by the .pkg installer.
///   2. /Applications/LibreOffice.app
///      System install (user-managed).
///
/// No network downloads — the bundle is baked into the .pkg at release time.
///
/// Architecture: hybrid in-process UNO (no soffice subprocess).
/// The embedded CPython interpreter initializes the UNO runtime directly via
/// URE_BOOTSTRAP pointing to libuuresolverlo.dylib.
/// See tessera_lo_service.py: bridge_bootstrap_uno() for the UNO init sequence.
public enum LibreOfficeBootstrap {

    // MARK: - Public API

    /// Returns the LibreOffice root URL. Throws if none is found.
    /// Call once at app startup. Thread-safe; concurrent calls are serialized.
    public static func bootstrap() throws -> URL {
        _lock.lock()
        defer { _lock.unlock() }
        if let cached = _cachedPath { return cached }
        let path = try _discover()
        _cachedPath = path
        return path
    }

    /// Path to the discovered LibreOffice root, nil if not found.
    public static var installedPath: URL? { _cachedPath }

    /// Whether a LibreOffice install was found.
    public static var isAvailable: Bool {
        _cachedPath != nil || bundlePath != nil || systemInstallPath != nil
    }

    /// How the LibreOffice installation was located.
    public enum Source: String, Sendable {
        /// Bundled in Contents/Resources/LibreOffice-Headless/ by the .pkg installer.
        case bundle
        /// Located at /Applications/LibreOffice.app (system install).
        case system
    }

    /// The source of the discovered installation.
    public static var installedSource: Source? { _cachedSource }

    // MARK: - Install paths

    /// Path inside the app bundle where the .pkg installer places LO.
    /// Contents/Resources/LibreOffice-Headless/LibreOffice.app
    public static var bundlePath: URL? {
        guard let bundle = Bundle.main.bundleURL as URL? else { return nil }
        let loApp = bundle
            .appendingPathComponent("Contents/Resources/LibreOffice-Headless/LibreOffice.app")
        return isValidInstall(at: loApp) ? loApp : nil
    }

    /// Path to the system-installed LibreOffice.app, if any.
    public static var systemInstallPath: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/LibreOffice.app"),
            URL(fileURLWithPath: "/Applications (macOS)/LibreOffice.app"),
        ]
        for url in candidates {
            if isValidInstall(at: url) { return url }
        }
        return nil
    }

    // MARK: - Environment variables for EmbeddedPythonBridge

    /// PYTHONHOME: root of the vendored Python.framework inside the LO bundle.
    public static func pythonHome(for loRoot: URL) -> URL {
        loRoot
            .appendingPathComponent("Contents/Frameworks/LibreOfficePython.framework/Versions/3.12")
    }

    /// URE_BOOTSTRAP value: tells pyuno's C extension where to find
    /// libuuresolverlo.dylib which bootstraps the in-process UNO runtime.
    public static func ureBootstrap(for loRoot: URL) -> String {
        let resolver = loRoot
            .appendingPathComponent("Contents/Frameworks/libuuresolverlo.dylib")
        return "vnd.sun.star.pathname:\(resolver.path)"
    }

    /// UNO_PATH: directory containing soffice (URE uses this).
    public static func unoPath(for loRoot: URL) -> String {
        loRoot.appendingPathComponent("Contents/MacOS").path
    }

    /// PYTHONPATH components for the embedded interpreter.
    public static func pythonPath(for loRoot: URL) -> [String] {
        let resources = loRoot.appendingPathComponent("Contents/Resources")
        let frameworks = loRoot.appendingPathComponent("Contents/Frameworks")
        let pythonHome = self.pythonHome(for: loRoot)
        let pythonLib = pythonHome.appendingPathComponent("lib/python3.12")
        let dynLoad = pythonLib.appendingPathComponent("lib-dynload")
        var paths = [
            resources.path,
            frameworks.path,
            pythonLib.path,
            dynLoad.path,
        ]
        let sitePackages = pythonLib.appendingPathComponent("site-packages")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sitePackages.path, isDirectory: &isDir) && isDir.boolValue {
            paths.append(sitePackages.path)
        }
        return paths
    }

    // MARK: - Errors

    public enum BootstrapError: Error, LocalizedError {
        /// No LibreOffice install found (not bundled and no system install).
        case notFound
        /// The found app bundle is not a valid LibreOffice install.
        case invalidInstall(URL)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "LibreOffice not found. Install it at /Applications/LibreOffice.app "
                    + "or ensure the .pkg installer bundled LibreOffice-Headless."
            case .invalidInstall(let url):
                return "Invalid LibreOffice install at \(url.path)"
            }
        }
    }

    // MARK: - Private state

    private static var _cachedPath: URL?
    private static var _cachedSource: Source?
    private static let _lock = NSLock()

    // MARK: - Discovery

    private static func _discover() throws -> URL {
        // 1. Bundle path (packaged in .pkg)
        if let bundle = bundlePath {
            _cachedSource = .bundle
            return bundle
        }

        // 2. System install
        if let system = systemInstallPath {
            _cachedSource = .system
            return system
        }

        throw BootstrapError.notFound
    }

    // MARK: - Validation

    /// Returns true if the given URL is a valid LibreOffice.app install.
    private static func isValidInstall(at url: URL) -> Bool {
        let soffice   = url.appendingPathComponent("Contents/MacOS/soffice")
        let mergedLo  = url.appendingPathComponent("Contents/Frameworks/libmergedlo.dylib")
        let pythonFw  = url.appendingPathComponent(
            "Contents/Frameworks/LibreOfficePython.framework/LibreOfficePython"
        )
        return FileManager.default.fileExists(atPath: soffice.path)
            && FileManager.default.fileExists(atPath: mergedLo.path)
            && FileManager.default.fileExists(atPath: pythonFw.path)
    }
}
