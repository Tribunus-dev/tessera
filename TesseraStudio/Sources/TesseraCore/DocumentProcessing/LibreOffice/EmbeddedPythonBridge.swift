import Foundation
import Darwin
import CoreFoundation

// MARK: - LOEnvironment

/// Environment configuration for the embedded Python interpreter.
/// Captures all environment variables needed to run pyuno in-process
/// without a soffice subprocess (hybrid architecture).
public struct LOEnvironment: Sendable {
    /// Bootstrap mode for the UNO runtime.
    public enum Mode: Sendable {
        /// Hybrid in-process UNO (default). The Python interpreter initializes
        /// the UNO runtime directly via URE_BOOTSTRAP. No soffice subprocess.
        case inProcess
        /// Process-pool mode: soffice --accept runs as a subprocess and Python
        /// connects to it via a UNO socket bridge. Kept for compatibility.
        case processPool
    }

    public let loRoot: URL
    public let mode: Mode

    /// PYTHONHOME: root of the vendored Python.framework (inside LO bundle).
    public let pythonHome: URL

    /// URE_BOOTSTRAP env var value: tells pyuno where to find libuuresolverlo.
    public let ureBootstrap: String

    /// UNO_PATH env var: directory containing soffice (URE uses this).
    public let unoPath: String

    /// PYTHONPATH components for the embedded interpreter.
    public let pythonPath: [String]

    /// RESOURCE_DIR for the Python interpreter.
    public let resourceDir: URL

    /// Frameworks dir inside the LO bundle.
    public let frameworkDir: URL

    /// Builds the environment from a LibreOffice root URL.
    public init(loRoot: URL, mode: Mode = .inProcess) {
        self.loRoot = loRoot
        self.mode = mode
        self.pythonHome = LibreOfficeBootstrap.pythonHome(for: loRoot)
        self.ureBootstrap = LibreOfficeBootstrap.ureBootstrap(for: loRoot)
        self.unoPath = LibreOfficeBootstrap.unoPath(for: loRoot)
        self.pythonPath = LibreOfficeBootstrap.pythonPath(for: loRoot)
        self.resourceDir = loRoot.appendingPathComponent("Contents/Resources")
        self.frameworkDir = loRoot.appendingPathComponent("Contents/Frameworks")
    }

    /// Applies all environment variables to the current process.
    /// Call this before Py_Initialize().
    public func apply() {
        setenv("PYTHONHOME", pythonHome.path, 1)
        setenv("URE_BOOTSTRAP", ureBootstrap, 1)
        setenv("UNO_PATH", unoPath, 1)
        setenv("PYTHONPATH", pythonPath.joined(separator: ":"), 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONUNBUFFERED", "1", 1)

        // Give UNO a HOME dir for its profile
        let loHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tessera-lo/python-runtime")
        try? FileManager.default.createDirectory(at: loHome, withIntermediateDirectories: true)
        setenv("HOME", loHome.path, 1)

        // Hybrid mode: no subprocess, in-process UNO via URE_BOOTSTRAP
        // Process-pool mode: relies on tessera_lo_service.py socket bridge
        if mode == .inProcess {
            setenv("LO_UNO_MODE", "inprocess", 1)
        }
    }
}

// MARK: - EmbeddedPythonBridge

/// Embeds LibreOffice's bundled CPython 3.12 in-process.
///
/// Architecture — hybrid in-process UNO (no soffice subprocess):
/// ```
/// Tessera Studio (Swift)
///   |
///   +-- EmbeddedPythonBridge (Swift, owns Python lifecycle)
///         |
///         +-- Bundled CPython 3.12 (LibreOfficePython.framework)
///               (loaded from Contents/Resources/LibreOffice-Headless/ in the app bundle)
///               |
///               +-- tessera_lo_service.py (Python UNO bridge)
///                     |
///                     +-- pyuno C extension (loads libmergedlo in-process)
///                           |
///                           +-- libmergedlo.dylib + libuuresolverlo.dylib
///                                 (URE runtime, initialized via URE_BOOTSTRAP)
///                                   NO soffice subprocess
/// ```
///
/// Discovery order (LibreOfficeBootstrap):
///   1. Contents/Resources/LibreOffice-Headless/LibreOffice.app (bundled in .pkg)
///   2. /Applications/LibreOffice.app (system install)
///
/// The embedded Python interpreter runs on a single dedicated thread.
/// Swift calls into it via a synchronous interface. The GIL is
/// held only during the Python call — Swift can run concurrently on
/// other threads.
///
/// This is NOT an async/await bridge. Python's C API is synchronous.
/// Calls into Python block the GIL thread. For concurrent document
/// operations, LOManager distributes requests across a pool of
/// EmbeddedPythonBridge instances, each with its own embedded interpreter.
public final class EmbeddedPythonBridge: @unchecked Sendable {

