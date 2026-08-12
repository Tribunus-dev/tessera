import SwiftUI
import TesseraCore

// MARK: - CodeSearchPanelView

/// The search panel: workspace-wide search. The view
/// drives `viewModel.runSearch()` on every change to
/// the query; the results are grouped by file with
/// expandable per-line hits.
public struct CodeSearchPanelView: View {

    @ObservedObject public var viewModel: CodeSurfaceViewModel
    @State private var caseSensitive: Bool = false
    @State private var isRegex: Bool = false
    @State private var languageFilter: String = ""

    public init(viewModel: CodeSurfaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchBar
            optionsBar
            Divider()
            if viewModel.searchHits.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .onChange(of: viewModel.searchQuery) { _, _ in
            viewModel.runSearch()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            TextField("Search workspace", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var optionsBar: some View {
        HStack(spacing: 8) {
            Toggle("Case", isOn: $caseSensitive)
                .toggleStyle(.button)
                .controlSize(.small)
                .accessibilityLabel("Case sensitive")
            Toggle("Regex", isOn: $isRegex)
                .toggleStyle(.button)
                .controlSize(.small)
                .accessibilityLabel("Regular expression")
            TextField("Language", text: $languageFilter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 100)
                .accessibilityLabel("Filter by language")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                viewModel.searchQuery.isEmpty ? "Type a query to search" : "No matches",
                systemImage: "text.magnifyingglass"
            )
        } description: {
            if !viewModel.searchQuery.isEmpty {
                Text("Try a different search term.")
            }
        }
    }

    private var resultsList: some View {
        let grouped = CodeSearchIndex.groupByFile(viewModel.searchHits)
        return List {
            ForEach(grouped, id: \.file.id) { group in
                Section {
                    ForEach(group.hits) { hit in
                        hitRow(hit)
                    }
                } header: {
                    HStack {
                        Text(group.file.filename)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(group.hits.count) match\(group.hits.count == 1 ? "" : "es")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func hitRow(_ hit: CodeSearchHit) -> some View {
        Button {
            // Navigation to the hit line is handled by the parent
            // view observing the search selection.
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("L\(hit.line):\(hit.column)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(hit.lineText)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Line \(hit.line): \(hit.lineText)")
        .keyboardShortcut(.return)
    }
}
