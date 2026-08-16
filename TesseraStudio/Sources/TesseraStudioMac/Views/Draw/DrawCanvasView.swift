import SwiftUI
import AppKit
import TesseraCore

// MARK: - DrawCanvasView
//
// The Draw material's gesture-layer canvas (P2-0 item 3). Verified
// before writing this file: `TransformController` and `SnapEngine`
// exist and are fully tested as pure engines but have ZERO callers
// anywhere in the app; no `DragGesture` exists anywhere in the repo;
// `ReceiptUndoManager.group(_:)` has exactly one caller total (its own
// test file). This view is the first real caller of all three.
//
// **The two receipt systems, and why this view touches both.** This
// codebase has two independent things both named "receipt":
//   1. `GraphReceipt` (via `TesseraDataLayer.appendReceipt` /
//      `DrawingStore.appendReceipt`) - the persisted, per-material
//      audit trail every `*Store` (`DrawingStore`, `SlideStore`, ...)
//      writes to. This is what `testing-doctrine.md`'s "receipts law"
//      tests assert against, and what actually survives a document
//      reopen.
//   2. `Receipt` (`Receipt.swift`, with `Mutation`/`MutationEngine`/
//      `ReceiptSigner`/`ReceiptUndoManager`) - the signed, undoable
//      mutation chain the Writer editor uses for Cmd-Z
//      (`EditorUndoCoordinator` is its only other caller in the app).
//      `DrawingStore` does not use this system at all today.
//
// One physical drag commits through BOTH: `DrawingStore.setGeometries`
// (added this wave specifically so a multi-shape/group drag is ONE
// `GraphReceipt`, not one per shape - the actual persisted audit
// record) for persistence, and a `ReceiptUndoManager.group(_:)` call
// (one signed `Receipt` per moved shape, grouped as one undo unit) for
// local Cmd-Z bookkeeping - the exact integration point
// `TransformController.swift`'s own header comment already documented
// ("wraps a multi-shape gesture's resulting receipts in
// `ReceiptUndoManager.group(_:)` so one drag is one undo unit").
// Signing requires a Keychain-backed key (`ReceiptSigner()`, same as
// `EditorUndoCoordinator`'s production path); if it is unavailable in
// this environment, undo registration is best-effort and swallowed -
// `DrawingStore.setGeometries` has ALREADY persisted the mutation by
// that point regardless, so a signing failure never loses data, only
// this window's Cmd-Z affordance. Actually wiring Cmd-Z to call
// `undoManager.undo(...)` and bridge the inverse mutation back into
// `DrawingStore` is a follow-up (`DrawingsViewModel`'s own doc comment
// defers "a canvas-editing view-model" the same way) - out of scope
// here; this view only produces a correctly-grouped, signed chain for
// that future wiring to consume.
//
// **Zero store writes during drag; one commit at gesture end**
// (`TransformController.swift`'s own contract). Every `.onChanged`
// only updates `liveGeometries` (a local `@State` overlay); the
// `DrawingStore`/`ReceiptUndoManager` calls happen exactly once, in
// `.onEnded`, and only if something actually moved (a click-without-
// drag, or a drag that snaps back to its start, commits nothing - the
// same "no receipt without a mutation" law applied at the gesture
// layer).
//
// **What is verified by reading vs by test** (per this cluster's task
// brief): the transform MATH (translate/resize/rotate composition,
// snap application, group-delta recursion) is exercised by
// `TransformControllerTests`/`SnapEngineTests`/`DrawingStoreTests`
// directly against the pure engines - real, runnable tests. The
// SwiftUI gesture wiring in THIS file (DragGesture hit-testing,
// handle placement, NSEvent modifier reads) is verified by reading
// only; `XCUITest`-level gesture simulation is out of scope for this
// wave (no such harness exists in this target), matching the
// doctrine's "pure-logic tests only for the gesture layer" scoping.
public struct DrawCanvasView: View {

    @Binding public var drawing: Drawing
    public let store: DrawingStore
    public let undoManager: ReceiptUndoManager
    public let userID: UserID

