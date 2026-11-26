import AppKit

/// A small vim layer tuned for prose. j/k move by visual (wrapped) line,
/// a "line" for d/y/c is a paragraph, apostrophes count as word characters.
///
/// Normal: h j k l w b e 0 ^ $ gg G { } ( ) Return, counts,
///         i a I A o O, x X s S D C J r, p P, u Ctrl-R, v, / n N
/// Operators: d c y with motions, dd cc yy, text objects iw aw is as ip ap
/// Visual: motions, d x y c s o
extension ZenTextView {

    // MARK: Character classes and line bounds

    func isNewline(_ i: Int) -> Bool {
        let c = ns.character(at: i)
        return c == 10 || c == 13
    }

    /// 0 = whitespace, 1 = word, 2 = punctuation
    func cls(_ i: Int) -> Int {
        let c = ns.character(at: i)
        guard let u = Unicode.Scalar(c) else { return 1 }
        if CharacterSet.whitespacesAndNewlines.contains(u) { return 0 }
        if CharacterSet.alphanumerics.contains(u) || c == 95 || c == 39 || c == 0x2019 { return 1 }
        return 2
    }

    func lineRange(_ p: Int) -> NSRange {
        ns.lineRange(for: NSRange(location: min(max(p, 0), ns.length), length: 0))
    }

    func lineStart(_ p: Int) -> Int { lineRange(p).location }

    /// End of the line, excluding the newline.
    func lineEnd(_ p: Int) -> Int {
        let r = lineRange(p)
        var e = NSMaxRange(r)
        while e > r.location && isNewline(e - 1) { e -= 1 }
        return e
    }

    /// Start of the last character on the line (never splits emoji etc.).
    func lastCharPos(_ p: Int) -> Int {
        let s = lineStart(p), e = lineEnd(p)
        return e > s ? ns.rangeOfComposedCharacterSequence(at: e - 1).location : s
    }

    func nextChar(_ p: Int) -> Int {
        p < ns.length ? NSMaxRange(ns.rangeOfComposedCharacterSequence(at: p)) : p
    }

    func prevChar(_ p: Int) -> Int {
        p > 0 ? ns.rangeOfComposedCharacterSequence(at: p - 1).location : 0
    }

    /// Range covering n characters from p, stopping at the end of the line.
    func charsRange(_ p: Int, _ n: Int) -> NSRange {
        let e = lineEnd(p)
        var t = p
        for _ in 0..<n where t < e { t = nextChar(t) }
        return NSRange(location: p, length: min(t, e) - p)
    }

    func firstNonBlank(_ p: Int) -> Int {
        var i = lineStart(p)
        let e = lineEnd(p)
        while i < e && cls(i) == 0 { i += 1 }
        return i
    }

    /// Normal mode keeps the cursor on a character, not past the end of the line.
    func clampNormal() {
        guard mode == .normal else { return }
        let p = selectedRange().location
        let s = lineStart(p), e = lineEnd(p)
        if p >= e && e > s { setCursor(lastCharPos(p)) }
        else if selectedRange().length > 0 { setCursor(p) }
    }

    // MARK: Mode changes

    func leaveInsert() {
        let p = selectedRange().location
        setMode(.normal)
        if p > lineStart(p) { setCursor(prevChar(p)) } else { setCursor(p) }
    }

    func escapeNormal() {
        if mode == .visual {
            let h = visualHead
            setMode(.normal)
            setCursor(h)
            clampNormal()
        } else {
            pending = ""; pendingCount = 1; count = ""
        }
    }

    var visualRange: NSRange {
        let len = ns.length
        let a = min(min(visualAnchor, visualHead), len)
        let hi = min(max(visualAnchor, visualHead), len)
        let b = hi < len ? nextChar(hi) : len
        return NSRange(location: a, length: max(0, b - a))
    }

    func updateVisual() {
        setSelectedRange(visualRange)
        scrollRangeToVisible(NSRange(location: visualHead, length: 0))
    }

