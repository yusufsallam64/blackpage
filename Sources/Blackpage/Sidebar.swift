import AppKit

enum Files {
    static let textExts: Set<String> = ["md", "markdown", "txt"]
    static let skipDirs: Set<String> = ["node_modules", "build", "dist", "Pods", "DerivedData", "target",
                                        "vendor", "venv", "__pycache__", "Library"]

    /// Text files under `root`, newest first. Capped so a huge folder can't hang it.
    static func scan(_ root: URL, limit: Int = 5000) -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [(URL, Date)] = []
        var visited = 0
        for case let u as URL in en {
            visited += 1
            if visited > 60_000 || out.count >= limit { break }
            if skipDirs.contains(u.lastPathComponent) || en.level > 8 { en.skipDescendants(); continue }
            guard textExts.contains(u.pathExtension.lowercased()) else { continue }
            let d = (try? u.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            out.append((u, d))
        }
        return out.sorted { $0.1 > $1.1 }
    }
}

final class FileNode: NSObject {
    let url: URL
    let isDir: Bool
    private var cached: [FileNode]?

    init(url: URL, isDir: Bool) {
        self.url = url
        self.isDir = isDir
    }

    var name: String {
        url.pathExtension.lowercased() == "md" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    var children: [FileNode] {
        if cached == nil { cached = FileNode.list(url) }
        return cached!
    }

    private static func list(_ dir: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [FileNode] = []
        for u in urls {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true && v?.isPackage != true {
                if !Files.skipDirs.contains(u.lastPathComponent) { out.append(FileNode(url: u, isDir: true)) }
            } else if Files.textExts.contains(u.pathExtension.lowercased()) {
                out.append(FileNode(url: u, isDir: false))
            }
        }
        return out.sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }
}

/// Outline with NERDTree-ish keys: j/k move, l/o/return open, h collapse.
final class FileOutlineView: NSOutlineView {
    var onActivate: ((FileNode) -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch (e.keyCode, e.charactersIgnoringModifiers ?? "") {
            case (53, _): onEscape?(); return
            case (36, _), (_, "l"), (_, "o"): activateSelected(); return
            case (_, "j"): step(1); return
            case (_, "k"): step(-1); return
            case (_, "h"): collapseOrParent(); return
            default: break
            }
        }
        super.keyDown(with: e)
    }

    func select(row r: Int) {
        guard r >= 0 && r < numberOfRows else { return }
        selectRowIndexes([r], byExtendingSelection: false)
        scrollRowToVisible(r)
    }

    private func step(_ d: Int) {
        guard numberOfRows > 0 else { return }
        select(row: max(0, min(numberOfRows - 1, selectedRow + d)))
    }

    func activateSelected() {
        guard let n = item(atRow: selectedRow) as? FileNode else { return }
        if n.isDir {
            isItemExpanded(n) ? collapseItem(n) : expandItem(n)
        } else {
            onActivate?(n)
        }
    }

    private func collapseOrParent() {
        guard let n = item(atRow: selectedRow) as? FileNode else { return }
        if n.isDir && isItemExpanded(n) {
            collapseItem(n)
        } else if let p = parent(forItem: n) {
            select(row: row(forItem: p))
        }
    }
}

private final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}

final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = FileOutlineView()
    var onOpen: ((URL) -> Void)?
    var onEscape: (() -> Void)? { didSet { outline.onEscape = onEscape } }
    var current: URL?
    private(set) var root: URL?

    private let header = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let separator = NSView()
    private var rootNode: FileNode?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        header.font = .systemFont(ofSize: 10.5, weight: .semibold)
        header.textColor = NSColor(white: 0.36, alpha: 1)
        header.lineBreakMode = .byTruncatingMiddle

        let col = NSTableColumn(identifier: .init("name"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 24
        outline.indentationPerLevel = 12
        outline.style = .plain
        outline.focusRingType = .none
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.onActivate = { [weak self] n in self?.onOpen?(n.url) }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = outline

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor

        [header, scroll, separator].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        header.frame = NSRect(x: 16, y: size.height - 56, width: size.width - 28, height: 14)
        scroll.frame = NSRect(x: 0, y: 34, width: size.width - 1, height: max(0, size.height - 98))
        separator.frame = NSRect(x: size.width - 1, y: 0, width: 1, height: size.height)
    }

    /// Re-read the folder from disk and show `current` in the tree.
    func reload(root newRoot: URL) {
        root = newRoot
        rootNode = FileNode(url: newRoot, isDir: true)
        header.stringValue = newRoot.lastPathComponent.uppercased()
        outline.reloadData()
        reveal(current)
    }

    func reveal(_ url: URL?) {
        guard let url, let root, let rootNode else { return }
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return }
        var node = rootNode
        for comp in path.dropFirst(rootPath.count + 1).split(separator: "/") {
            guard let child = node.children.first(where: { $0.url.lastPathComponent == comp }) else { return }
            if child.isDir { outline.expandItem(child) }
            node = child
        }
        outline.select(row: outline.row(forItem: node))
    }

    @objc private func clicked() {
        guard outline.clickedRow >= 0 else { return }
        outline.select(row: outline.clickedRow)
        outline.activateSelected()
    }

    // MARK: Data source / delegate

    private func node(_ item: Any?) -> FileNode? { item == nil ? rootNode : item as? FileNode }

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item)?.children.count ?? 0
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item)!.children[index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDir ?? false
    }

    func outlineView(_ ov: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }

    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let c = ov.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = c
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let isCurrent = n.url.standardizedFileURL == current?.standardizedFileURL
        cell.textField?.stringValue = n.name
        cell.textField?.font = .systemFont(ofSize: 12.5, weight: isCurrent ? .semibold : .regular)
        cell.textField?.textColor = isCurrent ? Theme.text : NSColor(white: n.isDir ? 0.42 : 0.62, alpha: 1)
        return cell
    }
}
