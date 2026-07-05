import SwiftUI
import AppKit

/// One column of ``ResourceTableView``. Cells are plain text (with a color and
/// optional monospacing) so they render as native `NSTextField`s — no per-cell
/// SwiftUI hosting view, which is what makes SwiftUI `Table` slow on macOS.
struct RowColumn: Identifiable {
    let id: String
    let title: String
    let width: CGFloat
    let mono: Bool
    let bold: Bool
    let text: (ResourceRow) -> String
    let color: (ResourceRow) -> NSColor
    let less: (ResourceRow, ResourceRow) -> Bool   // ascending comparator

    init(id: String, title: String, width: CGFloat, mono: Bool = false, bold: Bool = false,
         text: @escaping (ResourceRow) -> String,
         color: @escaping (ResourceRow) -> NSColor = { _ in .secondaryLabelColor },
         less: @escaping (ResourceRow, ResourceRow) -> Bool) {
        self.id = id; self.title = title; self.width = width; self.mono = mono; self.bold = bold
        self.text = text; self.color = color; self.less = less
    }
}

/// A fast, native `NSTableView` wrapped for SwiftUI. Handles sorting (header
/// clicks), single-row selection, and live data updates. Used instead of
/// SwiftUI `Table`, whose per-cell hosting views and AttributeGraph diffing
/// make wide tables slow to sort on macOS.
struct ResourceTableView: NSViewRepresentable {
    let rows: [ResourceRow]
    let columns: [RowColumn]
    @Binding var selection: String?
    var defaultDescending = false   // events sort newest-first by their first column

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 12, height: 2)
        // Name (first column) stretches to fill slack; overflow scrolls.
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.usesAutomaticRowHeights = false
        context.coordinator.configureColumns(table, columns: columns)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        context.coordinator.apply(rows: rows)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = context.coordinator.table else { return }
        // Rebuild columns only if the set actually changed (type switch).
        if context.coordinator.columnIDs != columns.map(\.id) {
            context.coordinator.configureColumns(table, columns: columns)
        }
        context.coordinator.apply(rows: rows)
        context.coordinator.syncSelection()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: ResourceTableView
        weak var table: NSTableView?
        private(set) var columnIDs: [String] = []
        private var columnsByID: [String: RowColumn] = [:]
        private var sorted: [ResourceRow] = []
        private var applyingSelection = false

        init(_ parent: ResourceTableView) { self.parent = parent }

        func configureColumns(_ table: NSTableView, columns: [RowColumn]) {
            for col in table.tableColumns { table.removeTableColumn(col) }
            columnsByID = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
            columnIDs = columns.map(\.id)
            for col in columns {
                let c = NSTableColumn(identifier: .init(col.id))
                c.title = col.title
                c.width = col.width
                c.minWidth = 40
                c.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: true)
                table.addTableColumn(c)
            }
            // Default sort: first column (ascending, or descending for events).
            if let first = columns.first {
                table.sortDescriptors = [NSSortDescriptor(key: first.id, ascending: !parent.defaultDescending)]
            }
        }

        /// Re-sort by the table's current descriptor and reload — but only when
        /// the data actually changed, so an idle auto-refresh doesn't thrash.
        func apply(rows: [ResourceRow]) {
            let newSorted = sort(rows, by: table?.sortDescriptors ?? [])
            guard newSorted != sorted else { return }
            sorted = newSorted
            table?.reloadData()
            syncSelection()
        }

        private func sort(_ rows: [ResourceRow], by descriptors: [NSSortDescriptor]) -> [ResourceRow] {
            guard let d = descriptors.first, let key = d.key, let col = columnsByID[key] else { return rows }
            return rows.sorted { d.ascending ? col.less($0, $1) : col.less($1, $0) }
        }

        func syncSelection() {
            guard let table else { return }
            let target = parent.selection
            let row = target.flatMap { id in sorted.firstIndex { $0.id == id } }
            applyingSelection = true
            if let row {
                if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
            } else {
                table.deselectAll(nil)
            }
            applyingSelection = false
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { sorted.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let col = columnsByID[tableColumn.identifier.rawValue],
                  row < sorted.count else { return nil }
            let id = tableColumn.identifier
            // Return a bare, reused NSTextField — no NSTableCellView wrapper and
            // no Auto Layout. Wiring constraints per cell made the NSISEngine
            // solver run for every visible row on every layout pass (the sort
            // hang in profiling); frame-based reused labels are the fast path.
            let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
                ?? Self.makeLabel(id)
            let item = sorted[row]
            field.stringValue = col.text(item)
            field.textColor = col.color(item)
            field.font = col.mono
                ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: col.bold ? .medium : .regular)
                : .systemFont(ofSize: NSFont.systemFontSize, weight: col.bold ? .medium : .regular)
            return field
        }

        private static func makeLabel(_ id: NSUserInterfaceItemIdentifier) -> NSTextField {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
            return field
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            sorted = sort(sorted, by: tableView.sortDescriptors)
            tableView.reloadData()
            syncSelection()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let row = table.selectedRow
            let newID = (row >= 0 && row < sorted.count) ? sorted[row].id : nil
            if parent.selection != newID { parent.selection = newID }
        }
    }
}
