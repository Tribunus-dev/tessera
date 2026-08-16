import SwiftUI
import TesseraCore

// Lazy bootstraps for the productivity surfaces. Each mirrors
// EmailSurfaceBootstrap: a @MainActor ObservableObject that holds a
// TesseraDataLayer + the surface's store/viewmodel, and defers the Postgres
// connect to first use via installIfNeeded(). Constructed once per window as
// @State in ContentView; the view observes identity changes without
// re-creating the store on every render.

@MainActor
final class NotesSurfaceBootstrap: ObservableObject {
    private(set) var dataLayer: TesseraDataLayer
    private(set) var store: NoteStore
    private(set) var viewModel: NotesViewModel
    private var didInstall = false

    init() {
        let dl = TesseraDataLayer(configuration: .init())
        let store = NoteStore(dataLayer: dl)
        self.dataLayer = dl
        self.store = store
        self.viewModel = NotesViewModel(store: store, dataLayer: dl)
    }

    func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        Task { [dataLayer] in _ = await dataLayer.start() }
    }
}

@MainActor
final class DocsSurfaceBootstrap: ObservableObject {
    private(set) var dataLayer: TesseraDataLayer
    private(set) var store: DocStore
    private(set) var viewModel: DocsViewModel
    private var didInstall = false

    init() {
        let dl = TesseraDataLayer(configuration: .init())
        let store = DocStore(dataLayer: dl)
        self.dataLayer = dl
        self.store = store
        self.viewModel = DocsViewModel(store: store, dataLayer: dl)
        // merge_run / MailMergeWizardView (P2-C 2.4/2.21) both act
        // through this one coordinator, built off the Docs surface's
        // own data layer (a SheetStore reading from the SAME Postgres
        // connection the DocStore above already opened - no second
        // pool). Installed eagerly, unlike SheetToolContext's
        // per-selection install, since MailMergeCoordinator has no
        // "which sheet is open" concept to wait for - see
        // MailMergeToolContext's own doc comment.
        MailMergeToolContext.shared.install(MailMergeCoordinator(dataLayer: dl))
        // macro_list/macro_read/macro_translate (P2-D 2.13) resolve
        // their Doc access/persistence through this closure seam rather
        // than a constructor argument, mirroring MacroToolContext's own
        // "DocStore withheld this wave" doc comment.
        MacroToolContext.shared.install(
            loader: { docID in try await store.get(id: docID) },
            translator: { docID, outlines in try await store.translateMacro(for: docID, outlines: outlines) }
        )
        // doc_form_fields_list/doc_form_fill (P2-D 2.15) - same
        // closure-seam shape as MacroToolContext above.
        DocToolContext.shared.install(
            loader: { docID in try await store.get(id: docID) },
            filler: { blockID, value, docID in try await store.fillForm(blockID: blockID, value: value, for: docID) }
        )
        // doc_accessibility_check (P2-D 2.20) - a plain DocStore
        // reference, no closure seam needed (read-only, no mutation).
        DocAccessibilityToolContext.shared.install(store)
    }

    func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        Task { [dataLayer] in _ = await dataLayer.start() }
    }
}

@MainActor
final class SheetsSurfaceBootstrap: ObservableObject {
    private(set) var dataLayer: TesseraDataLayer
    private(set) var store: SheetStore
    private(set) var viewModel: SheetsViewModel
    private var didInstall = false

    init() {
        let dl = TesseraDataLayer(configuration: .init())
        let store = SheetStore(dataLayer: dl)
        self.dataLayer = dl
        self.store = store
        self.viewModel = SheetsViewModel(store: store, dataLayer: dl)
        // db_attach/db_schema/db_query/db_import_range/db_detach
        // (P2-D 2.16) - a self-contained actor, no TesseraDataLayer
        // needed; sheetStore is only used by db_import_range's
        // materialization path. Installed eagerly, same posture as
        // MailMergeToolContext above.
        DatabaseToolContext.shared.install(DatabaseConnector(), sheetStore: store)
    }