    // MARK: - Lifecycle

    /// Initializes the embedded Python interpreter with hybrid in-process UNO.
    /// Call once at app startup, after LibreOfficeBootstrap.bootstrap().
    ///
    /// - Parameter loRoot: Path to the LibreOffice.app root.
    ///   Must have Contents/{MacOS,Frameworks,Resources}.
    ///
    /// - Parameter mode: UNO bootstrap mode. Defaults to `.inProcess` (no
    ///   soffice subprocess). Pass `.processPool` to use the socket bridge
    ///   instead.
    ///
    /// - Throws: `PythonError.initializationFailed` if the interpreter fails.
    public init(loRoot: URL, mode: LOEnvironment.Mode = .inProcess) throws {
        let env = LOEnvironment(loRoot: loRoot, mode: mode)
        self.environment = env
        try configureEnvironment(using: env)
        try initializePython()
    }

    /// Initializes the embedded Python interpreter with an explicit environment.
    /// Use this when you want to inspect or share the `LOEnvironment` before
    /// constructing the bridge.
    public init(environment: LOEnvironment) throws {
        self.environment = environment
        try configureEnvironment(using: environment)
        try initializePython()
    }

    deinit {
        Py_Finalize()
    }

    // MARK: - Public API

    /// The environment used to configure this interpreter.
    public let environment: LOEnvironment

    // MARK: - Public API

    /// Calls a Python function with JSON-serializable arguments.
    /// Blocks the calling thread until the Python call completes.
    ///
    /// - Parameters:
    ///   - module: Python module name (e.g. "tessera_lo_service")
    ///   - function: Function name in the module
    ///   - args: JSON-compatible arguments (String, Int, Double, Bool,
    ///     [Any], [String: Any], or nil)
    ///
    /// - Returns: The JSON-compatible result from Python.
    ///
    /// - Throws: `PythonError` if Python raises an exception or the
    ///   call fails. Swallows Swift exceptions raised by the Python code.
    public func call(
        module: String,
        function: String,
        args: [Any] = []
    ) throws -> Any? {
        ensurePythonReady()

        var gilState: PyGILState_STATE = 0
        // Acquire GIL. If the current thread already holds it (nested call
        // from Python -> Swift -> Python), PyGILState_Ensure returns
        // the saved state without deadlocking.
        gilState = PyGILState_Ensure()

        defer { PyGILState_Release(gilState) }

        guard let moduleObj = PyImport_ImportModule(module) else {
            let err = extractPythonError()
            throw PythonError.importFailed(module: module, detail: err)
        }
        defer { Py_DecRef(moduleObj) }

        guard let funcObj = PyObject_GetAttrString(moduleObj, function) else {
            let err = extractPythonError()
            throw PythonError.functionNotFound(module: module, function: function, detail: err)
        }
        defer { Py_DecRef(funcObj) }

        guard PyCallable_Check(funcObj) != 0 else {
            throw PythonError.notCallable(module: module, function: function)
        }

        let pyArgs = buildPyTuple(from: args)
        defer { Py_DecRef(pyArgs) }

        let rawResult: OpaquePointer?
        if args.isEmpty {
            rawResult = PyObject_CallObjectNoArgs(funcObj)
        } else {
            rawResult = PyObject_CallObject(funcObj, pyArgs)
        }

        if rawResult == nil {
            let err = extractPythonError()
            throw PythonError.pythonRaised(module: module, function: function, detail: err)
        }

        return convertPyToSwift(PyObjectPtr(rawResult))
    }

