import AppKit

/// Markdown writing helpers: list continuation, indenting, bold/italic.
extension ZenTextView {
    static let listRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])|(\d+)([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)
    static let quoteRegex = try! NSRegularExpression(pattern: #"^[ \t]*>+[ \t]?"#)

    private func line(at p: Int) -> (NSRange, NSString) {
        let s = lineStart(p)
        let r = NSRange(location: s, length: lineEnd(p) - s)
        return (r, ns.substring(with: r) as NSString)
    }

    private func listMatch(_ line: NSString) -> NSTextCheckingResult? {
        Self.listRegex.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))
    }

    // MARK: Return continues lists and quotes

    /// Returns true if it handled the newline.
    func continueList() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        let p = sel.location
        let (lr, text) = line(at: p)

        if let m = listMatch(text) {
            guard p >= lr.location + m.range.length else { return false }
            if m.range.length == text.length {
                // empty item: Return ends the list
                replace(lr, with: "")
                setSelectedRange(NSRange(location: lr.location, length: 0))
                return true
            }
            let indent = text.substring(with: m.range(at: 1))
            var next = indent
            var number: Int?
            if m.range(at: 2).location != NSNotFound {
                next += text.substring(with: m.range(at: 2))
            } else {
                let n = (Int(text.substring(with: m.range(at: 3))) ?? 0) + 1
                number = n
                next += "\(n)" + text.substring(with: m.range(at: 4))
            }
            next += text.substring(with: m.range(at: 5))
            if m.range(at: 6).location != NSNotFound { next += "[ ] " }
            insertText("\n" + next, replacementRange: sel)
            if let n = number { renumber(after: selectedRange().location, indent: indent, from: n + 1) }
            return true
        }

        if let m = Self.quoteRegex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) {
            guard p >= lr.location + m.range.length else { return false }
            if m.range.length == text.length {
                replace(lr, with: "")
                setSelectedRange(NSRange(location: lr.location, length: 0))
                return true
            }
            insertText("\n" + text.substring(with: m.range), replacementRange: sel)
            return true
        }
        return false
    }

    /// Fix the numbers of the items following the line at `pos`.
    func renumber(after pos: Int, indent: String, from start: Int) {
        var n = start
        var p = NSMaxRange(lineRange(pos))
        while p < ns.length {
            let (lr, text) = line(at: p)
            guard let m = listMatch(text) else { break }
            let ind = text.substring(with: m.range(at: 1))
            if ind.count > indent.count { p = NSMaxRange(lineRange(p)); continue }  // nested item
            if ind != indent || m.range(at: 3).location == NSNotFound { break }
            let num = m.range(at: 3)
            if Int(text.substring(with: num)) != n {
                replace(NSRange(location: lr.location + num.location, length: num.length), with: "\(n)")
            }
            n += 1
            p = NSMaxRange(lineRange(lr.location))
        }
    }

    // MARK: Indent

    func caretOnListLine() -> Bool {
        listMatch(line(at: selectedRange().location).1) != nil
    }

    @objc func indentLines(_ sender: Any?) { shiftLines(by: 1) }
    @objc func outdentLines(_ sender: Any?) { shiftLines(by: -1) }

    /// Indent (+1) or outdent (-1) every line touched by the selection by 4 spaces.
    func shiftLines(by dir: Int) {
        let sel = selectedRange()
        let block = ns.lineRange(for: sel)
        let text = ns.substring(with: block)
        let trailing = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if trailing { lines.removeLast() }
        var firstDelta = 0
        for i in lines.indices {
            if dir > 0 {
                if lines.count > 1 && lines[i].isEmpty { continue }
                lines[i] = "    " + lines[i]
                if i == 0 { firstDelta = 4 }
            } else {
                let l = lines[i]
                var k = 0
                if l.hasPrefix("\t") { k = 1 } else { while k < 4 && l.dropFirst(k).hasPrefix(" ") { k += 1 } }
                lines[i] = String(l.dropFirst(k))
                if i == 0 { firstDelta = -k }
            }
        }
        let out = lines.joined(separator: "\n") + (trailing ? "\n" : "")
        guard out != text else { return }
        replace(block, with: out)
        if sel.length == 0 {
            setSelectedRange(NSRange(location: max(block.location, sel.location + firstDelta), length: 0))
        } else {
            setSelectedRange(NSRange(location: block.location, length: (out as NSString).length - (trailing ? 1 : 0)))
        }
    }

    // MARK: Notes

    /// Insert `<!--  -->` (after the selection, if any) with the caret inside.
    @objc func insertNote(_ sender: Any?) {
        let sel = selectedRange()
        let at = NSMaxRange(sel)
        let pad = at > 0 && cls(at - 1) != 0 ? " " : ""
        replace(NSRange(location: at, length: 0), with: pad + "<!--  -->")
        setSelectedRange(NSRange(location: at + (pad as NSString).length + 5, length: 0))
        if vimEnabled { setMode(.insert) }
    }

    // MARK: Bold / italic

    @objc func markdownBold(_ sender: Any?) { toggleWrap("**") }
    @objc func markdownItalic(_ sender: Any?) { toggleWrap("*") }

    private func run(of ch: unichar, before loc: Int) -> Int {
        var k = 0
        while loc - k - 1 >= 0 && ns.character(at: loc - k - 1) == ch { k += 1 }
        return k
    }

    private func run(of ch: unichar, after loc: Int) -> Int {
        var k = 0
        while loc + k < ns.length && ns.character(at: loc + k) == ch { k += 1 }
        return k
    }

    /// `**` / `*` toggling that understands `***both***`.
    func toggleWrap(_ mk: String) {
        let m = (mk as NSString).length
        let star = unichar(42)
        let present: (Int, Int) -> Bool = mk == "*" ? { $0 % 2 == 1 && $1 % 2 == 1 } : { $0 >= 2 && $1 >= 2 }
        var sel = selectedRange()

        if sel.length == 0 {
            let loc = sel.location
            let b = run(of: star, before: loc), a = run(of: star, after: loc)
            if b >= m && a >= m && present(b, a) {
                // empty pair "**|**": remove it
                replace(NSRange(location: loc - m, length: 2 * m), with: "")
                setSelectedRange(NSRange(location: loc - m, length: 0))
                return
            }
            if a >= m && loc > 0 && cls(loc - 1) != 0 {
                // just typed inside a pair: hop over the closing marker
                setSelectedRange(NSRange(location: loc + m, length: 0))
                return
            }
            let word = selectionRange(forProposedRange: NSRange(location: loc, length: 0), granularity: .selectByWord)
            if word.length > 0 && word.location < ns.length && cls(word.location) == 1 {
                sel = word
            } else {
                replace(NSRange(location: loc, length: 0), with: mk + mk)
                setSelectedRange(NSRange(location: loc + m, length: 0))
                return
            }
        }

        let inner = ns.substring(with: sel)
        let b = run(of: star, before: sel.location), a = run(of: star, after: NSMaxRange(sel))
        if present(b, a) {
            replace(NSRange(location: NSMaxRange(sel), length: m), with: "")
            replace(NSRange(location: sel.location - m, length: m), with: "")
            setSelectedRange(NSRange(location: sel.location - m, length: sel.length))
        } else if inner.count >= 2 * m && inner.hasPrefix(mk) && inner.hasSuffix(mk)
                    && !String(inner.dropFirst(m).dropLast(m)).contains(mk)
                    && (mk == "**" || !inner.hasPrefix("**") || inner.hasPrefix("***")) {
            let stripped = String(inner.dropFirst(m).dropLast(m))
            replace(sel, with: stripped)
            setSelectedRange(NSRange(location: sel.location, length: (stripped as NSString).length))
        } else {
            replace(sel, with: mk + inner + mk)
            setSelectedRange(NSRange(location: sel.location + m, length: sel.length))
        }
    }
}

