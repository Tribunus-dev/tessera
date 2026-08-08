import SwiftUI
import TesseraCore

// MARK: - SlideCanvasView

/// The 16:9 slide canvas. Renders a single ``Slide`` — a one-root
/// slice of the deck's `DocumentAST` — as a centered, shadowed card
/// with the block content laid out inside. v1 is read-only; the
/// editable variant will host an embedded `TesseraEditorView`.
public struct SlideCanvasView: View {

    public let slide: Slide
    public var isSelected: Bool = true
    public var onTap: (() -> Void)? = nil

    public init(slide: Slide, isSelected: Bool = true, onTap: (() -> Void)? = nil) {
        self.slide = slide
        self.isSelected = isSelected
        self.onTap = onTap
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let inset: CGFloat = 12
            let canvasWidth = width - inset * 2
            let canvasHeight = canvasWidth * 9 / 16
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background)
                    .shadow(color: Color.black.opacity(0.12), radius: isSelected ? 10 : 4, x: 0, y: isSelected ? 4 : 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.18),
                                    lineWidth: isSelected ? 1.5 : 0.75)
                    )
                slideContent
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: canvasWidth, height: canvasHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
        }
        .frame(minHeight: 180)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Content

    private var slideContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(slide.body.rootChildren, id: \.self) { id in
                SlideBlockRow(blockID: id, ast: slide.body)
            }
            if slide.body.rootChildren.isEmpty {
                Text("(empty slide)")
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
    }
}

// MARK: - SlideBlockRow

/// Renders one block inside the canvas. Non-recursive for toggle:
/// toggle children are rendered inline as leaves (heading /
/// paragraph / image) so the view graph stays flat and avoids the
/// opaque-type recursion error in Swift 6.
private struct SlideBlockRow: View {
    let blockID: UUID
    let ast: DocumentAST

    var body: some View {
        if let block = ast.blocks[blockID] {
            blockView(block)
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block.type {
        case .heading:
            let level = Int(block.attributes["level"]?.numberValue ?? 1)
            Text(block.content.map { $0.text }.joined())
                .font(level == 1 ? .title2.bold() : .headline)
                .lineLimit(2)
        case .paragraph:
            Text(block.content.map { $0.text }.joined())
                .font(.body).foregroundStyle(.primary)
        case .image:
            SlideInlineImage(block: block)
        case .toggle:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(block.children, id: \.self) { childID in
                    if let child = ast.blocks[childID] {
                        toggleChildView(child)
                    }
                }
            }
        case .list:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(block.children, id: \.self) { childID in
                    if let item = ast.blocks[childID] {
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(item.content.map { $0.text }.joined()).font(.body)
                        }
                    }
                }
            }
        case .listItem:
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(block.content.map { $0.text }.joined()).font(.body)
            }
        case .quote:
            HStack(alignment: .top, spacing: 6) {
                Rectangle().fill(Color.accentColor.opacity(0.55)).frame(width: 3)
                Text(block.content.map { $0.text }.joined()).font(.callout.italic())
                    .foregroundStyle(.secondary)
            }
        case .codeBlock:
            Text(block.content.map { $0.text }.joined())
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10)))
        case .callout:
            HStack(alignment: .top, spacing: 6) {
                if let emoji = block.attributes["emoji"]?.stringValue, !emoji.isEmpty {
                    Text(emoji)
                }
                Text(block.content.map { $0.text }.joined()).font(.body)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
        case .divider:
            Divider()
        case .table, .tableCell, .equation:
            Text(SlideDeck.plainText(of: ast)).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func toggleChildView(_ child: Block) -> some View {
        switch child.type {
        case .heading:
            let level = Int(child.attributes["level"]?.numberValue ?? 1)
            Text(child.content.map { $0.text }.joined())
                .font(level == 1 ? .title2.bold() : .headline)
                .lineLimit(2)
        case .paragraph:
            Text(child.content.map { $0.text }.joined())
                .font(.body).foregroundStyle(.primary)
        case .image:
            SlideInlineImage(block: child)
        case .listItem:
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(child.content.map { $0.text }.joined()).font(.body)
            }
        default:
            Text(child.content.map { $0.text }.joined()).font(.body)
        }
    }
}

private struct SlideInlineImage: View {
    let block: Block
    var body: some View {
        let urlStr = block.attributes["source"]?.stringValue ?? ""
        if let url = URL(string: urlStr), !urlStr.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .frame(maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                case .failure:
                    RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12))
                        .frame(height: 60)
                        .overlay { Label("Image unavailable", systemImage: "photo.slash").font(.caption).foregroundStyle(.secondary) }
                case .empty:
                    RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08))
                        .frame(height: 60).overlay { ProgressView() }
                @unknown default: EmptyView()
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08))
                .frame(height: 44)
                .overlay {
                    Label("Image", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
        }
    }
}

// MARK: - SlideThumbnailView

/// Small 16:9 thumbnail used in the horizontal rail.
public struct SlideThumbnailView: View {
    public let slide: Slide
    public let isSelected: Bool

    public init(slide: Slide, isSelected: Bool) {
        self.slide = slide
        self.isSelected = isSelected
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.background)
                .shadow(color: Color.black.opacity(isSelected ? 0.18 : 0.08), radius: isSelected ? 6 : 3, x: 0, y: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                                lineWidth: isSelected ? 1.25 : 0.5)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(slide.title).font(.caption2).fontWeight(.semibold).lineLimit(1)
                    .foregroundStyle(.primary)
                let preview = SlideDeck.plainTextSnippet(from: slide.body, maxLength: 80)
                if !preview.isEmpty, preview != slide.title {
                    Text(preview).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if slide.thumbnailHint != nil {
                    Image(systemName: "photo").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(6)
        }
        .frame(width: 120, height: 68)
    }
}