    /// Adds a directory to Python's sys.path at runtime.
    public func addToSysPath(_ path: String) throws {
        ensurePythonReady()
        var gilState = PyGILState_Ensure()
        defer { PyGILState_Release(gilState) }

        guard let sys = PyImport_ImportModule("sys") else {
            throw PythonError.importFailed(module: "sys", detail: extractPythonError())
        }
        defer { Py_DecRef(sys) }

        guard let pathList = PyObject_GetAttrString(sys, "path") else {
            throw PythonError.pythonRaised(module: "sys", function: "get sys.path", detail: extractPythonError())
        }
        defer { Py_DecRef(pathList) }

        let pyPath = PyUnicode_FromString(path)
        guard let pypath = pyPath else {
            throw PythonError.encodingFailed(string: path)
        }
        defer { Py_DecRef(pypath) }

        if PyList_Insert(pathList, 0, pyPath) != 0 {
            throw PythonError.pythonRaised(module: "sys", function: "sys.path.insert", detail: extractPythonError())
        }
    }

    // MARK: - Errors

    public enum PythonError: Error, LocalizedError {
        case initializationFailed(String)
        case importFailed(module: String, detail: String)
        case functionNotFound(module: String, function: String, detail: String)
        case notCallable(module: String, function: String)
        case pythonRaised(module: String, function: String, detail: String)
        case encodingFailed(string: String)
        case notReady

        public var errorDescription: String? {
            switch self {
            case .initializationFailed(let d): return "Python init failed: \(d)"
            case .importFailed(let m, let d): return "Failed to import '\(m)': \(d)"
            case .functionNotFound(let m, let f, let d): return "'\(m).\(f)' not found: \(d)"
            case .notCallable(let m, let f): return "'\(m).\(f)' is not callable"
            case .pythonRaised(let m, let f, let d): return "'\(m).\(f)' raised: \(d)"
            case .encodingFailed(let s): return "UTF-8 encoding failed for: \(s)"
            case .notReady: return "Python interpreter not initialized"
            }
        }
    }

    // MARK: - Private state

    private var _isReady = false

    // MARK: - Environment setup

    private func configureEnvironment(using env: LOEnvironment) throws {
        env.apply()
    }

    private func initializePython() throws {
        // Py_Initialize is idempotent — calling twice is safe.
        // It reads PYTHONHOME and PYTHONPATH from the environment set above.
        Py_Initialize()

        // Verify the interpreter actually started.
        guard Py_IsInitialized() == 1 else {
            throw PythonError.initializationFailed("Py_IsInitialized() returned 0")
        }

        // Suppress the deprecation warnings that Python 3.12 emits for
        // some stdlib modules when run embedded.
        var warnState: OpaquePointer?
        if let warnings = PyImport_ImportModule("warnings") {
            warnState = warnings
            // Suppress via PyRun_SimpleString rather than the variadic
            // PyObject_CallMethod (avoids C variadic import complexity).
            _ = PyRun_SimpleString(
                "import warnings; warnings.filterwarnings('ignore', category=DeprecationWarning)"
            )
        }

        // Also silence stdin closed warnings if running in a daemon context.
        _ = PyRun_SimpleString("import sys; sys.stdin = None")
        _isReady = true
    }

    // MARK: - Python type conversions

    private func buildPyTuple(from args: [Any]) -> OpaquePointer? {
        let tuple = PyTuple_New(args.count)
        for (i, arg) in args.enumerated() {
            let pyObj = buildPyObject(from: arg)
            PyTuple_SET_ITEM(tuple, i, pyObj)
        }
        return tuple
    }

    private func buildPyObject(from value: Any) -> OpaquePointer? {
        switch value {
        case let s as String:
            return PyUnicode_FromStringAndSize(s, s.utf8.count)
        case let i as Int:
            return PyLong_FromLong(i)
        case let d as Double:
            return PyFloat_FromDouble(d)
        case let b as Bool:
            return b ? Py_True : Py_False
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? Py_True : Py_False
            } else if CFGetTypeID(n) == CFNumberGetTypeID() {
                if CFNumberIsFloatType(n) {
                    return PyFloat_FromDouble(n.doubleValue)
                } else {
                    return PyLong_FromLong(n.intValue)
                }
            }
            return PyLong_FromLong(n.intValue)
        case let arr as [Any]:
            let list = PyList_New(arr.count)
            for (i, item) in arr.enumerated() {
                let pyItem = buildPyObject(from: item)
                PyList_SET_ITEM(list, i, pyItem)
            }
            return list
        case let dict as [String: Any]:
            let pyDict = PyDict_New()
            for (k, v) in dict {
                let pyKey = PyUnicode_FromStringAndSize(k, k.utf8.count)
                let pyVal = buildPyObject(from: v)
                PyDict_SetItem(pyDict, pyKey, pyVal)
                Py_DecRef(pyKey)
                Py_DecRef(pyVal)
            }
            return pyDict
        case is NSNull, is Void, nil:
            return Py_NewRef(Py_None)
        default:
            // Fallback: try JSON encoding
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let str = String(data: data, encoding: .utf8) {
                return PyUnicode_FromStringAndSize(str, str.utf8.count)
            }
            return Py_NewRef(Py_None)
        }
    }

