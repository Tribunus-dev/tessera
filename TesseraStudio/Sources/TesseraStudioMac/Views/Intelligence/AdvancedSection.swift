import SwiftUI
import TesseraCore

/// A section that auto-collapses when ``InterfaceLevel`` is `.standard`,
/// revealing its contents only when the user has opted into the advanced view.
/// Wraps SwiftUI's `DisclosureGroup` (the same primitive already used in
/// LearningTrainingSection and SettingsView) so the visual language matches.
struct AdvancedSection<Content: View>: View {
    @AppStorage("interfaceLevel") private var interfaceLevelRaw = InterfaceLevel.standard.rawValue
    @State private var expanded = false

    private let title: String
    private let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    private var interfaceLevel: InterfaceLevel {
        InterfaceLevel(rawValue: interfaceLevelRaw) ?? .standard
    }

    var body: some View {
        if interfaceLevel == .advanced {
            DisclosureGroup(isExpanded: $expanded) {
                content()
            } label: {
                Text(title).font(.headline)
            }
            .padding(.vertical, 4)
        }
    }
}
