import AppKit

struct PickerItem {
    var title: String
    var detail: String = ""
    var matches: [Int] = []
    var action: () -> Void
}

/// Telescope-style floating picker: prompt on top, results under it,
/// centered in the window. Used for ⌘K, ⌘P and ⌘F.
final class PickerView: NSView, NSTextFieldDelegate {
    typealias Filter = (String, [PickerItem]) -> [PickerItem]

    let field = NSTextField()
    var onClose: (() -> Void)?
    var emptyText = "No matches"
    var loading = false { didSet { render() } }

    private let panel = NSView()
    private let prompt = NSTextField(labelWithString: "›")
    private let divider = NSView()
    private let empty = NSTextField(labelWithString: "")
    private var rows: [PickerRow] = []
    private var items: [PickerItem]
    private var shown: [PickerItem] = []
    private var selected = 0
    private var offset = 0
    private let filter: Filter
    private var monitor: Any?

    private let maxRows = 12
    private let rowH: CGFloat = 30
    private let fieldH: CGFloat = 50

    init(placeholder: String, items: [PickerItem], filter: @escaping Filter = PickerView.fuzzyFilter) {
        self.items = items
        self.filter = filter
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.045, alpha: 1).cgColor
        panel.layer?.cornerRadius = 12
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(white: 0.15, alpha: 1).cgColor
        addSubview(panel)

        prompt.font = .systemFont(ofSize: 20)
        prompt.textColor = Theme.accent
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.textColor = Theme.text
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(white: 0.34, alpha: 1), .font: NSFont.systemFont(ofSize: 16),
        ])
        field.delegate = self
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = NSColor(white: 0.38, alpha: 1)
        [prompt, field, divider, empty].forEach(panel.addSubview)

        for i in 0..<maxRows {
            let r = PickerRow()
            r.onClick = { [weak self] in
                guard let self else { return }
                self.selected = self.offset + i
                self.choose()
            }
            rows.append(r)
            panel.addSubview(r)
        }

        // ⌃J ⌃K ⌃N ⌃P move the selection, like telescope
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.superview != nil,
                  e.modifierFlags.intersection([.command, .option, .control]) == .control else { return e }
            switch e.charactersIgnoringModifiers {
            case "j", "n": self.move(1); return nil
            case "k", "p": self.move(-1); return nil
            default: return e
            }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setItems(_ items: [PickerItem]) {
        self.items = items
        loading = false
        refresh()
    }

    // MARK: Filtering

    static func fuzzyFilter(_ q: String, _ items: [PickerItem]) -> [PickerItem] {
        if q.trimmingCharacters(in: .whitespaces).isEmpty { return Array(items.prefix(200)) }
        var scored: [(Int, Int, PickerItem)] = []
        for (i, var it) in items.enumerated() {
            guard let m = Fuzzy.match(q, in: it.title) else { continue }
            it.matches = m.indices
            scored.append((m.score, i, it))
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        return scored.prefix(200).map { $0.2 }
    }

    /// Cut a long line down to a window around the first match.
    static func window(_ s: String, _ idx: [Int], width: Int = 110) -> (String, [Int]) {
        let ns = s as NSString
        guard ns.length > width, let first = idx.first else { return (s, idx) }
        let start = max(0, min(first - 30, ns.length - width))
        let r = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: width))
        let prefix = r.location > 0 ? "…" : ""
        let suffix = NSMaxRange(r) < ns.length ? "…" : ""
        let pl = (prefix as NSString).length
        let shifted = idx.map { $0 - r.location + pl }.filter { $0 >= pl && $0 < pl + r.length }
        return (prefix + ns.substring(with: r) + suffix, shifted)
    }

    private func refresh() {
        shown = filter(field.stringValue, items)
        selected = 0
        offset = 0
        render()
    }

    private func render() {
        if selected < offset { offset = selected }
        if selected >= offset + maxRows { offset = selected - maxRows + 1 }
        for (i, r) in rows.enumerated() {
            let idx = offset + i
            r.isHidden = idx >= shown.count
            if idx < shown.count { r.configure(shown[idx], selected: idx == selected) }
        }
        empty.stringValue = shown.isEmpty ? (loading ? "Scanning…" : emptyText) : ""
        layoutPanel()
    }

    // MARK: Layout

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        layoutPanel()
    }

    private func layoutPanel() {
        let visible = shown.isEmpty ? 1 : min(shown.count, maxRows)
        let ph = fieldH + 1 + CGFloat(visible) * rowH + 12
        let pw = min(680, bounds.width - 40)
        let top = max(bounds.height * 0.8, ph + 20)
        panel.frame = NSRect(x: floor((bounds.width - pw) / 2), y: floor(top - ph), width: pw, height: ph)
        prompt.frame = NSRect(x: 18, y: ph - fieldH + 12, width: 18, height: 26)
        field.frame = NSRect(x: 40, y: ph - fieldH + 14, width: pw - 56, height: 22)
        divider.frame = NSRect(x: 0, y: ph - fieldH - 1, width: pw, height: 1)
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 6, y: ph - fieldH - 1 - 6 - CGFloat(i + 1) * rowH, width: pw - 12, height: rowH)
        }
        empty.frame = NSRect(x: 20, y: ph - fieldH - 1 - 6 - rowH + 6, width: pw - 40, height: 18)
    }

    // MARK: Keys

    func controlTextDidChange(_ n: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        selected = max(0, min(shown.count - 1, selected + d))
        render()
    }

    private func choose() {
        guard selected < shown.count else { return }
        let action = shown[selected].action
        close()
        action()
    }

    func close() {
        guard superview != nil else { return }
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        removeFromSuperview()
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { close() }
    }
}

final class PickerRow: NSView {
    var onClick: (() -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        title.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = NSColor(white: 0.36, alpha: 1)
        detail.lineBreakMode = .byTruncatingHead
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ it: PickerItem, selected: Bool) {
        layer?.backgroundColor = selected ? NSColor(white: 0.13, alpha: 1).cgColor : NSColor.clear.cgColor
        let font = NSFont.systemFont(ofSize: 13.5)
        let s = NSMutableAttributedString(string: it.title, attributes: [
            .font: font, .foregroundColor: selected ? Theme.text : NSColor(white: 0.62, alpha: 1),
        ])
        let len = (it.title as NSString).length
        for i in it.matches where i >= 0 && i < len {
            s.addAttributes([.foregroundColor: Theme.accent, .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)],
                            range: NSRange(location: i, length: 1))
        }
        title.attributedStringValue = s
        detail.stringValue = it.detail
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let dw: CGFloat = 140
        title.frame = NSRect(x: 12, y: 6, width: size.width - 24 - dw, height: 18)
        detail.frame = NSRect(x: size.width - dw - 10, y: 7, width: dw, height: 16)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