    @State private var selectedShapeIDs: Set<UUID> = []
    @State private var dragMode: DragMode?
    @State private var dragAnchorShapeID: UUID?
    @State private var dragGroupID: UUID?
    @State private var dragStartPoint: CGPoint = .zero
    @State private var dragStartGeometries: [UUID: ShapeGeometry] = [:]
    @State private var liveGeometries: [UUID: ShapeGeometry] = [:]
    @State private var snapContext: SnapContext?
    @State private var activeGuides: [SnapGuide] = []
    @State private var lastError: String?

    /// Fixed at 1.0: this first cut of the canvas has no pan/zoom
    /// controls yet (`WorkflowCanvasView` is the sibling that does;
    /// wiring the same zoom/pan state here is a follow-up, not part of
    /// this item). `SnapEngine`'s threshold math already takes
    /// `zoomScale` as a parameter specifically so that follow-up is a
    /// call-site change, not a signature change.
    private let zoomScale: Double = 1.0
    private static let coordinateSpaceName = "tesseraDrawCanvas"

    public init(drawing: Binding<Drawing>, store: DrawingStore, undoManager: ReceiptUndoManager, userID: UserID) {
        self._drawing = drawing
        self.store = store
        self.undoManager = undoManager
        self.userID = userID
    }

    private enum DragMode: Equatable {
        case move
        case resize(handle: TransformController.Handle)
        case rotate
    }

