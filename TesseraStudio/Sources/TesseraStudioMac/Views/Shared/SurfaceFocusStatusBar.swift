import SwiftUI

// MARK: - SurfaceFocusStatusBar

/// The identical focus-mode status bar extracted from
/// `DocEditorView` and `NoteEditorColumn`.
///
/// Shows "N words · N min read" left-aligned and an
/// "Exit Focus" button right-aligned.
public struct SurfaceFocusStatusBar: View {
    public let wordCount: Int
    public let readingMinutes: Int
    public let onExit: () -> Void

    public init(wordCount: Int, readingMinutes: Int, onExit: @escaping () -> Void) {
        self.wordCount = wordCount
        self.readingMinutes = readingMinutes
        self.onExit = onExit
    }

    public var body: some View {
        HStack {
            Text("\(wordCount) words · \(readingMinutes) min read")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onExit) {
                Label("Exit Focus", systemImage: "arrow.up.right.and.arrow.down.left.rectangle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Exit focus mode (Escape)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
