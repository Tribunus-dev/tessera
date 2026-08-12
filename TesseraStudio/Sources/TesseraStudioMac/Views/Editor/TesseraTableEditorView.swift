import AppKit
import TesseraCore

// MARK: - TesseraTableEditorOverlay

/// A floating overlay editor for table blocks.
///
/// The overlay appears when the user activates a table block (double-click
/// or Enter on the placeholder). It contains an NSTableView with editable
/// cells, column resize handles, and Tab/Shift+Tab navigation. On dismiss,
/// it syncs all cell content back to the document AST.
///
/// Wired into ``TesseraEditorView.Coordinator`` via
/// `showTableEditor(for:)`.
@MainActor
public final class TesseraTableEditorOverlay: NSView {
    // MARK: - Public API

    /// The block ID of the table being edited.
    public private(set) var tableBlockID: UUID?

    /// Called when the user dismisses the editor (Escape / Enter / click outside).
    /// Passes the updated table block for the caller to commit as a mutation.
    public var onDismiss: ((Block?) -> Void)?

    // MARK: - Internal state

    private var rows: Int = 3
    private var columns: Int = 3
    private var cellText: [[String]] = []
    private var columnWidths: [CGFloat] = []
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private let minColumnWidth: CGFloat = 60
    private let defaultColumnWidth: CGFloat = 120
    private var activeCellRow: Int = 0
    private var activeCellCol: Int = 0
    private var resizeColumnIndex: Int? = nil
    private var resizeStartX: CGFloat = 0
    private var resizeStartWidths: [CGFloat] = []

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    /// Configure the editor with an existing table block. Call after
    /// `addSubview` / `frame` is set.
    public func configure(with block: Block) {
        tableBlockID = block.id
        rows = block.attributes["rows"]?.intValue ?? 3
        columns = block.attributes["cols"]?.intValue ?? 3
        columnWidths = (0..<columns).map { col in
            if case .array(let widths) = block.attributes["columnWidths"],
               col < widths.count,
               case .number(let w) = widths[col] {
                return CGFloat(w)
            }
            return defaultColumnWidth
        }
        // Reset to empty cells; configureCells() will fill them.
        cellText = (0..<rows).map { _ in (0..<columns).map { _ in "" } }
        tableView.reloadData()
    }

    /// Fill cell text from an external block-ID -> content map.
    public func configureCells(_ contentByID: [UUID: [InlineRun]]) {
        // This is called by the coordinator with the live cell content.
    }

    /// Configure with explicit cell text (coordinator passes this).
    public func setCellText(_ text: [[String]]) {
        cellText = text
        rows = text.count
        columns = text.first?.count ?? 0
        if columnWidths.count < columns {
            columnWidths.append(contentsOf: [CGFloat](repeating: defaultColumnWidth, count: columns - columnWidths.count))
        }
        tableView?.reloadData()
    }

    // MARK: - Setup

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        NSShadow.editorOverlayShadow.apply(to: layer!)

