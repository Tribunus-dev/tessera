import SwiftUI
import TesseraCore

// MARK: - LayoutInspectorView

/// A popover panel for editing page layout properties:
/// page size, orientation, margins, columns, and page color.
///
/// Attached to the Layout ribbon tab's toolbar buttons.
/// The host passes the current `DocumentAST` and a callback
/// that fires the appropriate `EditorCommand`.
public struct LayoutInspectorView: View {
    @Binding var document: DocumentAST
    let onCommand: (EditorCommand) -> Void

    @State private var selectedPreset: MarginPreset = .normal
    @State private var customTop: Double = 72
    @State private var customBottom: Double = 72
    @State private var customLeft: Double = 72
    @State private var customRight: Double = 72
    @State private var useCustomMargins: Bool = false
    @State private var orientation: Orientation = .portrait
    @State private var columnCount: Int = 1
    @State private var pageColorHex: String = "#FFFFFF"

    public init(document: Binding<DocumentAST>, onCommand: @escaping (EditorCommand) -> Void) {
        self._document = document
        self.onCommand = onCommand
        // Initialize state from the current document.
        let layout = document.wrappedValue.pageLayout
        _customTop = State(initialValue: layout.marginTop)
        _customBottom = State(initialValue: layout.marginBottom)
        _customLeft = State(initialValue: layout.marginLeft)
        _customRight = State(initialValue: layout.marginRight)
        _columnCount = State(initialValue: layout.columnCount)
        _pageColorHex = State(initialValue: layout.pageColor)
        _orientation = State(initialValue: layout.pageWidth > layout.pageHeight ? .landscape : .portrait)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pageSizeSection
                    orientationSection
                    marginsSection
                    columnsSection
                    pageColorSection
                }
                .padding(16)
            }
        }
        .frame(width: 280, height: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Page Layout")
                .font(.headline)
            Spacer()
            Button("Done") {
                // Each onCommand already pushes to the binding; nothing extra needed.
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Page size

    private var pageSizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Page Size")
            HStack(spacing: 8) {
                pageSizeButton("A4", 595, 842)
                pageSizeButton("Letter", 612, 792)
                pageSizeButton("Legal", 612, 1008)
            }
        }
    }

    private func pageSizeButton(_ label: String, _ w: Double, _ h: Double) -> some View {
        let isSelected = document.pageLayout.pageWidth == w && document.pageLayout.pageHeight == h
        return Button {
            var doc = document
            doc.pageLayout.pageWidth = w
            doc.pageLayout.pageHeight = h
            document = doc
            onCommand(.setOrientation(w > h ? .landscape : .portrait))
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Orientation

    private var orientationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Orientation")
            HStack(spacing: 8) {
                orientationButton(.portrait, "Portrait", "rectangle.portrait")
                orientationButton(.landscape, "Landscape", "rectangle.landscape")
            }
        }
    }

    private func orientationButton(_ o: Orientation, _ label: String, _ icon: String) -> some View {
        let isSelected = orientation == o
        return Button {
            orientation = o
            onCommand(.setOrientation(o))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Margins

    private var marginsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Margins")
            HStack(spacing: 6) {
                marginPresetButton(.narrow)
                marginPresetButton(.normal)
                marginPresetButton(.wide)
                marginPresetButton(.veryWide)
            }
            if useCustomMargins {
                VStack(spacing: 4) {
                    marginField("Top", value: $customTop)
                    marginField("Bottom", value: $customBottom)
                    marginField("Left", value: $customLeft)
                    marginField("Right", value: $customRight)
                }
            } else {
                Button("Custom margins...") {
                    useCustomMargins = true
                    customTop = document.pageLayout.marginTop
                    customBottom = document.pageLayout.marginBottom
                    customLeft = document.pageLayout.marginLeft
                    customRight = document.pageLayout.marginRight
                }
                .font(.caption)
            }
        }
    }

    private func marginPresetButton(_ preset: MarginPreset) -> some View {
        let label: String
        switch preset {
        case .narrow: label = "Narrow"
        case .normal: label = "Normal"
        case .wide: label = "Wide"
        case .veryWide: label = "V. Wide"
        }
        return Button {
            selectedPreset = preset
            useCustomMargins = false
            onCommand(.setMargins(preset))
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selectedPreset == preset && !useCustomMargins ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundColor(selectedPreset == preset && !useCustomMargins ? .white : .primary)
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func marginField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 50, alignment: .trailing)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
            Text("pt")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Columns

    private var columnsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Columns")
            HStack(spacing: 6) {
                ForEach(1..<7, id: \.self) { n in
                    Button { } label: {
                        Text("\(n)")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(columnCount == n ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                            .foregroundColor(columnCount == n ? .white : .primary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .onTapGesture {
                        columnCount = n
                        onCommand(.setColumns(n))
                    }
                }
            }
        }
    }

    // MARK: - Page color

    private var pageColorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Page Color")
            HStack(spacing: 6) {
                colorSwatch("#FFFFFF", "White")
                colorSwatch("#FFF8DC", "Cream")
                colorSwatch("#F0F0F0", "Light Gray")
                colorSwatch("#E8F4F8", "Blue Tint")
                colorSwatch("#F4F4F4", "Dark Mode")
            }
            HStack(spacing: 6) {
                colorSwatch("#000000", "Black")
                colorSwatch("#1A1A2E", "Dark Navy")
                colorSwatch("#2D2D2D", "Dark Gray")
                colorSwatch("#162A2A", "Dark Green")
                colorSwatch("#2A1A2A", "Dark Purple")
            }
        }
    }

    private func colorSwatch(_ hex: String, _ label: String) -> some View {
        let isSelected = pageColorHex == hex
        return Button { } label: {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(hexColor(hex))
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                    )
                Text(label)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 40)
        }
        .buttonStyle(.plain)
        .onTapGesture {
            pageColorHex = hex
            onCommand(.setPageColor(hex))
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - Color hex helper

/// Parse a hex color string (e.g. "#FF0000" or "FF0000") to Color.
/// Uses the Color(hex:) from AgentCursorOverlay (same module).
private func hexColor(_ hex: String) -> Color {
    Color(hex) ?? .white
}
