import SwiftUI
import TesseraCore
#if canImport(AppKit)
import AppKit
#endif

// MARK: - MailMergeWizardView

/// Guided single-flow sheet over `MailMergeCoordinator.run(...)` - THE
/// SAME endpoint the `merge_run` agent tool calls
/// (`Tools/MailMergeTools.swift`). P2-C item 2.21 ("Merge wizard",
/// effort S, "after 2.4" per the plan): "Gmail-style single-flow, not a
/// multi-page wizard component" (studio-expansion-design-refinement-
/// 2026-08-14.md 5, "2.21 Mail-merge wizard + 2.4 coordinator") -
/// source picker -> field chips -> preview record k -> run, laid out
/// top-to-bottom in ONE scroll view, each later section appearing once
/// its prerequisite is picked, rather than a paged/stepped wizard
/// control. No multi-step-sheet component exists anywhere else in this
/// codebase to build on (checked: `TesseraStudioMac/Views` has no
/// "wizard"/step-index type - `VersionHistorySheet` is the closest
/// existing Docs sheet and is itself a single flat view), so this is a
/// plain SwiftUI `View` with `@State` driving which sections show - the
/// simplest shape that satisfies the design contract, not a new
/// reusable wizard framework this one screen doesn't need yet.
public struct MailMergeWizardView: View {
    private let docStore: DocStore
    private let sheetStore: SheetStore
    private let coordinator: MailMergeCoordinator

    @Environment(\.dismiss) private var dismiss

    @State private var templates: [Doc] = []
    @State private var sources: [Sheet] = []
    @State private var isLoadingLists = true
    @State private var loadError: String?

    @State private var selectedTemplateID: UUID?
    @State private var selectedSourceID: UUID?

    @State private var records: [[String: String]] = []
    @State private var previewIndex: Int = 0

    /// The raw `ExportFormat.rawValue`, not the enum itself:
    /// `DocumentExporter.ExportFormat` does not declare `Hashable`
    /// (only `CaseIterable`/`Identifiable`), which `Picker(selection:)`
    /// requires of its selection type - `String` sidesteps that without
    /// touching `DocumentExporter.swift` (outside this track's file
    /// list this wave). `outputFormat` below converts back at the one
    /// call site that needs the real enum.
    @State private var outputFormatRaw: String = DocumentExporter.ExportFormat.pdf.rawValue
    private var outputFormat: DocumentExporter.ExportFormat {
        DocumentExporter.ExportFormat(rawValue: outputFormatRaw) ?? .pdf
    }
    @State private var destinationDirectory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    @State private var isRunning = false
    @State private var runResult: MailMergeRunResult?
    @State private var runError: String?

    public init(docStore: DocStore, sheetStore: SheetStore, coordinator: MailMergeCoordinator) {
        self.docStore = docStore
        self.sheetStore = sheetStore
        self.coordinator = coordinator
    }

    // MARK: - Derived state

    private var selectedTemplate: Doc? {
        templates.first { $0.id == selectedTemplateID }
    }

    private var selectedSource: Sheet? {
        sources.first { $0.id == selectedSourceID }
    }

    private var mergeFieldNames: [String] {
        guard let selectedTemplate else { return [] }
        return MailMergeCoordinator.mergeFieldNames(in: selectedTemplate)
    }