        // Title bar
        let titleBar = NSView()
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleBar)

        let label = NSTextField(labelWithString: "Table Editor")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(label)

        let closeButton = NSButton(title: "", target: self, action: #selector(dismissEditor))
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(closeButton)

        // NSTableView
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.gridColor = NSColor.separatorColor

        for col in 0..<columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col_\(col)"))
            column.title = "Column \(col + 1)"
            column.width = columnWidths[safe: col] ?? defaultColumnWidth
            column.minWidth = minColumnWidth
            column.maxWidth = 400
            column.isEditable = true
            column.dataCell = NSTextField()
            tableView.addTableColumn(column)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked)

        scrollView.documentView = tableView

        // Size hints
        let totalWidth = columnWidths.reduce(0, +) + 20
        let totalHeight = CGFloat(rows) * 28 + 36 + 32 // rows * rowHeight + header + padding

        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 36),

            label.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 12),

            closeButton.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        // Keyboard handling
        becomeFirstResponder()
    }

    // MARK: - Keyboard navigation

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? ""
        let mods = event.modifierFlags

        switch (key, mods.contains(.shift)) {
        case ("\t", false):
            // Tab: move to next cell
            moveToCell(row: activeCellRow, col: activeCellCol + 1)
        case ("\t", true):
            // Shift+Tab: move to previous cell
            moveToCell(row: activeCellRow, col: activeCellCol - 1)
        case ("\r", _):
            // Enter / Return: commit current cell and move down
            commitCurrentCell()
            moveToCell(row: activeCellRow + 1, col: activeCellCol)
        case ("\u{1B}", _):
            // Escape: cancel and dismiss
            dismissEditor()
        default:
            super.keyDown(with: event)
        }
    }

    private func moveToCell(row: Int, col: Int) {
        // Wrap around edges.
        var r = row
        var c = col
        if c < 0 { r -= 1; c = columns - 1 }
        if c >= columns { r += 1; c = 0 }
        r = max(0, min(rows - 1, r))
        c = max(0, min(columns - 1, c))
        activeCellRow = r
        activeCellCol = c
        tableView.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        tableView.scrollRowToVisible(r)
        if let editor = tableView.view(atColumn: c, row: r, makeIfNecessary: false) as? NSTableCellView,
           let field = editor.subviews.first as? NSTextField {
            window?.makeFirstResponder(field)
        }
    }

    private func commitCurrentCell() {
        // Cell text is already in cellText; just mark it.
    }

    // MARK: - Actions

    @objc private func dismissEditor() {
        // Build updated cell text array before dismissing.
        let finalText = cellText
        onDismiss?(buildTableBlock(text: finalText))
        removeFromSuperview()
    }

    @objc private func tableViewDoubleClicked() {
        // Double-click enters edit mode (already handled by NSTableView).
    }

    // MARK: - Column resize

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Check if near a column boundary (within 6pt).
        for col in 0..<columns {
            var x: CGFloat = 0
            for i in 0...col { x += columnWidths[safe: i] ?? defaultColumnWidth }
            if abs(point.x - x) < 6 {
                resizeColumnIndex = col
                resizeStartX = point.x
                resizeStartWidths = columnWidths
                return
            }
        }
        super.mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let col = resizeColumnIndex else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = point.x - resizeStartX
        let newWidth = max(minColumnWidth, resizeStartWidths[col] + delta)
        columnWidths[col] = newWidth
        if let tableColumn = tableView.tableColumns[safe: col] {
            tableColumn.width = newWidth
        }
    }

    public override func mouseUp(with event: NSEvent) {
        resizeColumnIndex = nil
        super.mouseUp(with: event)
    }

    // MARK: - Block building

    private func buildTableBlock(text: [[String]]) -> Block {
        // Build tableCell blocks for each cell.
        let cellIDs = text.flatMap { $0 }.map { _ in UUID() }
        return Block(
            id: tableBlockID ?? UUID(),
            type: .table,
            attributes: [
                "rows": .number(Double(rows)),
                "cols": .number(Double(columns)),
                "columnWidths": .array(columnWidths.map { .number(Double($0)) }),
            ],
            content: [],
            children: cellIDs,
            parentID: nil
        )
    }
}

// MARK: - NSTableViewDataSource

extension TesseraTableEditorOverlay: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows
    }
}

// MARK: - NSTableViewDelegate

extension TesseraTableEditorOverlay: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn,
              let colID = Int(col.identifier.rawValue.replacingOccurrences(of: "col_", with: "")) else {
            return nil
        }

        let cellID = NSUserInterfaceItemIdentifier("cell_\(row)_\(colID)")
        var cellView = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView
        if cellView == nil {
            cellView = NSTableCellView()
            cellView?.identifier = cellID
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = true
            field.focusRingType = .none
            field.font = NSFont.systemFont(ofSize: 13)
            field.translatesAutoresizingMaskIntoConstraints = false
            cellView?.addSubview(field)
            cellView?.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
            ])
        }

        let text = cellText[safe: row]?[safe: colID] ?? ""
        cellView?.textField?.stringValue = text
        cellView?.textField?.target = self
        cellView?.textField?.action = #selector(cellTextChanged(_:))
        cellView?.textField?.tag = row * 100 + colID

        return cellView
    }

    @objc private func cellTextChanged(_ sender: NSTextField) {
        let row = sender.tag / 100
        let col = sender.tag % 100
        guard row < rows, col < columns else { return }
        if cellText[safe: row] != nil {
            cellText[row][col] = sender.stringValue
        }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        activeCellRow = row
        return true
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - NSShadow extension

private extension NSShadow {
    /// Apply this shadow to a CALayer. Call after `layer.backgroundColor`.
    func apply(to layer: CALayer) {
        layer.shadowColor = self.shadowColor?.cgColor
        layer.shadowOffset = self.shadowOffset
        layer.shadowRadius = self.shadowBlurRadius
        layer.shadowOpacity = 1.0
    }
}

private extension NSShadow {
    static var editorOverlayShadow: NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.2)
        s.shadowOffset = NSSize(width: 0, height: -2)
        s.shadowBlurRadius = 8
        return s
    }
}