// MARK: Smart punctuation and links

extension ZenTextView {
    /// Curly quotes and "--" to an em dash, as you type. Leaves code,
    /// rules at line start and <!-- note --> markers alone.
    func smarten(_ s: String) -> (NSRange, String)? {
        guard s == "\"" || s == "'" || s == "-" else { return nil }
        let sel = selectedRange()
        let loc = sel.location
        let line = ns.lineRange(for: NSRange(location: loc, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: loc - line.location))
        if before.filter({ $0 == "`" }).count % 2 == 1 || inside(open: "```", close: "```", at: loc) { return nil }

        if s == "-" {
            guard sel.length == 0, before.hasSuffix("-"), before.count >= 2 else { return nil }
            let p2 = before.dropLast().last!
            if p2 == "-" || p2 == "!" || before.trimmingCharacters(in: .whitespaces) == "-" { return nil }
            if inside(open: "<!--", close: "-->", at: loc) { return nil }
            return (NSRange(location: loc - 1, length: 1), "—")
        }
        let opens = before.last.map { $0.isWhitespace || "([{—–‘“".contains($0) } ?? true
        if s == "\"" { return (sel, opens ? "“" : "”") }
        return (sel, opens ? "‘" : "’")
    }

    /// Whether `loc` sits between an unclosed `open` and its `close`.
    private func inside(open: String, close: String, at loc: Int) -> Bool {
        let head = NSRange(location: 0, length: loc)
        if open == close {
            var n = 0, r = head
            while true {
                let f = ns.range(of: open, options: [], range: r)
                if f.location == NSNotFound { break }
                if f.location == 0 || ns.character(at: f.location - 1) == 10 { n += 1 }
                r = NSRange(location: NSMaxRange(f), length: loc - NSMaxRange(f))
            }
            return n % 2 == 1
        }
        let o = ns.range(of: open, options: .backwards, range: head).location
        guard o != NSNotFound else { return false }
        let c = ns.range(of: close, options: .backwards, range: head).location
        return c == NSNotFound || c < o
    }

    /// Pasting a URL over selected words makes a markdown link.
    func pasteLink(from pb: NSPasteboard = .general) -> Bool {
        let sel = selectedRange()
        guard sel.length > 0,
              let url = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              url.range(of: #"^(https?://|mailto:)\S+$"#, options: .regularExpression) != nil else { return false }
        let text = ns.substring(with: sel)
        guard !text.contains("\n"), text.range(of: #"^\s*(https?://|mailto:)"#, options: .regularExpression) == nil
        else { return false }
        let link = "[\(text)](\(url))"
        if mode == .visual { setMode(.normal) }
        replace(sel, with: link)
        setCursor(sel.location + (link as NSString).length)
        clampNormal()
        return true
    }
}