    private func convertPyToSwift(_ pyObj: PyObjectPtr) -> Any? {
        let raw = pyObj.raw
        if raw == Py_None { return nil }
        if raw == Py_True || raw == Py_False { return raw == Py_True }
        if PyLong_Check(raw) != 0 {
            let val = PyLong_AsLong(raw)
            return Int(val)
        }
        if PyFloat_Check(raw) != 0 {
            return PyFloat_AsDouble(raw)
        }
        if PyUnicode_Check(raw) != 0 {
            // PyUnicode_AsUTF8 returns a null-terminated string.
            // PyUnicode_AsUTF8AndSize can return non-null-terminated but we
            // use the null-terminated version for Swift String compatibility.
            if let ptr = PyUnicode_AsUTF8(raw) {
                return String(cString: ptr)
            }
            return nil
        }
        if PyList_Check(raw) != 0 {
            let count = PyList_Size(raw)
            var result: [Any] = []
            result.reserveCapacity(Int(count))
            for i in 0..<count {
                let item = PyList_GetItem(raw, i)
                result.append(convertPyToSwift(PyObjectPtr(item)) as Any)
            }
            return result
        }
        if PyDict_Check(raw) != 0 {
            var result: [String: Any] = [:]
            var pos: Py_ssize_t = 0
            var key, value: UnsafeMutableRawPointer?
            while PyDict_Next(raw, &pos, &key, &value) != 0 {
                guard let k = key, let v = value else { break }
                let keyStr = String(cString: UnsafeRawPointer(k).assumingMemoryBound(to: CChar.self))
                result[keyStr] = convertPyToSwift(PyObjectPtr(OpaquePointer(v)))
            }
            return result
        }
        // Unknown type: return as string if possible
        if let repr = PyObject_Repr(raw),
           let ptr = PyUnicode_AsUTF8(repr) {
            return String(cString: ptr)
        }
        return nil
    }

    // MARK: - Error handling

    private func extractPythonError() -> String {
        guard PyErr_Occurred() != nil else { return "unknown error" }
        defer { PyErr_Clear() }

        if let excType = PyErr_ExceptionType(),
           let excVal = PyErr_ExceptionValue(),
           let tb = PyErr_Traceback(),
           let typeStr = PyObject_Str(excType),
           let valStr = PyObject_Str(excVal),
           let tbStr = PyObject_Str(tb),
           let typeCStr = PyUnicode_AsUTF8(typeStr),
           let valCStr = PyUnicode_AsUTF8(valStr),
           let tbCStr = PyUnicode_AsUTF8(tbStr) {
            return "\(String(cString: typeCStr)): \(String(cString: valCStr))\n\(String(cString: tbCStr))"
        }
        return "Python error (details unavailable)"
    }

    // MARK: - Helpers

    private func ensurePythonReady() {
        guard _isReady, Py_IsInitialized() == 1 else {
            fatalError("EmbeddedPythonBridge: Python not initialized. Call init() first.")
        }
    }
}

// MARK: - PyObjectPtr (RAII wrapper for PyObject*)

/// A simple RAII wrapper for borrowed and owned PyObject references.
/// Not thread-safe — always construct on the GIL thread.
final class PyObjectPtr {
    let raw: OpaquePointer?

    init(_ ptr: OpaquePointer?) {
        self.raw = ptr
    }

    /// Retains the object (NewRef = +1).
    init(borrowing ptr: OpaquePointer?) {
        self.raw = ptr
    }