    func move(to t: Int) {
        if mode == .visual {
            visualHead = max(0, min(t, max(0, ns.length - 1)))
            updateVisual()
        } else {
            setCursor(t)
            clampNormal()
        }
    }

    // MARK: Dispatch

    func handleVimEvent(_ event: NSEvent) {
        let mods = event.modifierFlags
        if mods.contains(.command) { super.keyDown(with: event); return }
        if mods.contains(.control) {
            if event.charactersIgnoringModifiers == "r" {
                undoManager?.redo()
                clampNormal()
            }
            return
        }
        if pending == "r" {
            pending = ""
            let p = cursor
            let special: Set<UInt16> = [36, 48, 51, 117, 123, 124, 125, 126]
            if let c = event.characters, !c.isEmpty, !special.contains(event.keyCode), p < lineEnd(p) {
                replace(charsRange(p, 1), with: c)
                setCursor(p)
            }
            return
        }
        if mode == .normal && selectedRange().length > 0 {
            // e.g. a match left selected by find: vim keys act from its start
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        }
        guard var k = event.characters, !k.isEmpty else { return }
        switch event.keyCode {
        case 36: k = "\r"   // Return
        case 51: k = "h"    // Backspace
        case 123: k = "h"; case 124: k = "l"; case 125: k = "j"; case 126: k = "k"
        default: break
        }
        handle(k)
    }

    private func handle(_ k: String) {
        if let d = k.first, k.count == 1, d.isASCII, d.isNumber, d != "0" || !count.isEmpty {
            count.append(d)
            return
        }
        let n = max(1, (Int(count) ?? 1) * pendingCount)
        count = ""
        if k != "j" && k != "k" { goalX = nil }

        if pending == "g" {
            pending = ""; pendingCount = 1
            if k == "g" { move(to: 0) }
            return
        }
        if ["d", "c", "y"].contains(pending) {
            let op = pending
            if k == "i" || k == "a" || k == "g" { pending = op + k; pendingCount = n; return }
            pending = ""; pendingCount = 1
            let p = cursor
            if k == op { linewise(op, count: n); return }
            if k == "G" {
                let s = lineStart(p)
                applyLinewise(op, NSRange(location: s, length: ns.length - s))
                return
            }
            var motion = k
            var count = n
            if op == "c" && k == "w" && p < ns.length && cls(p) != 0 {
                // vim: cw acts like ce; on the last letter of a word it changes just that letter
                let atWordEnd = nextChar(p) >= ns.length || cls(nextChar(p)) != cls(p)
                if atWordEnd && n == 1 { apply(op, charsRange(p, 1), linewise: false); return }
                motion = "e"
                if atWordEnd { count = n - 1 }
            }
            if let r = operatorRange(motion, from: p, count: count) { apply(op, r, linewise: false) }
            return
        }
        if pending == ">" || pending == "<" {
            let key = pending
            pending = ""; pendingCount = 1
            if k == key {
                setSelectedRange(NSRange(location: cursor, length: 0))
                for _ in 0..<n { shiftLines(by: key == ">" ? 1 : -1) }
                clampNormal()
            }
            return
        }
        if pending.count == 2 && pending.hasSuffix("g") {
            let op = String(pending.prefix(1))
            pending = ""; pendingCount = 1
            if k == "g" { applyLinewise(op, NSRange(location: 0, length: NSMaxRange(lineRange(cursor)))) }
            return
        }
        if pending.count == 2 {
            let op = String(pending.prefix(1))
            let inner = pending.hasSuffix("i")
            pending = ""; pendingCount = 1
            if let r = textObject(k, at: cursor, inner: inner) { apply(op, r, linewise: false) }
            return
        }
        if mode == .visual { visualKey(k, n) } else { normalKey(k, n) }
    }

