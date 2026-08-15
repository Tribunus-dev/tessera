import Foundation

// MARK: - CanvasSize

/// A drawing's page size, in points - peer of `DocumentPageLayout`
/// (`Block.swift`), which plays the same role for text documents.
public struct CanvasSize: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double = 800, height: Double = 600) {
        self.width = width
        self.height = height
    }

    /// 800x600 - an arbitrary but common blank-canvas default; nothing
    /// downstream depends on this exact value yet (no canvas view
    /// exists to render it against).
    public static let `default` = CanvasSize()
}

// MARK: - Drawing

/// A first-class Material in the Tessera productivity surface - a
/// single-page vector graphic, stored as a `graph_entity` row with
/// `entity_type = 'document'` and `subtype = 'drawing'`, matching the
/// universal "one row per thing" pattern every other material uses
/// (`docs/tessera-data-layer-design.md` §3).
///
/// `body` holds `.shape` blocks (`Shape.swift`'s own header: "A
/// Drawing's body is a flat, z-ordered list of these") persisted via
/// `Block`'s existing `attributes["shape"]` JSON bridge
/// (`Block/shape`) rather than a bespoke `[Shape]` field - the same
/// `DocumentAST`-backed storage every other material uses, so nothing
/// about receipts, JSON round-tripping, or the data layer needed to
/// change to add this material. Read through ``shapes``, not `body`
/// directly, for the flat view every P0 mutation operates on.
///
/// Grouping (`.shapeGroup`, nested shapes) is P1
/// (`docs/agent-tools-surface.md`'s `drawing_group` is marked P1
/// there) - `shapes` only walks top-level `.shape` blocks in
/// `body.rootChildren`.
///
/// Layers: `layers` below plus `LayerStore`'s pure paint-order/
/// render-list logic exist; `DrawingStore`-side layer CRUD (add/
/// delete/hide/lock/reorder, each its own receipt -
/// `docs/agent-tools-surface.md`'s `drawing_set_layer` tool) is built
/// via the pure mutators below (``addingLayer(_:)`` etc.) plus their
/// ``DrawingStore`` wrappers. `shapes` itself stays layer-unaware, in
/// `body.rootChildren` order - exactly the raw input
/// `LayerStore.paintOrder` expects.
///
/// Drawings ride the same constitutional-receipt backbone as every
/// other material: every mutation produces a signed receipt.
/// ``DrawingStore`` is the seam that enforces that invariant.
public struct Drawing: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var title: String
    public var body: DocumentAST
    public var canvasSize: CanvasSize
    /// `nil` = no background fill (the renderer's own default, e.g.
    /// white or transparent).
    public var canvasBackground: ShapeFill?
    /// Ordered named paint bands - array position is a shape's "band"
    /// in `LayerStore.paintOrder`; paint order = layer order, not just
    /// z-order (`LayerStore.swift`'s header explains why this is
    /// deliberately stronger than LibreOffice's model). Empty (the
    /// default) is every P0 drawing's implicit single layer: every
    /// shape has `layerID == nil` and paints in plain `zIndex` order,
    /// unchanged from before this field existed.
    public var layers: [DrawLayer]
    public var gridEnabled: Bool
    public var isArchived: Bool
    public var isTrashed: Bool
    public var isFavorite: Bool
    public var tags: [String]
    public var linkedEntityIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        body: DocumentAST = .empty,
        canvasSize: CanvasSize = .default,
        canvasBackground: ShapeFill? = nil,
        layers: [DrawLayer] = [],
        gridEnabled: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false,
        isFavorite: Bool = false,
        tags: [String] = [],
        linkedEntityIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.canvasSize = canvasSize
        self.canvasBackground = canvasBackground
        self.layers = layers
        self.gridEnabled = gridEnabled
        self.isArchived = isArchived
        self.isTrashed = isTrashed
        self.isFavorite = isFavorite
        self.tags = Self.normalizeTags(tags)
        self.linkedEntityIDs = linkedEntityIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Codable

    /// Custom, not synthesized: `layers` was added after this type
    /// shipped, so decoding must tolerate its absence in JSON written
    /// before it existed - `decodeIfPresent` falls back to `[]`, the
    /// same implicit-single-layer default the memberwise `init` above
    /// uses. Mirrors `DocumentAST`'s handling of its own later-added
    /// `meta` field. Every other field decodes/encodes exactly as the
    /// synthesized conformance did before this type needed a custom one.
    private enum CodingKeys: String, CodingKey {
        case id, title, body, canvasSize, canvasBackground, layers, gridEnabled
        case isArchived, isTrashed, isFavorite, tags, linkedEntityIDs, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(DocumentAST.self, forKey: .body)
        canvasSize = try container.decode(CanvasSize.self, forKey: .canvasSize)
        canvasBackground = try container.decodeIfPresent(ShapeFill.self, forKey: .canvasBackground)
        layers = try container.decodeIfPresent([DrawLayer].self, forKey: .layers) ?? []
        gridEnabled = try container.decode(Bool.self, forKey: .gridEnabled)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        isTrashed = try container.decode(Bool.self, forKey: .isTrashed)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        tags = try container.decode([String].self, forKey: .tags)
        linkedEntityIDs = try container.decode([UUID].self, forKey: .linkedEntityIDs)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(canvasSize, forKey: .canvasSize)
        try container.encodeIfPresent(canvasBackground, forKey: .canvasBackground)
        try container.encode(layers, forKey: .layers)
        try container.encode(gridEnabled, forKey: .gridEnabled)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encode(isTrashed, forKey: .isTrashed)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(tags, forKey: .tags)
        try container.encode(linkedEntityIDs, forKey: .linkedEntityIDs)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    // MARK: - Constants

    public static let entityType = "document"
    public static let subtype = "drawing"
    public var subtypeString: String { Self.subtype }

    // MARK: - Display

    /// A drawing's content is shapes, not headed prose - unlike
    /// `Doc`/`SlideDeck` there's no heading to fall back to, so an
    /// empty title is simply "Untitled".
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    // MARK: - Shapes

    /// Every top-level shape, in `body.rootChildren` order (== paint
    /// order once something has called `applyingZOrder`; a shape's own
    /// `zIndex` may disagree with array order until then, the same way
    /// `ShapeZOrder.apply`'s doc comment describes for its raw
    /// `[Shape]` input).
    public var shapes: [Shape] {
        body.rootChildren.compactMap { body.blocks[$0] }.compactMap(\.shape)
    }

    public var shapeCount: Int { shapes.count }

    public func shape(id: UUID) -> Shape? {
        shapes.first { $0.id == id }
    }

    public static func makeBlank(title: String = "Untitled", canvasSize: CanvasSize = .default) -> Drawing {
        Drawing(title: title, canvasSize: canvasSize)
    }

    // MARK: - Shape mutations (pure)

    /// A copy with `shape` appended as a new top-level `.shape` block.
    public func insertingShape(_ shape: Shape) -> Drawing {
        var updated = self
        var block = Block(id: shape.id, type: .shape)
        block.shape = shape
        updated.body.blocks[shape.id] = block
        updated.body.rootChildren.append(shape.id)
        return updated
    }

    /// A copy with the shape matching `id` removed. A no-op if no
    /// shape has that id.
    public func deletingShape(_ id: UUID) -> Drawing {
        var updated = self
        updated.body.blocks.removeValue(forKey: id)
        updated.body.rootChildren.removeAll { $0 == id }
        return updated
    }

    /// A copy with the shape matching `shape.id` replaced. A no-op if
    /// no shape has that id (this never inserts - see
    /// ``insertingShape(_:)`` for that).
    public func updatingShape(_ shape: Shape) -> Drawing {
        var updated = self
        guard updated.body.blocks[shape.id] != nil else { return self }
        updated.body.blocks[shape.id]?.shape = shape
        return updated
    }

    /// A copy with `move` applied to the shape at `id` via
    /// `ShapeZOrder.apply`, with `body.rootChildren` re-ordered to
    /// match the result so array order and `zIndex` stay in agreement.
    public func applyingZOrder(_ move: ShapeZOrder.Move, toShape id: UUID) -> Drawing {
        var updated = self
        let reordered = ShapeZOrder.apply(move, to: id, in: shapes)
        for shape in reordered {
            updated.body.blocks[shape.id]?.shape = shape
        }
        updated.body.rootChildren = reordered.map(\.id)
        return updated
    }

    // MARK: - Layer mutations (pure)

    /// A copy with `layer` appended to `layers` - the new layer paints
    /// on top of every existing one, matching `LayerStore`'s
    /// array-position-is-paint-order convention.
    public func addingLayer(_ layer: DrawLayer) -> Drawing {
        var updated = self
        updated.layers.append(layer)
        return updated
    }

    /// A copy with the layer matching `id` removed from `layers`. Any
    /// shape whose `layerID` pointed at the removed layer has its
    /// `layerID` cleared to `nil` - `LayerStore`'s own "unassigned
    /// shapes paint on the implicit base layer" convention
    /// (`LayerStore.band(of:layers:)`), never left as a dangling
    /// reference. A no-op if no layer has that id.
    public func removingLayer(_ id: UUID) -> Drawing {
        var updated = self
        guard updated.layers.contains(where: { $0.id == id }) else { return self }
        updated.layers.removeAll { $0.id == id }
        for shape in updated.shapes where shape.layerID == id {
            var orphaned = shape
            orphaned.layerID = nil
            updated.body.blocks[orphaned.id]?.shape = orphaned
        }
        return updated
    }

    /// A copy with the layer matching `id` renamed to `newName`. A
    /// no-op if no layer has that id.
    public func renamingLayer(_ id: UUID, to newName: String) -> Drawing {
        var updated = self
        guard let index = updated.layers.firstIndex(where: { $0.id == id }) else { return self }
        updated.layers[index].name = newName
        return updated
    }

    /// A copy with `layers` reordered to `newOrder` - the full list of
    /// layer ids in their new paint-order sequence (array position IS
    /// paint order, per `LayerStore`). A no-op if `newOrder` doesn't
    /// contain exactly the same set of ids as the current `layers`
    /// array - reordering never silently drops a layer.
    public func reorderingLayers(_ newOrder: [UUID]) -> Drawing {
        var updated = self
        guard newOrder.count == updated.layers.count,
              Set(newOrder) == Set(updated.layers.map(\.id)) else { return self }
        let byID = Dictionary(uniqueKeysWithValues: updated.layers.map { ($0.id, $0) })
        updated.layers = newOrder.compactMap { byID[$0] }
        return updated
    }

    /// A copy with the layer matching `id`'s `isVisible` set. A no-op
    /// if no layer has that id.
    public func settingLayerVisibility(_ id: UUID, isVisible: Bool) -> Drawing {
        var updated = self
        guard let index = updated.layers.firstIndex(where: { $0.id == id }) else { return self }
        updated.layers[index].isVisible = isVisible
        return updated
    }

    /// A copy with the layer matching `id`'s `isLocked` set. A no-op
    /// if no layer has that id.
    public func settingLayerLock(_ id: UUID, isLocked: Bool) -> Drawing {
        var updated = self
        guard let index = updated.layers.firstIndex(where: { $0.id == id }) else { return self }
        updated.layers[index].isLocked = isLocked
        return updated
    }

    // MARK: - Tag normalization

    public static func normalizeTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in tags {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted { out.append(trimmed) }
        }
        return out
    }
}

// MARK: - JSON helpers

extension Drawing {
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func from(jsonData: Data) throws -> Drawing {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Drawing.self, from: jsonData)
    }

    public func jsonDataString() throws -> String {
        let data = try jsonData()
        guard let s = String(data: data, encoding: .utf8) else {
            throw DrawingStoreError.invalidBody(reason: "encoded JSON is not UTF-8")
        }
        return s
    }

    public static func from(jsonDataString: String) throws -> Drawing {
        guard let data = jsonDataString.data(using: .utf8) else {
            throw DrawingStoreError.invalidBody(reason: "body is not valid UTF-8")
        }
        return try from(jsonData: data)
    }
}
