import XCTest
@testable import TesseraCore

/// `MasterPageStore` (P0 0.7). Async mutations need a live data layer
/// this test target doesn't stand up (see `SlideStoreTests`/
/// `DocStoreTests`, which are scoped the same way) - the mutation
/// LOGIC itself (what `defineMasterPage`/`removingMasterPage`/
/// `setMasterPage` actually change) is pinned at the pure-model level
/// in `SlideMasterPageTests`. This covers what's testable without one.
final class MasterPageStoreTests: XCTestCase {

    func testStoreConstruction() {
        let dataLayer = TesseraDataLayer()
        let store = MasterPageStore(dataLayer: dataLayer)
        _ = store
    }
}
