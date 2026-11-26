import AppKit

enum VimMode { case insert, normal, visual }

/// The editor surface: typewriter scrolling, paragraph focus dimming,
/// pointer hiding while typing, and an optional vim layer (Vim.swift).
final class ZenTextView: NSTextView {
    var onEscape: (() -> Void)?
    /// Sees every key first; return true to swallow it.
    var interceptKey: ((NSEvent) -> Bool)?

    var typewriter = true { didSet { if typewriter { centerCaret() } } }
    var focusParagraph = false { didSet { updateFocusDim() } }
    var smartPunctuation = false

    // vim state (used by Vim.swift)
    var vimEnabled = false {
        didSet {
            setMode(vimEnabled ? .normal : .insert)
            if vimEnabled { clampNormal() }
        }
    }
    private(set) var mode: VimMode = .insert
    var pending = ""
    var pendingCount = 1
    var count = ""
    var register = ""
    var registerLinewise = false
    var visualAnchor = 0
    var visualHead = 0
    var goalX: CGFloat?

    let caretInsert = MarkdownStyler.offWhite
    let caretNormal = NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.22, alpha: 1)
    let dimColor = NSColor(white: 0.26, alpha: 1)

    var ns: NSString { string as NSString }

    /// Where the "cursor" is: the visual head in visual mode, else the caret.
    var cursor: Int { mode == .visual ? visualHead : selectedRange().location }

    func setMode(_ m: VimMode) {
        mode = m
        pending = ""
        pendingCount = 1
        count = ""
        breakUndoCoalescing()
        insertionPointColor = (m == .insert) ? caretInsert : caretNormal
        updateInsertionPointStateAndRestartTimer(true)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        if interceptKey?(event) == true { return }
        let isEsc = event.keyCode == 53
            || (event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "[")

        guard vimEnabled else {
            if isEsc, let onEscape { onEscape(); return }
            super.keyDown(with: event)
            return
        }
        switch mode {
        case .insert:
            if isEsc { leaveInsert(); return }
            super.keyDown(with: event)
        case .normal, .visual:
            if isEsc { escapeNormal(); return }
            if (123...126).contains(event.keyCode) && mode == .normal {
                super.keyDown(with: event)  // arrow keys
                return
            }
            handleVimEvent(event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .visual { setMode(.normal) }
        super.mouseDown(with: event)
    }

    // MARK: Markdown editing (Editing.swift)

    override func insertNewline(_ sender: Any?) {
        if !continueList() { super.insertNewline(sender) }
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        if ns.substring(with: sel).contains("\n") || caretOnListLine() {
            shiftLines(by: 1)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(by: -1) }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if smartPunctuation, replacementRange.location == NSNotFound, !hasMarkedText(),
           let s = string as? String, let (r, out) = smarten(s) {
            super.insertText(out, replacementRange: r)
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    override func paste(_ sender: Any?) {
        if !pasteLink() { super.paste(sender) }
    }

    // MARK: Typewriter scrolling

    /// Typewriter mode centers the caret; selections and find matches
    /// scroll normally so their moving end stays visible.
    override func scrollRangeToVisible(_ range: NSRange) {
        if typewriter && range.length == 0 { centerCaret() } else { super.scrollRangeToVisible(range) }
    }

    /// Back to normal mode after the text is replaced or jumped around in.
    func resetVim() {
        if vimEnabled { setMode(.normal) }
    }

    private func caretRect(_ at: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let len = ns.length
        let loc = min(at, len)
        lm.ensureLayout(for: tc)  // incremental after edits; ~0.7 ms on a 10k-word essay
        var rect: NSRect
        if len == 0 || (loc >= len && !lm.extraLineFragmentRect.isEmpty) {
            rect = lm.extraLineFragmentRect
        } else {
            let gi = lm.glyphIndexForCharacter(at: min(loc, len - 1))
            rect = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
        }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    private var glideTarget: NSPoint?

    /// Keep the caret line mid-screen. Small moves glide (~0.14s) instead of
    /// snapping a whole line at once; big jumps and Reduce Motion are instant.
    func centerCaret(at loc: Int? = nil, animated: Bool = true) {
        guard typewriter, let sv = enclosingScrollView, let rect = caretRect(loc ?? cursor) else { return }
        let clip = sv.contentView
        let h = clip.bounds.height
        let maxY = max(0, frame.height - h)
        let target = NSPoint(x: clip.bounds.origin.x, y: min(max(0, rect.midY - h / 2), maxY))
        // compare with where a running glide is heading, not where it is mid-flight
        if abs((glideTarget ?? clip.bounds.origin).y - target.y) < 0.5 { return }
        let glide = animated && abs(clip.bounds.origin.y - target.y) < h
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        glideTarget = glide ? target : nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = glide ? 0.14 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(target)
        }, completionHandler: { [weak self] in
            if self?.glideTarget == target { self?.glideTarget = nil }
            sv.reflectScrolledClipView(clip)
        })
    }

    // MARK: Focus dimming

    func updateFocusDim() {
        guard let lm = layoutManager else { return }
        let full = NSRange(location: 0, length: ns.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard focusParagraph, full.length > 0 else { return }
        lm.addTemporaryAttribute(.foregroundColor, value: dimColor, forCharacterRange: full)
        let para = ns.paragraphRange(for: NSRange(location: min(cursor, full.length), length: 0))
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: para)
    }

    // MARK: Editing helpers

    /// Undoable replacement.
    func replace(_ r: NSRange, with s: String) {
        guard shouldChangeText(in: r, replacementString: s) else { return }
        textStorage?.replaceCharacters(in: r, with: s)
        didChangeText()
    }

    func setCursor(_ t: Int) {
        let c = max(0, min(t, ns.length))
        setSelectedRange(NSRange(location: c, length: 0))
        scrollRangeToVisible(NSRange(location: c, length: 0))
    }
}
