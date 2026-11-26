import AppKit

/// Markdown to HTML for Copy as Rich Text and the exports. Covers what the
/// editor styles: headings, paragraphs, quotes, lists, code, rules, links,
/// bold and italic. Notes are dropped. Single line breaks are kept, as on screen.
enum Export {
    static func stripNotes(_ md: String) -> String {
        md.replacingOccurrences(of: #"[ \t]*<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
    }

    static func html(_ md: String) -> String {
        var out: [String] = []
        var para: [String] = []
        var quote: [String] = []
        var lists: [(indent: Int, ordered: Bool)] = []
        var code: [String]?

        func flushText() {
            if !para.isEmpty { out.append("<p>" + para.map(inline).joined(separator: "<br>\n") + "</p>") }
            if !quote.isEmpty { out.append("<blockquote><p>" + quote.map(inline).joined(separator: "<br>\n") + "</p></blockquote>") }
            para = []
            quote = []
        }
        func closeLists(above indent: Int = -1) {
            while let l = lists.last, l.indent > indent {
                out.append(l.ordered ? "</li></ol>" : "</li></ul>")
                lists.removeLast()
            }
        }
        func closeAll() { flushText(); closeLists() }

        for raw in stripNotes(md).components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let c = code {
                    out.append("<pre><code>" + c.map(escape).joined(separator: "\n") + "</code></pre>")
                    code = nil
                } else {
                    closeAll()
                    code = []
                }
                continue
            }
            if code != nil { code!.append(raw); continue }

            if trimmed.isEmpty { flushText(); continue }
            if let m = match(#"^(#{1,6})\s+(.*?)\s*#*$"#, trimmed) {
                closeAll()
                let n = m[1].count
                out.append("<h\(n)>\(inline(m[2]))</h\(n)>")
            } else if match(#"^([-*_])(\s*\1){2,}$"#, trimmed) != nil {
                closeAll()
                out.append("<hr>")
            } else if let m = match(#"^>\s?(.*)$"#, trimmed) {
                if !para.isEmpty { flushText() }
                closeLists()
                quote.append(m[1])
            } else if let m = match(#"^(\s*)([-*+]|(\d+)[.)])\s+(.*)$"#, line) {
                flushText()
                let indent = m[1].count
                let ordered = !m[3].isEmpty
                closeLists(above: indent)
                if let l = lists.last, l.indent == indent, l.ordered == ordered {
                    out.append("</li><li>")
                } else {
                    if let l = lists.last, l.indent == indent { closeLists(above: indent - 1) }
                    let start = Int(m[3]) ?? 1
                    out.append(ordered ? (start == 1 ? "<ol><li>" : "<ol start=\"\(start)\"><li>") : "<ul><li>")
                    lists.append((indent, ordered))
                }
                out.append(inline(m[4]))
            } else if !lists.isEmpty && line.hasPrefix("  ") && para.isEmpty {
                out.append("<br>" + inline(trimmed))  // continuation of a list item
            } else {
                if !quote.isEmpty { flushText() }
                closeLists()
                para.append(trimmed)
            }
        }
        if let c = code { out.append("<pre><code>" + c.map(escape).joined(separator: "\n") + "</code></pre>") }
        closeAll()
        return out.joined(separator: "\n")
    }

    /// A standalone page, styled for reading on white.
    static func page(_ body: String, title: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font: 12pt/1.55 Georgia, serif; color: #111; max-width: 36em; margin: 3em auto; padding: 0 1em; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 1.4em 0 0.5em; }
        h1 { font-size: 1.9em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; } h4 { font-size: 1em; }
        p, ul, ol, blockquote, pre { margin: 0 0 0.9em; }
        blockquote { color: #555; margin-left: 0; padding-left: 1em; border-left: 2px solid #ccc; }
        code, pre { font: 0.88em ui-monospace, Menlo, monospace; }
        hr { border: 0; border-top: 1px solid #ccc; margin: 2em 0; }
        a { color: #1a5fb4; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    static func attributed(_ html: String) -> NSAttributedString? {
        try? NSAttributedString(data: Data(html.utf8),
                                options: [.documentType: NSAttributedString.DocumentType.html,
                                          .characterEncoding: String.Encoding.utf8.rawValue],
                                documentAttributes: nil)
    }

    /// Puts HTML (for web editors), RTF (for Mail, Pages, Notes) and plain
    /// markdown without notes on the clipboard.
    static func copyRich(_ md: String) {
        let body = html(md)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("<meta charset=\"utf-8\">" + body, forType: .html)
        let rtfHTML = "<meta charset=\"utf-8\"><style>body { font: 13px 'Helvetica Neue', Helvetica, sans-serif; }</style>" + body
        if let a = attributed(rtfHTML),
           let rtf = a.rtf(from: NSRange(location: 0, length: a.length), documentAttributes: [:]) {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(stripNotes(md), forType: .string)
    }

    /// The HTML importer drops italics for New York, so pages are styled in
    /// Georgia and swapped to New York here, keeping bold and italic.
    static func newYork(_ a: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: a)
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { v, r, _ in
            guard let f = v as? NSFont, f.familyName == "Georgia" else { return }
            let traits = f.fontDescriptor.symbolicTraits
            var d = NSFont.systemFont(ofSize: f.pointSize, weight: traits.contains(.bold) ? .bold : .regular)
                .fontDescriptor.withDesign(.serif) ?? f.fontDescriptor
            if traits.contains(.italic) { d = d.withSymbolicTraits(d.symbolicTraits.union(.italic)) }
            if let nf = NSFont(descriptor: d, size: f.pointSize) { m.addAttribute(.font, value: nf, range: r) }
        }
        return m
    }

    /// Paginated PDF with one-inch margins on the default paper size.
    static func pdf(_ md: String, title: String, to url: URL) -> Bool {
        guard let a = attributed(page(html(md), title: title)).map(newYork) else { return false }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 72
        info.bottomMargin = 72
        info.leftMargin = 72
        info.rightMargin = 72
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - 144
        // TextKit 1: TextKit 2 would draw list markers a second time
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.drawsBackground = true
        tv.backgroundColor = .white
        tv.appearance = NSAppearance(named: .aqua)
        tv.textStorage?.setAttributedString(a)
        tv.sizeToFit()

        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        return op.run()
    }

    // MARK: Inline

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Code spans and links are swapped out for placeholders first, so
    /// emphasis never touches code or URLs.
    private static func inline(_ s: String) -> String {
        var held: [String] = []
        func hold(_ html: String) -> String {
            held.append(html)
            return "\u{1}\(held.count - 1)\u{1}"
        }
        var t = escape(s)
        t = replace(#"`([^`]+)`"#, in: t) { hold("<code>\($0[1])</code>") }
        t = replace(#"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#, in: t) { hold("<img alt=\"\($0[1])\" src=\"\($0[2])\">") }
        t = replace(#"\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#, in: t) { hold("<a href=\"\($0[2])\">\(emphasis($0[1]))</a>") }
        t = replace(#"&lt;((?:https?://|mailto:)[^\s&]+)&gt;"#, in: t) { hold("<a href=\"\($0[1])\">\($0[1])</a>") }
        t = emphasis(t)
        return replace("\u{1}(\\d+)\u{1}", in: t) { held[Int($0[1])!] }
    }

    private static func emphasis(_ s: String) -> String {
        var t = s
        for (p, tag) in [(#"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#, "strong><em"),
                         (#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, "strong"),
                         (#"(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)"#, "strong"),
                         (#"\*(?=\S)(.+?)(?<=\S)\*"#, "em"),
                         (#"(?<!\w)_(?=\S)(.+?)(?<=\S)_(?!\w)"#, "em"),
                         (#"~~(?=\S)(.+?)(?<=\S)~~"#, "del")] {
            let close = tag.components(separatedBy: "><").reversed().joined(separator: "></")
            t = replace(p, in: t) { "<\(tag)>\($0[1])</\(close)>" }
        }
        return t
    }

    private static func match(_ pattern: String, _ s: String) -> [String]? {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func replace(_ pattern: String, in s: String, _ f: ([String]) -> String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f((0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) })
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
