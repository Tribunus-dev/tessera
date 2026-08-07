import SwiftUI
import TesseraCore

// MARK: - SheetGridView

/// The spreadsheet grid. Renders the primary table's column
/// headers + row indices + cell editors inline. Uses `Grid` so
/// column widths track; editing a cell goes through
/// ``SheetStore/setCell(row:col:value:for:)`` via the detail
/// view-model. No new editor engine — table blocks are rendered
/// inline.
public struct SheetGridView: View {

    @ObservedObject public var viewModel: SheetEditorViewModel

    public init(viewModel: SheetEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            gridHeader
            gridControls
            gridBody
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Header

    private var gridHeader: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 40).font(.caption2).foregroundStyle(.secondary)
                .frame(height: 28).background(Color.gray.opacity(0.08))
            ForEach(Array(viewModel.sheet.columns.enumerated()), id: \.offset) { idx, col in
                let label = col.label.isEmpty ? columnLabel(index: idx) : col.label
                HStack(spacing: 4) {
                    Text(label).font(.caption).fontWeight(.semibold).lineLimit(1)
                    if col.type != .text {
                        Image(systemName: iconForColumnType(col.type)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(Color.gray.opacity(0.08))
                .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.gray.opacity(0.15)), alignment: .trailing)
            }
            if viewModel.sheet.columns.isEmpty {
                Text("No columns").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(Color.gray.opacity(0.08))
            }
            // Spacer for the add-column affordance.
            Button { Task { await viewModel.insertColumn(at: viewModel.sheet.columnCount) } } label: {
                Image(systemName: "plus").font(.caption)
            }
            .buttonStyle(.plain).frame(width: 28, height: 28)
        }
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.gray.opacity(0.15)), alignment: .bottom)
    }

    // MARK: - Controls

    private var gridControls: some View {
        HStack(spacing: 8) {
            Button { Task { await viewModel.insertRow(at: viewModel.sheet.rowCount) } } label: {
                Label("Add row", systemImage: "plus")
            }
            .controlSize(.small)
            Button { Task { await viewModel.insertColumn(at: viewModel.sheet.columnCount) } } label: {
                Label("Add column", systemImage: "plus.rectangle.on.rectangle")
            }
            .controlSize(.small)
            Spacer()
            Text("\(viewModel.sheet.rowCount) rows x \(viewModel.sheet.columnCount) cols")
                .font(.caption).foregroundStyle(.secondary)
            if viewModel.isSaving { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.gray.opacity(0.04))
    }

    // MARK: - Body

    private var gridBody: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0..<viewModel.sheet.rowCount, id: \.self) { row in
                    GridRow {
                        // Row index
                        HStack(spacing: 4) {
                            Text("\(row + 1)").font(.caption2).foregroundStyle(.secondary)
                            Menu {
                                Button("Insert row above") { Task { await viewModel.insertRow(at: row) } }
                                Button("Insert row below") { Task { await viewModel.insertRow(at: row + 1) } }
                                if viewModel.sheet.rowCount > 1 {
                                    Divider()
                                    Button("Delete row", role: .destructive) { Task { await viewModel.deleteRow(at: row) } }
                                }
                            } label: {
                                Image(systemName: "ellipsis").font(.caption2).foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton).controlSize(.mini)
                        }
                        .frame(width: 40).frame(height: 32)
                        .background(Color.gray.opacity(0.04))
                        .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.gray.opacity(0.15)), alignment: .trailing)
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.gray.opacity(0.1)), alignment: .bottom)

                        ForEach(0..<viewModel.sheet.columnCount, id: \.self) { col in
                            let coord = SheetCellCoord(row: row, col: col)
                            let isSelected = viewModel.selectedCell == coord
                            let isEditing = viewModel.editingCell == coord
                            Group {
                                if isEditing {
                                    TextField("", text: $viewModel.editingText, onCommit: {
                                        Task { await viewModel.commitEditingCell() }
                                    })
                                    .textFieldStyle(.plain)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .onExitCommand { viewModel.cancelEditingCell() }
                                } else {
                                    Text(viewModel.sheet.cellText(row: row, col: col))
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 6)
                                        .contentShape(Rectangle())
                                }
                            }
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(isEditing ? Color.accentColor.opacity(0.08) : (isSelected ? Color.accentColor.opacity(0.12) : Color.clear))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(isSelected || isEditing ? Color.accentColor : Color.clear, lineWidth: 1)
                            )
                            .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.gray.opacity(0.12)), alignment: .trailing)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.gray.opacity(0.1)), alignment: .bottom)
                            .onTapGesture {
                                if isEditing { return }
                                if isSelected {
                                    viewModel.beginEditingCell(coord)
                                } else {
                                    viewModel.selectCell(coord)
                                }
                            }
                            .onTapGesture(count: 2) {
                                viewModel.beginEditingCell(coord)
                            }
                        }
                        // Add-column affordance per row is handled in the header.
                    }
                }
            }
        }
        .frame(minHeight: 120, maxHeight: 420)
    }

    private func columnLabel(index: Int) -> String {
        var label = ""
        var n = index
        repeat {
            label = String(UnicodeScalar(65 + n % 26)!) + label
            n = n / 26 - 1
        } while n >= 0
        return label
    }

    private func iconForColumnType(_ type: SheetColumnType) -> String {
        switch type {
        case .text: return "textformat"
        case .number: return "number"
        case .date: return "calendar"
        case .checkbox: return "checkmark.square"
        }
    }
}
