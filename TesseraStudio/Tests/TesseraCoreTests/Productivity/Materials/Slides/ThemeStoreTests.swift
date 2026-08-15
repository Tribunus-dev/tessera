import XCTest
@testable import TesseraCore

/// `ThemeStore` (P1 1.5). Async mutations need a live data layer this
/// test target doesn't stand up (see `MasterPageStoreTests`/
/// `SlideStoreTests`, scoped the same way) - the mutation LOGIC
/// itself (what `defineTheme`/`setDeckTheme` actually change) is
/// pinned at the pure-model level in `ThemeTests`, via `SlideDeck`'s
/// own `settingTheme(_:)`/`settingActiveThemeID(_:)`. This covers
/// what's testable without one.
final class ThemeStoreTests: XCTestCase {

    func testStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = ThemeStore(dataLayer: dataLayer)
        _ = store
    }
}
