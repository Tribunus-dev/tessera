import Foundation

// MARK: - ReceiptExportServicing

/// The minimum seam the export UI depends on. ``ReceiptExportService``
/// is the production implementation (builds the artifact, then persists
/// an export receipt to a live ``TesseraDataLayer`` via ``DocumentStore``);
/// unit tests pass a thin in-memory fake (``InMemoryReceiptExportService``
/// in the test target). Mirrors ``ReminderStoring``/``CalendarStoring``/
/// ``DocumentStoring``'s role for their surfaces: the protocol is the only
/// public contract callers depend on, the production type is the
/// implementation detail.
///
/// This is `ReceiptExportService`'s one load-bearing async entry point.
/// The pure formatting helpers (`buildMarkdownSummary`, `slugify`,
/// `flattenAST`, ...) need no I/O and are already exercised directly and
/// ungated by `ReceiptExportServiceTests.swift`; they don't belong on
/// this protocol.
public protocol ReceiptExportServicing: Sendable {
    func export(
        documentID: UUID,
        format: ReceiptExportFormat,
        documentTitle: String,
        userID: UserID,
        userConfirmed: Bool
    ) async throws -> ExportArtifact
}

// ``ReceiptExportService`` already satisfies ``ReceiptExportServicing``
// member-for-member, so the conformance is a declaration, not a wrapper:
extension ReceiptExportService: ReceiptExportServicing {}