    private func normalKey(_ k: String, _ n: Int) {
        let p = cursor
        switch k {
        case "d", "c", "y":
            pending = k; pendingCount = n
        case "g": pending = "g"; pendingCount = n
        case ">", "<": pending = k; pendingCount = n
        case "r": pending = "r"
        case "i": setCursor(p); setMode(.insert)
        case "a": setCursor(p < lineEnd(p) ? nextChar(p) : p); setMode(.insert)
        case "I": setCursor(firstNonBlank(p)); setMode(.insert)
        case "A": setCursor(lineEnd(p)); setMode(.insert)
        case "o":
            let e = lineEnd(p)
            replace(NSRange(location: e, length: 0), with: "\n")
            setCursor(e + 1); setMode(.insert)
        case "O":
            let s = lineStart(p)
            replace(NSRange(location: s, length: 0), with: "\n")
            setCursor(s); setMode(.insert)
        case "x":
            if p < lineEnd(p) { apply("d", charsRange(p, n), linewise: false) }
        case "X":
            let s = lineStart(p)
            var a = p
            for _ in 0..<n where a > s { a = prevChar(a) }
            if a < p { apply("d", NSRange(location: a, length: p - a), linewise: false) }
        case "s": apply("c", charsRange(p, n), linewise: false)
        case "S": linewise("c", count: n)
        case "D": apply("d", NSRange(location: p, length: lineEnd(p) - p), linewise: false)
        case "C": apply("c", NSRange(location: p, length: lineEnd(p) - p), linewise: false)
        case "p": put(after: true)
        case "P": put(after: false)
        case "J": join()
        case "u":
            for _ in 0..<n { undoManager?.undo() }
            clampNormal()
        case "v":
            visualAnchor = p; visualHead = p
            setMode(.visual); updateVisual()
        case "/": finder(.showFindInterface)
        case "n", "N":
            finder(k == "n" ? .nextMatch : .previousMatch)
            setCursor(selectedRange().location)
        default:
            if let t = motionTarget(k, from: p, count: n) { setCursor(t); clampNormal() }
        }
    }

    private func visualKey(_ k: String, _ n: Int) {
        switch k {
        case "v", "V": escapeNormal()
        case "d", "x": apply("d", visualRange, linewise: false)
        case "y": apply("y", visualRange, linewise: false)
        case "c", "s": apply("c", visualRange, linewise: false)
        case "o": swap(&visualAnchor, &visualHead); updateVisual()
        case ">", "<":
            setSelectedRange(visualRange)
            shiftLines(by: k == ">" ? 1 : -1)
            setMode(.normal)
            setCursor(selectedRange().location)
            clampNormal()
        case "g": pending = "g"; pendingCount = n
        default:
            if let t = motionTarget(k, from: visualHead, count: n) { move(to: t) }
        }
    }

    // MARK: Motions

    func motionTarget(_ k: String, from p: Int, count n: Int) -> Int? {
        let len = ns.length
        switch k {
        case "h":
            let s = lineStart(p)
            var t = p
            for _ in 0..<n where t > s { t = prevChar(t) }
            return t
        case "l", " ":
            let last = lastCharPos(p)
            var t = p
            for _ in 0..<n where t < last { t = nextChar(t) }
            return min(t, last)
        case "j": return verticalMove(from: p, down: true, count: n)
        case "k": return verticalMove(from: p, down: false, count: n)
        case "\r", "+":
            var t = p
            for _ in 0..<n { let e = NSMaxRange(lineRange(t)); if e < len { t = e } }
            return firstNonBlank(t)
        case "w": var t = p; for _ in 0..<n { t = nextWordStart(t) }; return t
        case "b": var t = p; for _ in 0..<n { t = prevWordStart(t) }; return t
        case "e": var t = p; for _ in 0..<n { t = wordEnd(t) }; return t
        case "0": return lineStart(p)
        case "^": return firstNonBlank(p)
        case "$": return lastCharPos(p)
        case "G": return firstNonBlank(len)
        case "}":
            var t = p
            for _ in 0..<n { t = min(len, NSMaxRange(lineRange(t))) }
            return t
        case "{":
            var t = p
            for _ in 0..<n { let s = lineStart(t); t = (s < t) ? s : lineStart(max(0, s - 1)) }
            return t
        case ")":
            let starts = sentenceStarts()
            var t = p
            for _ in 0..<n { if let s = starts.first(where: { $0 > t }) { t = s } }
            return t
        case "(":
            let starts = sentenceStarts()
            var t = p
            for _ in 0..<n { if let s = starts.last(where: { $0 < t }) { t = s } }
            return t
        default: return nil
        }
    }

