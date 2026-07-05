import SwiftUI
import AppKit

/// One column: a header title, a width, an ascending comparator, and closures
/// for a row's text and text color. Cells are just drawn text.
struct RowColumn: Identifiable {
    let id: String
    let title: String
    let width: CGFloat        // fixed; the first column flexes to fill slack
    let mono: Bool
    let bold: Bool
    let text: (ResourceRow) -> String
    let color: (ResourceRow) -> NSColor
    let less: (ResourceRow, ResourceRow) -> Bool

    init(id: String, title: String, width: CGFloat, mono: Bool = false, bold: Bool = false,
         text: @escaping (ResourceRow) -> String,
         color: @escaping (ResourceRow) -> NSColor = { _ in .secondaryLabelColor },
         less: @escaping (ResourceRow, ResourceRow) -> Bool) {
        self.id = id; self.title = title; self.width = width; self.mono = mono; self.bold = bold
        self.text = text; self.color = color; self.less = less
    }
}

private let rowHeight: CGFloat = 22
private let headerHeight: CGFloat = 24
private let cellPadX: CGFloat = 8

/// Column geometry shared by header and rows so they line up. The first column
/// flexes to fill leftover width; the rest keep their fixed widths.
private func columnFrames(_ columns: [RowColumn], width: CGFloat) -> [(col: RowColumn, x: CGFloat, w: CGFloat)] {
    guard !columns.isEmpty else { return [] }
    let fixed = columns.dropFirst().reduce(0) { $0 + $1.width }
    var out: [(RowColumn, CGFloat, CGFloat)] = []
    var x: CGFloat = 0
    for (i, col) in columns.enumerated() {
        let w = i == 0 ? max(160, width - fixed) : col.width
        out.append((col, x, w))
        x += w
    }
    return out
}

// Cache fonts and the paragraph style once instead of rebuilding them for every
// cell on every redraw (the draw loop runs ~columns×visibleRows times).
// Immutable shared instances, only ever read on the main thread during draw.
private let sz = NSFont.systemFontSize
nonisolated(unsafe) private let fontRegular = NSFont.systemFont(ofSize: sz)
nonisolated(unsafe) private let fontMedium = NSFont.systemFont(ofSize: sz, weight: .medium)
nonisolated(unsafe) private let fontMono = NSFont.monospacedDigitSystemFont(ofSize: sz, weight: .regular)
nonisolated(unsafe) private let fontMonoMedium = NSFont.monospacedDigitSystemFont(ofSize: sz, weight: .medium)
nonisolated(unsafe) private let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
nonisolated(unsafe) private let truncatingParagraph: NSParagraphStyle = {
    let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p
}()

private func cellFont(mono: Bool, bold: Bool) -> NSFont {
    switch (mono, bold) {
    case (true, true): return fontMonoMedium
    case (true, false): return fontMono
    case (false, true): return fontMedium
    case (false, false): return fontRegular
    }
}

private func drawText(_ s: String, in rect: NSRect, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: truncatingParagraph]
    let textH = font.ascender - font.descender
    let y = rect.minY + (rect.height - textH) / 2
    (s as NSString).draw(in: NSRect(x: rect.minX, y: y, width: rect.width, height: textH), withAttributes: attrs)
}

/// A table we draw ourselves — no cell views, no reuse, no Auto Layout. Sorting
/// is just: re-sort the array and `setNeedsDisplay`, i.e. one draw pass. Nothing
/// here touches SwiftUI's layout, which is what kept NSTableView slow.
struct ResourceTableView: NSViewRepresentable {
    let rows: [ResourceRow]
    let columns: [RowColumn]
    @Binding var selection: String?
    var defaultDescending = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Container {
        let c = Container()
        c.coordinator = context.coordinator
        context.coordinator.container = c
        context.coordinator.configure(columns: columns, defaultDescending: defaultDescending)
        context.coordinator.setRows(rows)
        context.coordinator.setSelection(selection)
        return c
    }

    func updateNSView(_ c: Container, context: Context) {
        context.coordinator.parent = self
        context.coordinator.configure(columns: columns, defaultDescending: defaultDescending)
        context.coordinator.setRows(rows)
        context.coordinator.setSelection(selection)
    }

    @MainActor
    final class Coordinator {
        var parent: ResourceTableView
        weak var container: Container?
        private var columns: [RowColumn] = []
        private var sortColumn = ""
        private var ascending = true
        private var sorted: [ResourceRow] = []

        init(_ parent: ResourceTableView) { self.parent = parent }

        func configure(columns: [RowColumn], defaultDescending: Bool) {
            guard columns.map(\.id) != self.columns.map(\.id) else {
                self.columns = columns; return   // same shape, keep sort
            }
            self.columns = columns
            sortColumn = columns.first?.id ?? ""
            ascending = !defaultDescending
            container?.columns = columns
            container?.sortColumn = sortColumn
            container?.ascending = ascending
        }

