import AppKit

/// Light markdown styling: markup characters are dimmed, emphasis and
/// headings get real fonts. The text stays plain markdown on disk.
final class MarkdownStyler: NSObject, NSTextStorageDelegate {
    var fontSize: CGFloat = 20 { didSet { rebuildFonts() } }
    /// 0 serif (New York), 1 sans (SF Pro), 2 mono (SF Mono)
    var family = 0 { didSet { rebuildFonts() } }
    static let familyNames = ["Serif", "Sans", "Mono"]
    /// Every text change: (edited range after the edit, change in length, inserted text).
    var onEdit: ((NSRange, Int, String) -> Void)?

    // warm off-white on pure black
    static let offWhite = NSColor(srgbRed: 0.918, green: 0.902, blue: 0.871, alpha: 1)  // #EAE6DE
    let textColor = MarkdownStyler.offWhite
    let markupColor = NSColor(srgbRed: 0.36, green: 0.35, blue: 0.33, alpha: 1)
    let quoteColor = NSColor(srgbRed: 0.62, green: 0.60, blue: 0.57, alpha: 1)
    let codeColor = NSColor(srgbRed: 0.76, green: 0.74, blue: 0.70, alpha: 1)

    private var base = NSFont.systemFont(ofSize: 20)
    private var mono = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
    private var paragraph = NSParagraphStyle()

    override init() {
        super.init()
        rebuildFonts()
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: base, .foregroundColor: textColor, .paragraphStyle: paragraph]
    }

    private func rebuildFonts() {
        let sys = NSFont.systemFont(ofSize: fontSize)
        switch family {
        case 1:
            base = sys
        case 2:
            base = NSFont.monospacedSystemFont(ofSize: round(fontSize * 0.9), weight: .regular)
        default:
            if let d = sys.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: fontSize) {
                base = f
            } else {
                base = sys
            }
        }
        mono = NSFont.monospacedSystemFont(ofSize: round(fontSize * 0.85), weight: .regular)
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.45
        paragraph = p
    }

    // MARK: NSTextStorageDelegate

    func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters) else { return }
        onEdit?(range, delta, (ts.string as NSString).substring(with: range))
        let r = (ts.string as NSString).paragraphRange(for: range)
        style(ts, range: r)
    }

    func restyleAll(_ ts: NSTextStorage) {
        style(ts, range: NSRange(location: 0, length: ts.length))
    }

    // MARK: Styling

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
    }

    private static let heading = re(#"^(#{1,6})[ \t]+.*$"#)
    private static let quote = re(#"^(>+)[ \t]?(.*)$"#)
    private static let list = re(#"^[ \t]*([-*+]|\d+[.)])[ \t]+"#)
    private static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)(\1)"#)
    private static let italic = re(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])(\1)(?![*_\w])"#)
    private static let code = re(#"`[^`\n]+`"#)
    private static let fence = re(#"^```.*$"#)
    private static let link = re(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private static let rule = re(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let note = re(#"(<!--)(.*?)(-->)"#)

    func style(_ ts: NSTextStorage, range: NSRange) {
        guard range.length > 0 else { return }
        let s = ts.string
        func each(_ r: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            r.enumerateMatches(in: s, range: range) { m, _, _ in if let m { body(m) } }
        }
        func dim(_ r: NSRange) {
            if r.location != NSNotFound { ts.addAttribute(.foregroundColor, value: markupColor, range: r) }
        }

        ts.beginEditing()
        ts.setAttributes(baseAttributes, range: range)

        each(Self.bold) { m in
            addTrait(.boldFontMask, ts, m.range(at: 2))
            dim(m.range(at: 1)); dim(m.range(at: 3))
        }
        each(Self.italic) { m in
            addTrait(.italicFontMask, ts, m.range(at: 2))
            dim(m.range(at: 1)); dim(m.range(at: 3))
        }
        each(Self.code) { m in
            ts.addAttributes([.font: mono, .foregroundColor: codeColor], range: m.range)
        }
        each(Self.link) { m in
            dim(m.range)
            ts.addAttribute(.foregroundColor, value: textColor, range: m.range(at: 1))
        }
        each(Self.list) { m in dim(m.range(at: 1)) }
        each(Self.quote) { m in
            ts.addAttribute(.foregroundColor, value: quoteColor, range: m.range(at: 2))
            addTrait(.italicFontMask, ts, m.range(at: 2))
            dim(m.range(at: 1))
        }
        each(Self.heading) { m in
            let level = m.range(at: 1).length
            let scale: CGFloat = [1.5, 1.3, 1.15][min(level, 3) - 1]
            let f = NSFontManager.shared.convert(base.withSize(round(fontSize * scale)), toHaveTrait: .boldFontMask)
            ts.addAttribute(.font, value: f, range: m.range)
            dim(m.range(at: 1))
        }
        each(Self.fence) { m in
            ts.addAttributes([.font: mono, .foregroundColor: markupColor], range: m.range)
        }
        each(Self.rule) { m in dim(m.range) }
        each(Self.note) { m in
            // notes: small amber sans, markers faint
            let f = NSFontManager.shared.convert(NSFont.systemFont(ofSize: round(fontSize * 0.8)), toHaveTrait: .italicFontMask)
            ts.addAttributes([.font: f, .foregroundColor: Theme.accent.withAlphaComponent(0.75)], range: m.range)
            ts.addAttribute(.foregroundColor, value: Theme.accent.withAlphaComponent(0.3), range: m.range(at: 1))
            ts.addAttribute(.foregroundColor, value: Theme.accent.withAlphaComponent(0.3), range: m.range(at: 3))
        }
        ts.endEditing()
    }

    private func addTrait(_ trait: NSFontTraitMask, _ ts: NSTextStorage, _ r: NSRange) {
        guard r.location != NSNotFound, r.length > 0 else { return }
        ts.enumerateAttribute(.font, in: r) { v, sub, _ in
            guard let f = v as? NSFont else { return }
            ts.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: trait), range: sub)
        }
    }
}