    private func nextWordStart(_ p: Int) -> Int {
        let len = ns.length
        var i = p
        guard i < len else { return len }
        let c0 = cls(i)
        if c0 != 0 { while i < len && cls(i) == c0 { i += 1 } }
        while i < len && cls(i) == 0 { i += 1 }
        return i
    }

    private func prevWordStart(_ p: Int) -> Int {
        guard p > 0 else { return 0 }
        var i = p - 1
        while i > 0 && cls(i) == 0 { i -= 1 }
        let c0 = cls(i)
        while i > 0 && cls(i - 1) == c0 { i -= 1 }
        return i
    }

    private func wordEnd(_ p: Int) -> Int {
        let len = ns.length
        guard len > 0 else { return 0 }
        var i = p + 1
        while i < len && cls(i) == 0 { i += 1 }
        guard i < len else { return len - 1 }
        let c0 = cls(i)
        while i + 1 < len && cls(i + 1) == c0 { i += 1 }
        return i
    }

    private func sentenceStarts() -> [Int] {
        var out: [Int] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.bySentences, .substringNotRequired]) { _, r, _, _ in
            out.append(r.location)
        }
        return out
    }

    /// j/k by visual line, keeping the column across repeated moves.
    private func verticalMove(from p: Int, down: Bool, count n: Int) -> Int {
        guard let lm = layoutManager, let tc = textContainer else { return p }
        let len = ns.length
        guard len > 0 else { return 0 }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        var pos = p
        for _ in 0..<n {
            let gi = lm.glyphIndexForCharacter(at: min(pos, len - 1))
            var line = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
            if pos >= len && !lm.extraLineFragmentRect.isEmpty { line = lm.extraLineFragmentRect }
            let x: CGFloat
            if let g = goalX {
                x = g
            } else {
                let gr = lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc)
                x = pos >= len ? gr.maxX : gr.minX
            }
            goalX = x
            let y = down ? line.maxY + 1 : line.minY - 1
            if y < 0 || y > used.maxY { break }
            if down && !lm.extraLineFragmentRect.isEmpty && y >= lm.extraLineFragmentRect.minY {
                pos = len
                continue
            }
            var frac: CGFloat = 0
            let g = lm.glyphIndex(for: NSPoint(x: x + 1, y: y), in: tc, fractionOfDistanceThroughGlyph: &frac)
            pos = lm.characterIndexForGlyph(at: g)
        }
        return pos
    }

    // MARK: Operators

    private func operatorRange(_ k: String, from p: Int, count n: Int) -> NSRange? {
        let len = ns.length
        switch k {
        case "w":
            var e = p
            for _ in 0..<n { e = nextWordStart(e) }
            let le = lineEnd(p)
            if p < le { e = min(e, le) }
            return NSRange(location: p, length: e - p)
        case "e":
            var e = p
            for _ in 0..<n { e = wordEnd(e) }
            return NSRange(location: p, length: min(nextChar(e), len) - p)
        case "l", " ":
            return charsRange(p, n)
        case "$":
            return NSRange(location: p, length: lineEnd(p) - p)
        default:
            // backward and other motions: range between target and cursor
            guard let t = motionTarget(k, from: p, count: n) else { return nil }
            return NSRange(location: min(t, p), length: abs(p - t))
        }
    }

    private func textObject(_ k: String, at p: Int, inner: Bool) -> NSRange? {
        let len = ns.length
        guard p < len else { return nil }
        switch k {
        case "w":
            guard !isNewline(p) else { return nil }
            let c = cls(p)
            var s = p, e = p + 1
            while s > 0 && cls(s - 1) == c && !isNewline(s - 1) { s -= 1 }
            while e < len && cls(e) == c && !isNewline(e) { e += 1 }
            if !inner {
                var e2 = e
                while e2 < len && cls(e2) == 0 && !isNewline(e2) { e2 += 1 }
                if e2 > e { e = e2 } else { while s > 0 && cls(s - 1) == 0 && !isNewline(s - 1) { s -= 1 } }
            }
            return NSRange(location: s, length: e - s)
        case "s":
            var found: NSRange?
            ns.enumerateSubstrings(in: lineRange(p), options: [.bySentences, .substringNotRequired]) { _, sub, encl, stop in
                if NSLocationInRange(p, encl) { found = inner ? sub : encl; stop.pointee = true }
            }
            if var r = found {
                while r.length > 0 && isNewline(NSMaxRange(r) - 1) { r.length -= 1 }
                return r
            }
            return nil
        case "p":
            let s = lineStart(p)
            if inner { return NSRange(location: s, length: lineEnd(p) - s) }
            // the paragraph plus the blank lines after it
            var e = NSMaxRange(lineRange(p))
            while e < len && isNewline(e) { e += 1 }
            return NSRange(location: s, length: e - s)
        default:
            return nil
        }
    }

    private func apply(_ op: String, _ r: NSRange, linewise: Bool) {
        if r.length == 0 && op != "c" { return }
        register = ns.substring(with: r)
        registerLinewise = linewise
        switch op {
        case "y":
            if mode == .visual { setMode(.normal) }
            setCursor(r.location); clampNormal()
        case "d":
            if mode == .visual { setMode(.normal) }
            replace(r, with: "")
            setCursor(r.location); clampNormal()
        default:
            replace(r, with: "")
            setCursor(r.location)
            setMode(.insert)
        }
    }

    private func linewise(_ op: String, count n: Int) {
        let len = ns.length
        var block = lineRange(cursor)
        for _ in 1..<max(n, 1) {
            if NSMaxRange(block) >= len { break }
            block = NSUnionRange(block, lineRange(NSMaxRange(block)))
        }
        applyLinewise(op, block)
    }

    /// d/c/y over whole lines.
    func applyLinewise(_ op: String, _ block: NSRange) {
        guard block.length > 0 || op == "c" || block.location > 0 else { return }
        var text = ns.substring(with: block)
        if !text.hasSuffix("\n") { text += "\n" }
        register = text
        registerLinewise = true

        switch op {
        case "y":
            break
        case "d":
            var del = block
            let endsWithNewline = block.length > 0 && isNewline(NSMaxRange(block) - 1)
            if !endsWithNewline && block.location > 0 {
                del = NSRange(location: block.location - 1, length: block.length + 1)
            }
            replace(del, with: "")
            setCursor(firstNonBlank(min(del.location, ns.length)))
            clampNormal()
        default:
            var inner = block
            while inner.length > 0 && isNewline(NSMaxRange(inner) - 1) { inner.length -= 1 }
            replace(inner, with: "")
            setCursor(inner.location)
            setMode(.insert)
        }
    }

    private func put(after: Bool) {
        guard !register.isEmpty else { return }
        let p = cursor
        if registerLinewise {
            var text = register
            let lr = lineRange(p)
            if after {
                let at = NSMaxRange(lr)
                let len = ns.length
                if at == len && (len == 0 || !isNewline(len - 1)) {
                    text = "\n" + String(text.dropLast())
                    replace(NSRange(location: at, length: 0), with: text)
                    setCursor(at + 1)
                } else {
                    replace(NSRange(location: at, length: 0), with: text)
                    setCursor(at)
                }
            } else {
                replace(NSRange(location: lr.location, length: 0), with: text)
                setCursor(lr.location)
            }
        } else {
            let at = after ? min(p + 1, lineEnd(p)) : p
            replace(NSRange(location: at, length: 0), with: register)
            setCursor(at + (register as NSString).length - 1)
        }
        clampNormal()
    }

    private func join() {
        let e = lineEnd(cursor)
        guard e < ns.length else { return }
        var k = e + 1
        while k < ns.length && cls(k) == 0 && !isNewline(k) { k += 1 }
        replace(NSRange(location: e, length: k - e), with: " ")
        setCursor(e)
    }

    private func finder(_ a: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = a.rawValue
        performTextFinderAction(item)
    }
}
