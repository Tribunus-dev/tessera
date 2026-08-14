import SwiftUI
import TesseraCore

// MARK: - SheetTabBarView

/// A horizontal strip of tabs, one per sheet loaded into a
/// ``SheetWorkbook`` - the UI half of `SheetWorkbook.sheetOrder`/
/// `SheetEditorViewModel.switchActiveSheet(to:)`.
///
/// `SheetEditorView` only shows this once a second sheet has actually
/// been loaded (`viewModel.openSheets.count > 1`): the common case
/// today, a single open sheet, renders no new UI at all. Nothing here
/// decides which OTHER sheets belong in a workbook - see
/// `SheetEditorViewModel.loadAdditionalSheet(_:)`'s doc comment for
/// that boundary.
public struct SheetTabBarView: View {
    public let sheets: [Sheet]
    public let activeSheetID: UUID
    public let onSelect: (UUID) -> Void

    public init(sheets: [Sheet], activeSheetID: UUID, onSelect: @escaping (UUID) -> Void) {
        self.sheets = sheets
        self.activeSheetID = activeSheetID
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(sheets) { sheet in
                    tab(for: sheet)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func tab(for sheet: Sheet) -> some View {
        let isActive = sheet.id == activeSheetID
        let title = sheet.title.isEmpty ? "Untitled" : sheet.title
        return Button {
            onSelect(sheet.id)
        } label: {
            Text(title)
                .font(.callout)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