    func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        Task { [dataLayer] in _ = await dataLayer.start() }
    }
}

@MainActor
final class SlidesSurfaceBootstrap: ObservableObject {
    private(set) var dataLayer: TesseraDataLayer
    private(set) var store: SlideStore
    private(set) var viewModel: SlidesViewModel
    private var didInstall = false

    init() {
        let dl = TesseraDataLayer(configuration: .init())
        let store = SlideStore(dataLayer: dl)
        self.dataLayer = dl
        self.store = store
        self.viewModel = SlidesViewModel(store: store, dataLayer: dl)
    }

    func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        Task { [dataLayer] in _ = await dataLayer.start() }
    }
}

@MainActor
final class CodeSurfaceBootstrap: ObservableObject {
    private(set) var dataLayer: TesseraDataLayer
    private(set) var store: CodeStore
    private(set) var viewModel: CodeSurfaceViewModel
    private var didInstall = false

    init() {
        let dl = TesseraDataLayer(configuration: .init())
        let store = CodeStore(dataLayer: dl)
        self.dataLayer = dl
        self.store = store
        self.viewModel = CodeSurfaceViewModel(store: store)
    }

    func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        Task { [dataLayer] in _ = await dataLayer.start() }
    }
}

@MainActor
final class TasksSurfaceBootstrap: ObservableObject {
    private(set) var dataLayer: TesseraDataLayer
    private(set) var store: ProductivityTaskStore
    private var didInstall = false

    init() {
        let dl = TesseraDataLayer(configuration: .init())
        self.dataLayer = dl
        self.store = ProductivityTaskStore(dataLayer: dl)
    }

    func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        Task { [dataLayer] in _ = await dataLayer.start() }
    }
}

@MainActor
final class ContactsSurfaceBootstrap: ObservableObject {
    private(set) var dataLayer: TesseraDataLayer
    private(set) var store: ContactStore
    private(set) var importer: VCardImporter
    private var didInstall = false

    init() {
        let dl = TesseraDataLayer(configuration: .init())
        self.dataLayer = dl
        self.store = ContactStore(dataLayer: dl)
        self.importer = VCardImporter()
    }

    func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        Task { [dataLayer] in _ = await dataLayer.start() }
    }
}

@MainActor
final class RemindersSurfaceBootstrap: ObservableObject {
    private(set) var dataLayer: TesseraDataLayer
    private(set) var store: ReminderStore
    private(set) var scheduler: ReminderNotificationScheduler
    private var didInstall = false

    init() {
        let dl = TesseraDataLayer(configuration: .init())
        self.dataLayer = dl
        self.store = ReminderStore(dataLayer: dl)
        self.scheduler = ReminderNotificationScheduler()
    }

    func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        Task { [dataLayer] in _ = await dataLayer.start() }
    }
}

@MainActor
final class CalendarSurfaceBootstrap: ObservableObject {
    private(set) var dataLayer: TesseraDataLayer
    private(set) var viewModel: CalendarViewModel
    private var didInstall = false

    init() {
        let dl = TesseraDataLayer(configuration: .init())
        let store = CalendarStore(dataLayer: dl)
        // Empty static resolvers; the surface renders and accepts hand-typed
        // events. A later phase wires real contacts/documents adapters.
        let parser = CalendarNLUParser(
            contacts: StaticContactsAdapter(),
            documents: StaticDocumentResolver(),
            locations: StaticLocationResolver()
        )
        let handler = CalendarChatHandler(store: store, parser: parser)
        self.dataLayer = dl
        self.viewModel = CalendarViewModel(store: store, chatHandler: handler)
    }

    func installIfNeeded() {
        guard !didInstall else { return }
        didInstall = true
        Task { [dataLayer] in _ = await dataLayer.start() }
    }
}