    // MARK: - Body

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(nsColor: .textBackgroundColor))
            shapeRenderLayer
            guideLayer
            interactionLayer
        }
        .frame(width: max(drawing.canvasSize.width, 1), height: max(drawing.canvasSize.height, 1))
        .coordinateSpace(name: Self.coordinateSpaceName)
        .contentShape(Rectangle())
        .onTapGesture { selectedShapeIDs = [] }
        .overlay(alignment: .bottomLeading) {
            if let lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(4)
                    .background(.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        .accessibilityLabel("Drawing canvas with \(drawing.shapeCount) shapes")
    }

    // MARK: - Rendering (full-fidelity: reuses ShapeRenderer via the
    // Canvas's own CGContext, so fill/stroke/rotation/connector-routing
    // logic is never duplicated here)

    private var shapeRenderLayer: some View {
        Canvas { context, _ in
            let allShapes = drawing.shapes
            let renderer = ShapeRenderer()
            for shape in allShapes.sorted(by: { $0.zIndex < $1.zIndex }) {
                var renderShape = shape
                renderShape.geometry = liveGeometries[shape.id] ?? shape.geometry
                context.withCGContext { cgContext in
                    renderer.render(renderShape, in: cgContext, allShapes: allShapes)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var guideLayer: some View {
        Canvas { context, _ in
            for guide in activeGuides {
                guard case let .alignment(_, _, throughPoints, _) = guide, throughPoints.count == 2 else { continue }
                var path = Path()
                path.move(to: CGPoint(x: throughPoints[0].x, y: throughPoints[0].y))
                path.addLine(to: CGPoint(x: throughPoints[1].x, y: throughPoints[1].y))
                context.stroke(path, with: .color(.pink), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Interaction (hit areas + selection outline + handles)

    private var interactionLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(drawing.shapes) { shape in
                shapeHitArea(shape)
            }
            if selectedShapeIDs.count == 1,
               let onlyID = selectedShapeIDs.first,
               let shape = drawing.shape(id: onlyID) {
                handleOverlay(for: shape)
            }
        }
    }

    private func shapeHitArea(_ shape: TesseraCore.Shape) -> some View {
        let g = liveGeometries[shape.id] ?? shape.geometry
        return Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .overlay(
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .opacity(selectedShapeIDs.contains(shape.id) ? 1 : 0)
            )
            .frame(width: max(g.width, 2), height: max(g.height, 2))
            .rotationEffect(.degrees(g.rotation), anchor: rotationAnchor(g))
            .position(x: g.x + g.width / 2, y: g.y + g.height / 2)
            .gesture(bodyDragGesture(for: shape))
            .onTapGesture { selectedShapeIDs = [shape.id] }
            .accessibilityLabel("\(shape.kind.rawValue) shape")
            .accessibilityAddTraits(selectedShapeIDs.contains(shape.id) ? [.isSelected] : [])
    }

    @ViewBuilder
    private func handleOverlay(for shape: TesseraCore.Shape) -> some View {
        let g = liveGeometries[shape.id] ?? shape.geometry
        ForEach(TransformController.Handle.allCases, id: \.self) { handle in
            let p = TransformController.position(of: handle, in: g)
            Circle()
                .fill(handle == .rotation ? Color.orange : Color.accentColor)
                .frame(width: 9, height: 9)
                .position(x: p.x, y: p.y)
                .gesture(handleDragGesture(shapeID: shape.id, handle: handle))
                .accessibilityHidden(true)
        }
    }

    private func rotationAnchor(_ g: ShapeGeometry) -> UnitPoint {
        guard g.width > 0, g.height > 0 else { return .center }
        return UnitPoint(x: g.anchorPoint.x / g.width, y: g.anchorPoint.y / g.height)
    }

    // MARK: - Body-move gesture (translate; recurses across a group)

    private func bodyDragGesture(for shape: TesseraCore.Shape) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                if dragMode == nil { beginMoveDrag(hitShape: shape) }
                guard dragMode == .move else { return }
                applyMoveDrag(translation: value.translation)
            }
            .onEnded { _ in endDrag() }
    }

    private func beginMoveDrag(hitShape: TesseraCore.Shape) {
        let groupID = hitShape.parentGroupID
        let memberIDs: Set<UUID> = groupID.map { gid in
            Set(drawing.shapes.filter { $0.parentGroupID == gid }.map(\.id))
        } ?? [hitShape.id]
        selectedShapeIDs = memberIDs
        dragAnchorShapeID = hitShape.id
        dragGroupID = groupID
        dragStartGeometries = Dictionary(uniqueKeysWithValues:
            drawing.shapes.filter { memberIDs.contains($0.id) }.map { ($0.id, $0.geometry) })
        snapContext = SnapContext.build(
            shapes: drawing.shapes,
            selectedShapeIDs: memberIDs,
            layers: drawing.layers,
            canvasSize: drawing.canvasSize,
            gridSpacing: drawing.gridEnabled ? 20 : nil
        )
        dragMode = .move
    }

    private func applyMoveDrag(translation: CGSize) {
        guard let anchorID = dragAnchorShapeID, let anchorStart = dragStartGeometries[anchorID] else { return }
        var candidate = anchorStart
        candidate.x += translation.width
        candidate.y += translation.height
        let snap = snapContext.map {
            SnapEngine.snap(context: $0, proposedGeometry: candidate, zoomScale: zoomScale)
        } ?? .identity
        let worldDelta = CGVector(dx: translation.width + snap.dx, dy: translation.height + snap.dy)

        if let groupID = dragGroupID {
            // Recurse across every member of the group (the entry
            // point item 4 added to TransformController), not just the
            // one shape the drag started on.
            liveGeometries = TransformController.applyingGroupDelta(
                groupID: groupID, shapes: drawing.shapes, worldDelta: worldDelta)
        } else {
            var g = anchorStart
            g.x += worldDelta.dx
            g.y += worldDelta.dy
            liveGeometries = [anchorID: g]
        }
        activeGuides = snap.guides
    }

    // MARK: - Handle gesture (resize / rotate; single shape only - a
    // group-relative resize/rotate is not in scope for this item, see
    // this file's header)

    private func handleDragGesture(shapeID: UUID, handle: TransformController.Handle) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                if dragMode == nil {
                    beginHandleDrag(shapeID: shapeID, handle: handle, at: value.startLocation)
                }
                applyHandleDrag(shapeID: shapeID, handle: handle, current: value.location)
            }
            .onEnded { _ in endDrag() }
    }

    private func beginHandleDrag(shapeID: UUID, handle: TransformController.Handle, at point: CGPoint) {
        guard let shape = drawing.shape(id: shapeID) else { return }
        selectedShapeIDs = [shapeID]
        dragAnchorShapeID = shapeID
        dragGroupID = nil
        dragStartGeometries = [shapeID: shape.geometry]
        dragStartPoint = point
        dragMode = handle == .rotation ? .rotate : .resize(handle: handle)
    }

    private func applyHandleDrag(shapeID: UUID, handle: TransformController.Handle, current: CGPoint) {
        guard let start = dragStartGeometries[shapeID] else { return }
        switch dragMode {
        case .resize:
            let worldDelta = CGVector(dx: current.x - dragStartPoint.x, dy: current.y - dragStartPoint.y)
            let options = TransformController.ResizeOptions(
                centerAnchored: NSEvent.modifierFlags.contains(.option),
                aspectLocked: NSEvent.modifierFlags.contains(.shift)
            )
            liveGeometries = [shapeID: TransformController.resize(
                handle: handle, startGeometry: start, worldDelta: worldDelta, options: options)]
        case .rotate:
            var rotated = TransformController.rotate(startGeometry: start, startPoint: dragStartPoint, currentPoint: current)
            let pivot = CGPoint(x: start.x + start.anchorPoint.x, y: start.y + start.anchorPoint.y)
            let handleDistance = hypot(Double(current.x - pivot.x), Double(current.y - pivot.y))
            let snap = SnapEngine.snapRotation(rotated.rotation, handleDistance: handleDistance, zoomScale: zoomScale)
            rotated.rotation = snap.degrees
            activeGuides = snap.guide.map { [$0] } ?? []
            liveGeometries = [shapeID: rotated]
        case .move, .none:
            break
        }
    }

    // MARK: - Commit (gesture end only)

    private func endDrag() {
        guard dragMode != nil else { return }
        let toCommit = liveGeometries
        let preBody = drawing.body
        dragMode = nil
        dragAnchorShapeID = nil
        dragGroupID = nil
        dragStartGeometries = [:]
        dragStartPoint = .zero
        snapContext = nil
        activeGuides = []

        let changed = toCommit.filter { id, geometry in drawing.shape(id: id)?.geometry != geometry }
        guard !changed.isEmpty else {
            liveGeometries = [:]
            return
        }
        Task { await commit(changed, preBody: preBody) }
    }

    @MainActor
    private func commit(_ geometries: [UUID: ShapeGeometry], preBody: DocumentAST) async {
        do {
            let updated = try await store.setGeometries(geometries, for: drawing.id)
            drawing = updated
            liveGeometries = [:]
            await registerUndo(geometries: geometries, preBody: preBody)
        } catch {
            lastError = String(describing: error)
            liveGeometries = [:]
        }
    }

    /// Local Cmd-Z bookkeeping (see this file's header for why this is
    /// separate from, and best-effort relative to, the
    /// `DrawingStore.setGeometries` call above). One `Mutation
    /// .setBlockAttribute` per moved shape (the same `attributes
    /// ["shape"]` bridge `Block.shape` already uses), signed as one
    /// `Receipt` each, then grouped so the whole gesture is one undo
    /// unit.
    @MainActor
    private func registerUndo(geometries: [UUID: ShapeGeometry], preBody: DocumentAST) async {
        guard !geometries.isEmpty else { return }
        var engine = MutationEngine()
        var workingBody = preBody
        var receipts: [Receipt] = []
        var priorID = undoManager.snapshotUndoStack().last?.id
        let signer = ReceiptSigner()
        do {
            for (shapeID, geometry) in geometries {
                guard var shape = preBody.blocks[shapeID]?.shape else { continue }
                shape.geometry = geometry
                let encoded = try JSONEncoder().encode(shape)
                let anyValue = try JSONDecoder().decode(AnyCodable.self, from: encoded)
                let mutation = Mutation.setBlockAttribute(blockID: shapeID, key: "shape", value: anyValue)
                let preSnapshot = try engine.apply(mutation, to: &workingBody)
                let receipt = try signer.sign(
                    documentID: drawing.id,
                    mutations: [mutation],
                    priorReceiptID: priorID,
                    actor: .user(userID),
                    preMutationSnapshot: preSnapshot
                )
                receipts.append(receipt)
                priorID = receipt.id
            }
            if !receipts.isEmpty {
                undoManager.group(receipts)
            }
        } catch {
            // Best-effort: the persisted GraphReceipt audit trail
            // (DrawingStore.setGeometries, already awaited above) does
            // not depend on this succeeding. A missing Keychain signing
            // key only costs this window's Cmd-Z affordance.
        }
    }
}
