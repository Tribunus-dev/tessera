import Foundation
import XCTest

// MARK: - Doctrine rule 12: timeouts are policy
//
// USAGE (read this before writing a new XCTestCase):
//
//   1. If your test class is a plain synchronous (or XCTest-managed async)
//      XCTestCase, subclass `DoctrineTestCase` instead of `XCTestCase`:
//
//          final class FooTests: DoctrineTestCase {
//              func testBar() { ... }
//          }
//
//      Every test method in the class gets a 30s wall-clock watchdog for
//      free. If a soffice-shelling / other slow probe needs the 120s
//      allowance instead, override the timeout for the whole class:
//
//          final class FooSofficeProbeTests: DoctrineTestCase {
//              override var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.probe }
//              func testConvertsRoundTrip() { ... }
//          }
//
//   2. If your test body is `async throws` and cannot subclass
//      `DoctrineTestCase` (e.g. it must inherit from some other base, or
//      you only want to bound one slow `await` inside an otherwise-fast
//      test), wrap the slow section in `withDoctrineTimeout`:
//
//          func testFetchesRemoteThing() async throws {
//              let value = try await withDoctrineTimeout {
//                  try await slowThing.fetch()
//              }
//              XCTAssertEqual(value, .expected)
//          }
//
//      Pass `seconds: DoctrineTimeout.probe` (120s) for soffice-shelling
//      async probes. Both mechanisms record the failure as an XCTIssue
//      attached to the currently-running test (via `XCTestCase.record`),
//      pointing at `file`/`line`, so a run that hangs still produces a
//      named failure instead of an unattributed multi-minute stall.
//
// WHY NOT `executionTimeAllowance`: XCTestCase already exposes an
// `executionTimeAllowance: TimeInterval` property (Xcode 11+). It was
// investigated and rejected as the "clean built-in hook" for this repo's
// constraints, for two independent reasons documented in Apple's own
// header comment (XCTestCase.h): (a) it is honored "if test timeouts are
// enabled" -- an opt-in that lives in the *Xcode scheme* / the
// `-maximum-test-execution-time-allowance` `xcodebuild` flag, neither of
// which is present when the wave gate runs a plain `swift test`; and
// (b) the value you supply "will be rounded up to the nearest minute",
// which cannot express this doctrine's 30s default or even distinguish
// it from the 120s probe allowance. Both reasons are structural, not
// version-specific, so `DoctrineTestCase` instead implements its own
// watchdog via `XCTestObservation` (`testCaseWillStart` /
// `testCaseDidFinish`), which fires an `XCTIssue` against the named test
// after `doctrineTimeoutSeconds` regardless of scheme settings.
//
// LIMITATION (documented, not hidden): the `DoctrineTestCase` watchdog
// runs on a background queue and *records* a failure on the timed-out
// test; it cannot forcibly unwind a synchronous test method that is
// truly deadlocked on the main thread (Swift/XCTest has no supported API
// for that outside of Xcode's own spindump-and-restart, which is exactly
// the `executionTimeAllowance` machinery rejected above). For test
// bodies that await genuinely cancellable async work, prefer
// `withDoctrineTimeout`, which races the operation against the timeout
// with a `withThrowingTaskGroup` and returns control to the caller
// (rather than merely flagging a still-hanging thread) as soon as the
// timeout elapses.

/// The two allowances this doctrine names (testing-doctrine.md rule 12).
public enum DoctrineTimeout {
    /// Default per-test allowance for everything that is not a
    /// soffice-shelling / external-tool probe.
    public static let standard: TimeInterval = 30
    /// Allowance for empirical probes (rule 10) that shell out to
    /// external tools such as `soffice --convert-to`.
    public static let probe: TimeInterval = 120
}

/// Thrown by `withDoctrineTimeout` when `operation` does not complete
/// within `seconds`. Also recorded as an `XCTIssue` against the calling
/// test before being rethrown, so the failure is attributed by name even
/// if the caller does not additionally catch/report it.
public struct DoctrineTimeoutError: Error, CustomStringConvertible {
    public let seconds: TimeInterval

    public var description: String {
        "operation exceeded its \(seconds)s doctrine timeout budget (testing-doctrine.md rule 12)"
    }
}