    /// Every merge field name with NO matching source column - surfaced
    /// as an "unmatched" chip so a typo'd placeholder is caught before
    /// running, rather than discovered as N blank substitutions after
    /// the fact (`FieldController`'s own documented fallback for a
    /// missing name is an empty string, not an error - this chip is the
    /// wizard's own extra guardrail on top of that graceful default).
    private var unmatchedFieldNames: Set<String> {
        guard let selectedSource else { return Set(mergeFieldNames) }
        let columnLabels = Set(
            selectedSource.columns.map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        return Set(mergeFieldNames.filter { !columnLabels.contains($0) })
    }

    private var canRun: Bool {
        selectedTemplateID != nil && selectedSourceID != nil && !records.isEmpty && !isRunning
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoadingLists {
                Spacer()
                ProgressView("Loading templates and sources…")
                Spacer()
            } else if let loadError {
                Spacer()
                emptyState(message: loadError, systemImage: "exclamationmark.triangle")
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        sourcePickerSection
                        if selectedTemplateID != nil, selectedSourceID != nil {
                            fieldChipsSection
                            if !records.isEmpty {
                                previewSection
                                runSection
                            } else {
                                emptyState(
                                    message: "The selected source has no rows to merge.",
                                    systemImage: "tablecells"
                                )
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 620)
        .task { await loadLists() }
        .onChange(of: selectedSourceID) { _, _ in reloadRecords() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Mail Merge")
                .font(.headline)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Section 1: source picker (template + record source)

    private var sourcePickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Choose a template and a record source")
                .font(.subheadline)
                .fontWeight(.semibold)

            Picker("Template document", selection: $selectedTemplateID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(templates) { doc in
                    Text(doc.displayTitle).tag(UUID?.some(doc.id))
                }
            }
            .onChange(of: selectedTemplateID) { _, _ in previewIndex = 0 }

            Picker("Record source (Sheet)", selection: $selectedSourceID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(sources) { sheet in
                    Text(sheet.displayTitle).tag(UUID?.some(sheet.id))
                }
            }

            if templates.isEmpty {
                Text("No documents found. Create a Doc with .mergeField placeholders first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if sources.isEmpty {
                Text("No sheets found. Mail merge v1 reads records from a Sheet's grid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Section 2: field chips

    private var fieldChipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Merge fields detected in the template")
                .font(.subheadline)
                .fontWeight(.semibold)

            if mergeFieldNames.isEmpty {
                Text("This template has no .mergeField placeholders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowChips(names: mergeFieldNames, unmatched: unmatchedFieldNames)
                if !unmatchedFieldNames.isEmpty {
                    Label(
                        "Fields in red have no matching column in the selected source and will merge as blank.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Section 3: preview record k

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("3. Preview")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Stepper(
                    "Record \(previewIndex + 1) of \(records.count)",
                    value: $previewIndex,
                    in: 0...max(records.count - 1, 0)
                )
                .labelsHidden()
                Text("Record \(previewIndex + 1) of \(records.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if mergeFieldNames.isEmpty {
                Text("Nothing to preview - the template has no merge fields.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let record = records[safe: previewIndex] ?? [:]
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(mergeFieldNames, id: \.self) { name in
                        let value = record[name] ?? ""
                        HStack(alignment: .top, spacing: 6) {
                            Text(name + ":")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(value.isEmpty ? "(blank)" : value)
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
            }
        }
    }

    // MARK: - Section 4: run

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("4. Run")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack {
                Picker("Format", selection: $outputFormatRaw) {
                    ForEach(DocumentExporter.ExportFormat.allCases) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
                .frame(maxWidth: 220)

                Button("Choose Folder…") { pickDestinationDirectory() }
                Text(destinationDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Button {
                    Task { await runMerge() }
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Merge \(records.count) record\(records.count == 1 ? "" : "s") → \(outputFormat.displayName)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)

                if let runResult {
                    Label("\(runResult.outputURLs.count) file(s) written", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            if let runError {
                Text(runError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Empty state

    private func emptyState(message: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data loading

    private func loadLists() async {
        isLoadingLists = true
        loadError = nil
        do {
            async let docs = docStore.listActive()
            async let sheets = sheetStore.listActive()
            templates = try await docs
            sources = try await sheets
        } catch {
            loadError = error.localizedDescription
        }
        isLoadingLists = false
    }

    /// Pulls the currently-selected source's rows into `records` via
    /// `MailMergeCoordinator.records(from:)` (pure, no store round trip
    /// beyond the `Sheet` already loaded into `sources`) - this is what
    /// feeds the preview section without a second network/DB call per
    /// keystroke.
    private func reloadRecords() {
        previewIndex = 0
        guard let selectedSource else {
            records = []
            return
        }
        records = MailMergeCoordinator.records(from: selectedSource)
    }

    private func runMerge() async {
        guard let templateID = selectedTemplateID, let sourceID = selectedSourceID else { return }
        isRunning = true
        runError = nil
        do {
            let result = try await coordinator.run(
                templateDocID: templateID,
                sourceEntityID: sourceID,
                outputFormat: outputFormat,
                destinationDirectory: destinationDirectory
            )
            runResult = result
        } catch {
            runError = error.localizedDescription
        }
        isRunning = false
    }

    #if canImport(AppKit)
    private func pickDestinationDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationDirectory
        if panel.runModal() == .OK, let url = panel.url {
            destinationDirectory = url
        }
    }
    #else
    private func pickDestinationDirectory() {}
    #endif
}

// MARK: - FlowChips

/// A simple wrapping row of field-name chips - green for a name with a
/// matching source column, orange/outlined for `unmatched`. Deliberately
/// NOT a general-purpose flow-layout component: this wizard's chip count
/// is small (one per template merge field), so a plain `HStack` that
/// wraps via `LazyVGrid`'s adaptive columns is enough, matching this
/// screen's own "effort S, plain view" scope.
private struct FlowChips: View {
    let names: [String]
    let unmatched: Set<String>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(names, id: \.self) { name in
                let isUnmatched = unmatched.contains(name)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isUnmatched ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
                    .foregroundStyle(isUnmatched ? Color.orange : Color.green)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Array safe-subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
