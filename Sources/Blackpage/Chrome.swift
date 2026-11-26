import AppKit

enum Theme {
    static let text = MarkdownStyler.offWhite
    static let accent = NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.22, alpha: 1)
    static let dim = NSColor(white: 0.55, alpha: 1)
}

/// Window content view. Reports mouse movement (reveals the status line in
/// zen mode) and resizes, so the sidebar and editor can be laid out by hand.
final class RootView: NSView {
    var onMouseMoved: (() -> Void)?
    var onResize: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?() }

    override func resizeSubviews(withOldSize old: NSSize) {
        super.resizeSubviews(withOldSize: old)
        onResize?()
    }
}

/// The ⌘/ cheat sheet. Any key closes it.
final class ShortcutsView: NSView {
    typealias Section = (String, [(String, String)])

    static let left: [Section] = [
        ("Find", [
            ("⌘K", "Commands"),
            ("⌘P", "Find file"),
            ("⌘F", "Search this document"),
            ("⌥⌘F", "Find and replace"),
            ("⌘E", "File browser"),
            ("⇧⌘O", "Pick browser folder"),
            ("⌘K history", "Restore an older version"),
            ("⌘K replay", "Watch this piece being written"),
        ]),
        ("Write", [
            ("⌘B  ⌘I", "Bold, italic"),
            ("⌘'", "Add a note  <!-- like this -->"),
            ("⌘J  ⌥⌘↑ ⌥⌘↓", "Jump to notes"),
            ("tab  ⇧tab", "Indent, outdent list"),
            ("⌘;", "Spell check on/off"),
            ("⌘V on words", "Pasting a URL makes a link"),
            ("right-click", "Spelling suggestions"),
            ("⇧⌘C", "Copy as rich text, no notes"),
            ("⌘K export", "PDF or HTML"),
        ]),
        ("View", [
            ("⌘↩", "Zen mode  (esc leaves)"),
            ("⌘T", "Typewriter scrolling"),
            ("⇧⌘D", "Dim other paragraphs"),
            ("⌘=  ⌘-  ⌘0", "Text size"),
            ("⌃⌘V", "Vim keys on/off"),
            ("⌘/", "This list"),
        ]),
    ]
    static let right: [Section] = [
        ("Vim  (orange caret = normal mode)", [
            ("h j k l", "Move"),
            ("w b e", "Word"),
            ("( )  { }", "Sentence, paragraph"),
            ("0 ^ $  gg G", "Line, document"),
            ("i a I A o O", "Insert"),
            ("x  dd  D", "Delete"),
            ("ciw  cis  cc", "Change word, sentence, line"),
            ("yy  p  P", "Copy, paste"),
            (">>  <<", "Indent, outdent"),
            ("u  ⌃R", "Undo, redo"),
            ("v", "Select"),
            ("/  n  N", "Exact search"),
        ]),
        ("Pickers and file browser", [
            ("⌃J ⌃K  ⌃N ⌃P", "Move (arrows work too)"),
            ("↩  esc", "Open, close"),
            ("j k  l  h", "Browser: move, open, collapse"),
        ]),
    ]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.97).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.16, alpha: 1).cgColor

        let stack = NSStackView(views: [column(Self.left), column(Self.right)])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 40
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func column(_ sections: [Section]) -> NSView {
        let p = NSMutableParagraphStyle()
        p.tabStops = [NSTextTab(textAlignment: .left, location: 112)]
        p.lineSpacing = 5
        let s = NSMutableAttributedString()
        for (si, (title, rows)) in sections.enumerated() {
            if si > 0 { s.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])) }
            s.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor(white: 0.45, alpha: 1),
                .paragraphStyle: p,
            ]))
            for (i, (key, what)) in rows.enumerated() {
                s.append(NSAttributedString(string: key, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: Theme.text,
                    .paragraphStyle: p,
                ]))
                s.append(NSAttributedString(string: "\t" + what + (i == rows.count - 1 ? "" : "\n"), attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: Theme.dim,
                    .paragraphStyle: p,
                ]))
            }
        }
        return NSTextField(labelWithAttributedString: s)
    }
}