/// Runs `operation`, failing (and returning control to the caller) if it
/// has not produced a value within `seconds`. See the usage doc comment
/// at the top of this file. Default allowance is `DoctrineTimeout.standard`
/// (30s); pass `seconds: DoctrineTimeout.probe` (120s) for soffice-shelling
/// async probes (rule 10's ungated-shadow pairing still applies -- this
/// function only bounds wall-clock time, it does not gate on environment).
///
/// `operation` is declared `@escaping` (a deliberate, necessary deviation
/// from a literal non-escaping closure type): racing it against a timeout
/// task requires `withThrowingTaskGroup`, whose `addTask` closure is
/// `@escaping` by API contract, so a non-escaping `operation` could not be
/// captured by it. This does not change any call site -- trailing-closure
/// call syntax is identical either way.
public func withDoctrineTimeout<T>(
    seconds: TimeInterval = DoctrineTimeout.standard,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: @escaping () async throws -> T
) async throws -> T {
    do {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                throw DoctrineTimeoutError(seconds: seconds)
            }
            guard let value = try await group.next() else {
                throw DoctrineTimeoutError(seconds: seconds)
            }
            group.cancelAll()
            return value
        }
    } catch let timeoutError as DoctrineTimeoutError {
        XCTFail(timeoutError.description, file: file, line: line)
        throw timeoutError
    }
}

/// XCTestObservation-based watchdog: arms a background timer when a
/// `DoctrineTestCase` test starts, disarms it when the test finishes, and
/// records an `XCTIssue` against that specific test if the timer fires
/// first. Registered exactly once per process by `DoctrineTestCase`.
final class DoctrineWatchdogObserver: NSObject, XCTestObservation {
    static let shared = DoctrineWatchdogObserver()

    private let queue = DispatchQueue(label: "doctrine.watchdog.queue", qos: .utility)
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: DispatchWorkItem] = [:]

    private override init() {
        super.init()
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        guard let doctrineCase = testCase as? DoctrineTestCase else { return }
        let seconds = doctrineCase.doctrineTimeoutSeconds
        let testName = testCase.name
        let item = DispatchWorkItem { [weak testCase] in
            guard let testCase else { return }
            let issue = XCTIssue(
                type: .assertionFailure,
                compactDescription: "DoctrineTestSupport watchdog: \(testName) exceeded its \(Int(seconds))s allowance (testing-doctrine.md rule 12)."
            )
            testCase.record(issue)
        }
        lock.lock()
        pending[ObjectIdentifier(testCase)] = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        lock.lock()
        let item = pending.removeValue(forKey: ObjectIdentifier(testCase))
        lock.unlock()
        item?.cancel()
    }
}

/// Base class for doctrine-compliant test classes (rule 12). Subclass this
/// instead of `XCTestCase` and every test method gets a
/// `doctrineTimeoutSeconds` (default 30s) watchdog for free. Override
/// `doctrineTimeoutSeconds` to `DoctrineTimeout.probe` (120s) for a whole
/// soffice-shelling test class. See the file-top doc comment for the full
/// usage pattern and the `executionTimeAllowance` rejection rationale.
open class DoctrineTestCase: XCTestCase {
    /// Per-test wall-clock allowance. Override at the class level (as a
    /// computed property) to raise it for a whole suite; default is
    /// `DoctrineTimeout.standard` (30s).
    open var doctrineTimeoutSeconds: TimeInterval { DoctrineTimeout.standard }

    // Registers the shared watchdog observer exactly once per process.
    // `static let` storage on a Swift class belongs to the declaring
    // class, not to each subclass, so `DoctrineTestCase.observerRegistered`
    // is one lazily-initialized value shared by every subclass no matter
    // how many distinct `DoctrineTestCase` subclasses exist in the test
    // bundle; Swift's static-initialization guarantee makes the
    // `addTestObserver` call run exactly once even though `class setUp()`
    // itself runs once per subclass.
    private static let observerRegistered: Bool = {
        XCTestObservationCenter.shared.addTestObserver(DoctrineWatchdogObserver.shared)
        return true
    }()

    override open class func setUp() {
        super.setUp()
        _ = DoctrineTestCase.observerRegistered
    }
}
