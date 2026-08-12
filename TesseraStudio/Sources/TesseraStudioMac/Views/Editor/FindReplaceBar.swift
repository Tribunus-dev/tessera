import SwiftUI
import AppKit

// MARK: - FindReplaceBar

/// A floating toolbar-style bar for find and replace operations.
/// Appears at the top of the editor when Ctrl+F is pressed.
public struct FindReplaceBar: View {
    @Binding var findText: String
    @Binding var replaceText: String
    @Binding var isVisible: Bool
    public let onFindNext: () -> Void
    public let onFindPrevious: () -> Void
    public let onReplaceNext: () -> Void
    public let onReplaceAll: () -> Void
    public let onDismiss: () -> Void

    @State private var isRegex: Bool = false
    @State private var isCaseSensitive: Bool = false
    @State private var isWholeWord: Bool = false
    @State private var matchCount: Int = 0
    @State private var currentMatch: Int = 0
    @FocusState private var isSearchFocused: Bool

    public init(
        findText: Binding<String>,
        replaceText: Binding<String>,
        isVisible: Binding<Bool>,
        onFindNext: @escaping () -> Void,
        onFindPrevious: @escaping () -> Void,
        onReplaceNext: @escaping () -> Void,
        onReplaceAll: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self._findText = findText
        self._replaceText = replaceText
        self._isVisible = isVisible
        self.onFindNext = onFindNext
        self.onFindPrevious = onFindPrevious
        self.onReplaceNext = onReplaceNext
        self.onReplaceAll = onReplaceAll
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 6) {
            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Find", text: $findText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(minWidth: 160, maxWidth: 280)
                    .focused($isSearchFocused)
                    .accessibilityLabel("Find text")
                    .onSubmit { onFindNext() }
                    .onChange(of: findText) { _, _ in
                        // Trigger a search update when find text changes.
                        onFindNext()
                    }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(.textBackgroundColor))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(.separatorColor), lineWidth: 0.5)
            )

            // Match counter
            if !findText.isEmpty {
                Text(matchCount > 0 ? "\(currentMatch)/\(matchCount)" : "No results")
                    .font(.system(size: 10))
                    .foregroundStyle(matchCount > 0 ? Color.secondary : Color.red)
                    .frame(minWidth: 40)
                    .accessibilityLabel(matchCount > 0 ? "\(currentMatch) of \(matchCount) matches" : "No matches found")
            }

            // Navigation buttons
            HStack(spacing: 2) {
                Button(action: onFindPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(findText.isEmpty)
                .help("Previous match (Shift+F3)")

                Button(action: onFindNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(findText.isEmpty)
                .help("Next match (F3)")
            }
            .frame(height: 22)

            // Option toggles
            HStack(spacing: 4) {
                Toggle(isOn: $isCaseSensitive) {
                    Text("Aa")
                        .font(.system(size: 10, weight: .bold))
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help("Case sensitive")
                .accessibilityLabel("Case sensitive")

                Toggle(isOn: $isWholeWord) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 10))
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help("Whole word")
                .accessibilityLabel("Whole word")

                Toggle(isOn: $isRegex) {
                    Text(".*")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help("Regular expression")
                .accessibilityLabel("Regular expression")
            }
            .frame(height: 22)

            Divider()
                .frame(height: 20)

            // Replace section
            HStack(spacing: 4) {
                TextField("Replace", text: $replaceText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(minWidth: 120, maxWidth: 200)
                    .accessibilityLabel("Replace with text")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(.textBackgroundColor))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(.separatorColor), lineWidth: 0.5)
            )

            HStack(spacing: 2) {
                Button(action: onReplaceNext) {
                    Text("Replace")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(findText.isEmpty)
                .help("Replace next (Ctrl+H)")

                Button(action: onReplaceAll) {
                    Text("All")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(findText.isEmpty)
                .help("Replace all (Ctrl+Alt+A)")
            }
            .frame(height: 22)

            Divider()
                .frame(height: 20)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close find bar")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
                .background(Color(.windowBackgroundColor).opacity(0.95))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separatorColor))
                .frame(height: 0.5)
        }
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .onAppear { isSearchFocused = true }
    }
}

// MARK: - VisualEffectBlur (macOS 12+)

import AppKit

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - FindReplaceCoordinator

/// Coordinates find/replace state between the toolbar and the text view.
/// The host (e.g. DocDetailView) owns this and passes it to both.
@MainActor
public final class FindReplaceCoordinator: ObservableObject {
    @Published public var findText: String = ""
    @Published public var replaceText: String = ""
    @Published public var isBarVisible: Bool = false
    @Published public var matchCount: Int = 0
    @Published public var currentMatch: Int = 0
    @Published public var isCaseSensitive: Bool = false
    @Published public var isWholeWord: Bool = false
    @Published public var isRegex: Bool = false

    public weak var textView: TesseraSTTextView?

    public init() {}

    public func showBar() {
        isBarVisible = true
    }

    public func hideBar() {
        isBarVisible = false
    }

    public func findNext() {
        guard let tv = textView, !findText.isEmpty else { return }
        let options = searchOptions()
        tv.performFind(searchText: findText, options: options, direction: .forward)
    }

    public func findPrevious() {
        guard let tv = textView, !findText.isEmpty else { return }
        let options = searchOptions()
        tv.performFind(searchText: findText, options: options, direction: .backward)
    }

    public func replaceNext() {
        guard let tv = textView, !findText.isEmpty else { return }
        tv.replaceSelection(with: replaceText)
        findNext()
    }

    public func replaceAll() {
        guard let tv = textView, !findText.isEmpty else { return }
        tv.replaceAllOccurrences(searchText: findText, with: replaceText, options: searchOptions())
    }

    private func searchOptions() -> TesseraSTTextView.FindOptions {
        var options: TesseraSTTextView.FindOptions = []
        if isCaseSensitive { options.insert(.caseSensitive) }
        if isWholeWord { options.insert(.wholeWord) }
        if isRegex { options.insert(.regularExpr) }
        options.insert(.wrap)  // Always wrap for UX consistency.
        return options
    }
}