        func setRows(_ rows: [ResourceRow]) {
            let s = sortRows(rows)
            guard s != sorted else { return }   // Equatable — skip redundant reloads
            sorted = s
            container?.setRows(s)
        }

        func setSelection(_ id: String?) { container?.setSelection(id) }

        private func sortRows(_ rows: [ResourceRow]) -> [ResourceRow] {
            guard let col = columns.first(where: { $0.id == sortColumn }) ?? columns.first else { return rows }
            return rows.sorted { ascending ? col.less($0, $1) : col.less($1, $0) }
        }

        // Called by the header on a click.
        func toggleSort(columnID: String) {
            if sortColumn == columnID { ascending.toggle() } else { sortColumn = columnID; ascending = true }
            container?.sortColumn = sortColumn
            container?.ascending = ascending
            sorted = sortRows(sorted)
            container?.setRows(sorted)
            container?.header.needsDisplay = true
        }

        // Called by the rows view on a click.
        func selectRow(id: String?) {
            if parent.selection != id { parent.selection = id }
            container?.setSelection(id)
        }
    }

    // MARK: - Native views

    final class Container: NSView {
        weak var coordinator: Coordinator?
        let header = HeaderView()
        let rowsView = RowsView()
        private let scroll = NSScrollView()

        var columns: [RowColumn] = [] { didSet { header.columns = columns; rowsView.columns = columns } }
        var sortColumn = "" { didSet { header.sortColumn = sortColumn } }
        var ascending = true { didSet { header.ascending = ascending } }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            header.container = self
            rowsView.container = self
            scroll.documentView = rowsView
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            addSubview(header)
            addSubview(scroll)
        }
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
            scroll.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: bounds.height - headerHeight)
            sizeRows()
        }

        func setRows(_ rows: [ResourceRow]) {
            rowsView.rows = rows
            sizeRows()
            rowsView.needsDisplay = true
        }

        func setSelection(_ id: String?) {
            guard rowsView.selectedID != id else { return }
            rowsView.selectedID = id
            rowsView.needsDisplay = true
        }

        private func sizeRows() {
            let w = scroll.contentSize.width
            let h = max(scroll.contentSize.height, CGFloat(rowsView.rows.count) * rowHeight)
            rowsView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        }
    }

    final class HeaderView: NSView {
        weak var container: Container?
        var columns: [RowColumn] = []
        var sortColumn = ""
        var ascending = true
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            let font = headerFont
            for (col, x, w) in columnFrames(columns, width: bounds.width) {
                var title = col.title
                if col.id == sortColumn { title += ascending ? "  ▲" : "  ▼" }
                drawText(title, in: NSRect(x: x + cellPadX, y: 0, width: w - cellPadX - 4, height: bounds.height),
                         font: font, color: .secondaryLabelColor)
            }
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }

        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            for (col, x, w) in columnFrames(columns, width: bounds.width) where p.x >= x && p.x < x + w {
                container?.coordinator?.toggleSort(columnID: col.id)
                return
            }
        }
    }

    final class RowsView: NSView {
        weak var container: Container?
        var rows: [ResourceRow] = []
        var columns: [RowColumn] = []
        var selectedID: String?
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let cols = columnFrames(columns, width: bounds.width)
            let stripe = NSColor.alternatingContentBackgroundColors
            let first = max(0, Int(dirtyRect.minY / rowHeight))
            let last = min(rows.count, Int(ceil(dirtyRect.maxY / rowHeight)))
            guard first < last else { return }
            for i in first..<last {
                let y = CGFloat(i) * rowHeight
                let row = rows[i]
                let selected = row.id == selectedID
                if selected {
                    NSColor.selectedContentBackgroundColor.setFill()
                    NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
                } else if i % 2 == 1, stripe.count > 1 {
                    stripe[1].setFill()
                    NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
                }
                for (col, x, w) in cols {
                    let color = selected ? NSColor.alternateSelectedControlTextColor : col.color(row)
                    drawText(col.text(row),
                             in: NSRect(x: x + cellPadX, y: y, width: w - cellPadX - 4, height: rowHeight),
                             font: cellFont(mono: col.mono, bold: col.bold), color: color)
                }
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)   // take key focus for arrow nav
            let p = convert(event.locationInWindow, from: nil)
            let i = Int(p.y / rowHeight)
            guard i >= 0, i < rows.count else { return }
            container?.coordinator?.selectRow(id: rows[i].id)
        }

        // Arrow-key row navigation.
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard !rows.isEmpty else { return super.keyDown(with: event) }
            let current = rows.firstIndex { $0.id == selectedID }
            let next: Int
            switch event.keyCode {
            case 126: next = (current ?? 0) - 1        // up arrow
            case 125: next = (current ?? -1) + 1       // down arrow
            default: return super.keyDown(with: event)
            }
            let clamped = max(0, min(rows.count - 1, next))
            container?.coordinator?.selectRow(id: rows[clamped].id)
            scrollToVisible(NSRect(x: 0, y: CGFloat(clamped) * rowHeight, width: bounds.width, height: rowHeight))
        }
    }
}