    /// The caller gives up ownership (caller holds a NewRef).
    init(consuming ptr: OpaquePointer?) {
        self.raw = ptr
    }

    deinit {
        if let raw = raw {
            Py_DecRef(raw)
        }
    }
}

// MARK: - C API imports

// These are the subset of Python's C API we need.
// We use @_silgen_name to import individual C functions. All Python object
// pointers are typed as OpaquePointer? (opaque C struct pointers).
@_silgen_name("Py_IsInitialized")
func Py_IsInitialized() -> Int32

@_silgen_name("Py_Initialize")
func Py_Initialize()

@_silgen_name("Py_Finalize")
func Py_Finalize()

@_silgen_name("PyGILState_Ensure")
func PyGILState_Ensure() -> PyGILState_STATE

@_silgen_name("PyGILState_Release")
func PyGILState_Release(_ state: PyGILState_STATE)

@_silgen_name("PyErr_Occurred")
func PyErr_Occurred() -> OpaquePointer?

@_silgen_name("PyErr_Clear")
func PyErr_Clear()

// Bridge: PyErr_ExceptionType/Value/Traceback were removed in Python 3.14.
// Use PyErr_GetRaisedException() and extract the fields manually.
@_silgen_name("bridge_PyErr_ExceptionType")
func PyErr_ExceptionType() -> OpaquePointer?

@_silgen_name("bridge_PyErr_ExceptionValue")
func PyErr_ExceptionValue() -> OpaquePointer?

@_silgen_name("bridge_PyErr_Traceback")
func PyErr_Traceback() -> OpaquePointer?

@_silgen_name("PyObject_Str")
func PyObject_Str(_ obj: OpaquePointer?) -> OpaquePointer?

@_silgen_name("PyObject_Repr")
func PyObject_Repr(_ obj: OpaquePointer?) -> OpaquePointer?

@_silgen_name("PyImport_ImportModule")
func PyImport_ImportModule(_ name: UnsafePointer<CChar>?) -> OpaquePointer?

@_silgen_name("PyObject_GetAttrString")
func PyObject_GetAttrString(_ obj: OpaquePointer?, _ attr: UnsafePointer<CChar>?) -> OpaquePointer?

@_silgen_name("PyCallable_Check")
func PyCallable_Check(_ obj: OpaquePointer?) -> Int32

@_silgen_name("PyObject_CallNoArgs")
func PyObject_CallObjectNoArgs(_ obj: OpaquePointer?) -> OpaquePointer?

@_silgen_name("PyObject_CallObject")
func PyObject_CallObject(_ obj: OpaquePointer?, _ args: OpaquePointer?) -> OpaquePointer?

@_silgen_name("PyObject_CallMethod")
func PyObject_CallMethod(
    _ obj: OpaquePointer?,
    _ name: UnsafePointer<CChar>?,
    _ format: UnsafePointer<CChar>?,
    _ args: OpaquePointer?
) -> OpaquePointer?

@_silgen_name("PyTuple_New")
func PyTuple_New(_ size: Int) -> OpaquePointer?

@_silgen_name("PyTuple_SetItem")
func PyTuple_SET_ITEM(_ t: OpaquePointer?, _ i: Int, _ o: OpaquePointer?) -> Int32

@_silgen_name("PyList_New")
func PyList_New(_ size: Int) -> OpaquePointer?

@_silgen_name("bridge_PyList_SET_ITEM")
func PyList_SET_ITEM(_ t: OpaquePointer?, _ i: Int, _ o: OpaquePointer?) -> Int32

@_silgen_name("PyList_Insert")
func PyList_Insert(_ list: OpaquePointer?, _ i: Int, _ o: OpaquePointer?) -> Int32

@_silgen_name("bridge_PyList_GET_ITEM")
func PyList_GetItem(_ list: OpaquePointer?, _ i: Int) -> OpaquePointer?

@_silgen_name("PyList_Size")
func PyList_Size(_ list: OpaquePointer?) -> Int

@_silgen_name("PyDict_New")
func PyDict_New() -> OpaquePointer?

@_silgen_name("PyDict_SetItem")
func PyDict_SetItem(
    _ dict: OpaquePointer?,
    _ key: OpaquePointer?,
    _ val: OpaquePointer?
) -> Int32

@_silgen_name("PyDict_Next")
func PyDict_Next(
    _ dict: OpaquePointer?,
    _ pos: UnsafeMutablePointer<Py_ssize_t>?,
    _ key: UnsafeMutableRawPointer?,
    _ value: UnsafeMutableRawPointer?
) -> Int32

@_silgen_name("PyDict_Size")
func PyDict_Size(_ dict: OpaquePointer?) -> Int

@_silgen_name("PyUnicode_FromString")
func PyUnicode_FromString(_ str: UnsafePointer<CChar>?) -> OpaquePointer?

@_silgen_name("PyUnicode_FromStringAndSize")
func PyUnicode_FromStringAndSize(_ str: UnsafePointer<CChar>?, _ size: Int) -> OpaquePointer?

@_silgen_name("PyUnicode_AsUTF8")
func PyUnicode_AsUTF8(_ obj: OpaquePointer?) -> UnsafePointer<CChar>?

@_silgen_name("PyLong_FromLong")
func PyLong_FromLong(_ v: Int) -> OpaquePointer?

@_silgen_name("PyLong_AsLong")
func PyLong_AsLong(_ obj: OpaquePointer?) -> Int

@_silgen_name("PyFloat_FromDouble")
func PyFloat_FromDouble(_ v: Double) -> OpaquePointer?

@_silgen_name("PyFloat_AsDouble")
func PyFloat_AsDouble(_ obj: OpaquePointer?) -> Double

@_silgen_name("Py_NewRef")
func Py_NewRef(_ obj: OpaquePointer?) -> OpaquePointer?

@_silgen_name("Py_DecRef")
func Py_DecRef(_ obj: OpaquePointer?)

@_silgen_name("Py_INCREF")
func Py_INCREF(_ obj: OpaquePointer?)

@_silgen_name("PyRun_SimpleString")
func PyRun_SimpleString(_ str: UnsafePointer<CChar>?) -> Int32

// Type check macros
// Bridge: these are macros in Python's C API — not linkable.
// The bridging C layer (PythonBridge.c) provides real symbol entries.
@_silgen_name("bridge_PyLong_Check")
func PyLong_Check(_ obj: OpaquePointer?) -> Int32

@_silgen_name("bridge_PyFloat_Check")
func PyFloat_Check(_ obj: OpaquePointer?) -> Int32

@_silgen_name("bridge_PyUnicode_Check")
func PyUnicode_Check(_ obj: OpaquePointer?) -> Int32

@_silgen_name("bridge_PyList_Check")
func PyList_Check(_ obj: OpaquePointer?) -> Int32

@_silgen_name("bridge_PyDict_Check")
func PyDict_Check(_ obj: OpaquePointer?) -> Int32

@_silgen_name("bridge_PyBool_Check")
func PyBool_Check(_ obj: OpaquePointer?) -> Int32

// Python singletons — resolved via bridge functions.
// Python 3.14 uses __Py_NoneStruct etc. (double-underscore, Struct suffix).
// The bridge functions call Py_None/True/False which resolves correctly.
@_silgen_name("bridge_PyNone")
func _PyNone() -> OpaquePointer?

@_silgen_name("bridge_PyTrue")
func _PyTrue() -> OpaquePointer?

@_silgen_name("bridge_PyFalse")
func _PyFalse() -> OpaquePointer?

/// The Python None singleton.
var Py_None: OpaquePointer? { _PyNone() }

/// The Python True singleton.
var Py_True: OpaquePointer? { _PyTrue() }

/// The Python False singleton.
var Py_False: OpaquePointer? { _PyFalse() }

// Types
typealias Py_ssize_t = Int
typealias PyGILState_STATE = Int32

// Python bool type ID
@_silgen_name("CFBooleanGetTypeID")
func CFBooleanGetTypeID() -> CFTypeID

@_silgen_name("CFNumberGetTypeID")
func CFNumberGetTypeID() -> CFTypeID

@_silgen_name("CFGetTypeID")
func CFGetTypeID(_ obj: UnsafeRawPointer?) -> CFTypeID

@_silgen_name("CFBooleanGetValue")
func CFBooleanGetValue(_ value: UnsafeRawPointer?) -> Bool

@_silgen_name("CFNumberIsFloatType")
func CFNumberIsFloatType(_ value: UnsafeRawPointer?) -> Bool
