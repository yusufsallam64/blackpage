import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var root: RootView!
    private var scrollView: NSScrollView!
    private var textView: ZenTextView!
    private var sidebar: SidebarView!
    private var statusBar: NSView!
    private var wordLabel: NSTextField!
    private var shortcuts: ShortcutsView?
    private var picker: PickerView?
    private var statusFadeTimer: Timer?
    private let styler = MarkdownStyler()
    private let defaults = UserDefaults.standard

    private var fileURL: URL?
    private var fileDate: Date?  // modification date when we last read or wrote the file
    private var history: History?
    private var recording = true
    private var dirty = false
    private var saveTimer: Timer?
    private var openedAtLaunch = false
    private var sidebarVisible = false
    private let sidebarWidth: CGFloat = 240

    private var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    private lazy var draftsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Blackpage/Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var isDraft: Bool {
        fileURL?.deletingLastPathComponent().standardizedFileURL.path == draftsDir.standardizedFileURL.path
    }

    /// Folder for the file browser and ⌘P: the one picked with ⇧⌘O, else
    /// the current file's folder, else ~/Documents.
    private var rootFolder: URL {
        if let p = defaults.string(forKey: "rootFolder"), FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        if let r = sidebar?.root {
            if isDraft { return r }
            if let f = fileURL, f.standardizedFileURL.path.hasPrefix(r.standardizedFileURL.path + "/") { return r }
        }
        if let f = fileURL, !isDraft { return f.deletingLastPathComponent() }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
    }

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ n: Notification) {
        defaults.register(defaults: ["fontSize": 20.0, "typewriter": true, "focusParagraph": false,
                                     "vim": false, "spellcheck": true, "family": 0, "sidebar": false])
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
        buildWindow()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if !openedAtLaunch {
            if let path = defaults.string(forKey: "lastFile"), FileManager.default.fileExists(atPath: path) {
                load(URL(fileURLWithPath: path))
            } else {
                newDraft()
            }
        }
        if defaults.bool(forKey: "sidebar") { setSidebar(visible: true) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        if !defaults.bool(forKey: "seenShortcuts") {
            defaults.set(true, forKey: "seenShortcuts")
            toggleShortcuts(nil)
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openedAtLaunch = true
        guard saveNow() else { return }
        load(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) {
        saveNow()
        history?.close(textView.string)
    }
    func windowWillClose(_ n: Notification) { saveNow() }

    // MARK: Window

    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("BlackpageMain")
        window.acceptsMouseMovedEvents = true

        root = RootView(frame: window.contentLayoutRect)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.onMouseMoved = { [weak self] in self?.revealStatus() }
        root.onResize = { [weak self] in self?.layoutPanes() }
        window.contentView = root

        // TextKit 1 stack, built by hand
        let storage = NSTextStorage()
        storage.delegate = styler
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)

        scrollView = NSScrollView(frame: root.bounds)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero

        let tv = ZenTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize), textContainer: tc)
        tv.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.drawsBackground = true
        tv.backgroundColor = .black
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = defaults.bool(forKey: "spellcheck")
        tv.isGrammarCheckingEnabled = false
        tv.selectedTextAttributes = [.backgroundColor: NSColor(white: 0.22, alpha: 1)]
        tv.insertionPointColor = tv.caretInsert
        tv.delegate = self
        tv.onEscape = { [weak self] in
            guard let self, self.isFullScreen else { return }
            self.window.toggleFullScreen(nil)
        }
        tv.interceptKey = { [weak self] _ in
            guard let self else { return false }
            self.hideStatusInZen()
            if self.shortcuts != nil {
                self.hideShortcuts()
                return true  // the key just closes the list
            }
            return false
        }
        textView = tv
        scrollView.documentView = tv
        root.addSubview(scrollView)

        sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: root.bounds.height))
        sidebar.isHidden = true
        sidebar.onOpen = { [weak self] url in self?.switchTo(url) }
        sidebar.onEscape = { [weak self] in self?.focusEditor() }
        root.addSubview(sidebar)

        buildStatusBar()

        styler.onEdit = { [weak self] range, delta, inserted in
            guard let self, self.recording else { return }
            self.history?.recordEdit(range: range, delta: delta, inserted: inserted)
        }
        styler.family = defaults.integer(forKey: "family")
        styler.fontSize = CGFloat(defaults.double(forKey: "fontSize"))
        tv.typingAttributes = styler.baseAttributes
        tv.typewriter = defaults.bool(forKey: "typewriter")
        tv.focusParagraph = defaults.bool(forKey: "focusParagraph")
        tv.vimEnabled = defaults.bool(forKey: "vim")
        tv.smartPunctuation = defaults.bool(forKey: "smartPunctuation")

        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        layoutPanes()
    }

    /// Hint bottom-left, word count bottom-right. Dim but always there in a
    /// window; in zen it only shows when the mouse moves.
    private func buildStatusBar() {
        statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusBar)
        wordLabel = NSTextField(labelWithString: "")
        wordLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        wordLabel.textColor = NSColor(white: 0.32, alpha: 1)
        let hint = NSTextField(labelWithString: "⌘/ shortcuts   ⌘K commands")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 0.22, alpha: 1)
        for l in [wordLabel!, hint] {
            l.translatesAutoresizingMaskIntoConstraints = false
            statusBar.addSubview(l)
        }
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 32),
            hint.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 16),
            hint.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            wordLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -16),
            wordLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }

    private func layoutPanes() {
        guard let root, let scrollView, let sidebar else { return }
        let b = root.bounds
        let sw = sidebarVisible ? sidebarWidth : 0
        sidebar.isHidden = !sidebarVisible
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: b.height)
        let editor = NSRect(x: sw, y: 0, width: b.width - sw, height: b.height)
        if scrollView.frame != editor { scrollView.frame = editor }
        picker?.frame = b
    }

    @objc private func clipFrameChanged(_ n: Notification) { updateLayout() }

    /// Centers a readable column; with typewriter scrolling, pads half a
    /// screen above and below so the caret line can sit mid-screen.
    private func updateLayout() {
        let size = scrollView.contentSize
        let column = min(styler.fontSize * 34, size.width - 64)
        let side = max(32, floor((size.width - column) / 2))
        let vertical = textView.typewriter ? floor(size.height / 2) : 72
        let inset = NSSize(width: side, height: vertical)
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.centerCaret(animated: false)
    }

    private func focusEditor() {
        picker?.close()
        window.makeFirstResponder(textView)
    }

    // MARK: Zen

    func windowWillEnterFullScreen(_ n: Notification) {
        statusBar.alphaValue = 0
        scrollView.hasVerticalScroller = false
        if sidebarVisible { setSidebar(visible: false, remember: false) }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func windowDidExitFullScreen(_ n: Notification) {
        statusFadeTimer?.invalidate()
        statusBar.alphaValue = 1
        scrollView.hasVerticalScroller = true
        if defaults.bool(forKey: "sidebar") { setSidebar(visible: true, focus: false) }
    }

    private func revealStatus() {
        guard isFullScreen else { return }
        statusFadeTimer?.invalidate()
        statusBar.animator().alphaValue = 1
        statusFadeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.hideStatusInZen()
        }
    }

    private func hideStatusInZen() {
        guard isFullScreen, statusBar.alphaValue > 0 else { return }
        statusFadeTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            statusBar.animator().alphaValue = 0
        }
    }

    // MARK: Shortcuts overlay

    @objc func toggleShortcuts(_ sender: Any?) {
        if shortcuts != nil { hideShortcuts(); return }
        picker?.close()
        let v = ShortcutsView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alphaValue = 0
        root.addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        v.animator().alphaValue = 1
        shortcuts = v
        focusEditor()
    }

    private func hideShortcuts() {
        guard let v = shortcuts else { return }
        shortcuts = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            v.animator().alphaValue = 0
        }, completionHandler: { v.removeFromSuperview() })
    }

    // MARK: Pickers

    @discardableResult
    private func showPicker(_ placeholder: String, items: [PickerItem] = [],
                            filter: @escaping PickerView.Filter = PickerView.fuzzyFilter) -> PickerView {
        picker?.close()
        hideShortcuts()
        let p = PickerView(placeholder: placeholder, items: items, filter: filter)
        p.frame = root.bounds
        p.onClose = { [weak self, weak p] in
            guard let self else { return }
            if self.picker === p { self.picker = nil }
            if self.window.firstResponder == nil || self.window.firstResponder === self.window { self.focusEditor() }
        }
        root.addSubview(p)
        picker = p
        window.makeFirstResponder(p.field)
        (p.field.currentEditor() as? NSTextView)?.insertionPointColor = Theme.text
        return p
    }

    /// ⌘K: every menu command, fuzzy-searchable.
    @objc func commandPalette(_ sender: Any?) {
        var items: [PickerItem] = []
        func walk(_ menu: NSMenu, prefix: String, top: Bool) {
            for it in menu.items where !it.isSeparatorItem && !it.isHidden {
                if top && it.title == "Window" { continue }  // macOS fills this with its own items
                if let sub = it.submenu {
                    walk(sub, prefix: top ? "" : prefix + it.title + ": ", top: false)
                    continue
                }
                guard let action = it.action, action != #selector(commandPalette(_:)) else { continue }
                _ = validateMenuItem(it)
                let target = it.target
                let keys = Self.keyString(it)
                items.append(PickerItem(title: prefix + it.title.replacingOccurrences(of: "…", with: ""),
                                        detail: (it.state == .on ? "on   " : "") + keys,
                                        action: { [weak self] in
                                            self?.focusEditor()
                                            NSApp.sendAction(action, to: target, from: it)
                                        }))
            }
        }
        if let main = NSApp.mainMenu { walk(main, prefix: "", top: true) }
        showPicker("Run a command", items: items)
    }

    private static func keyString(_ it: NSMenuItem) -> String {
        guard !it.keyEquivalent.isEmpty else { return "" }
        let m = it.keyEquivalentModifierMask
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + (it.keyEquivalent == "\r" ? "↩" : it.keyEquivalent.uppercased())
    }

    /// ⌘P: fuzzy find a file in the browser folder (plus drafts).
    @objc func findFile(_ sender: Any?) {
        let rootURL = rootFolder
        let drafts = draftsDir
        let p = showPicker("Find a file in \(rootURL.lastPathComponent)")
        p.emptyText = "No markdown files here. ⇧⌘O picks a folder."
        p.loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak p] in
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .abbreviated
            var found = Files.scan(rootURL).map { (u, d) -> (URL, Date, String) in
                (u, d, String(u.path.dropFirst(rootURL.path.count + 1)))
            }
            if !rootURL.path.hasPrefix(drafts.path) {
                found += Files.scan(drafts).map { ($0.0, $0.1, "Drafts/" + $0.0.lastPathComponent) }
            }
            found.sort { $0.1 > $1.1 }
            DispatchQueue.main.async {
                guard let self, let p else { return }
                p.setItems(found.map { (url, date, path) in
                    PickerItem(title: path, detail: rel.localizedString(for: date, relativeTo: Date()),
                               action: { [weak self] in self?.switchTo(url) })
                })
            }
        }
    }

    /// ⌘F: fuzzy search sentences in this document. Empty query lists headings.
    @objc func searchDocument(_ sender: Any?) {
        let text = textView.ns
        var sentences: [(NSRange, String, Int)] = []  // range, text, line number
        var headings: [(Int, PickerItem)] = []
        var lineNo = 1
        var scanned = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.bySentences]) { s, r, _, _ in
            guard let s else { return }
            for i in scanned..<r.location where text.character(at: i) == 10 { lineNo += 1 }
            scanned = r.location
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let lead = (s as NSString).range(of: trimmed).location
            let loc = r.location + (lead == NSNotFound ? 0 : lead)
            sentences.append((NSRange(location: loc, length: (trimmed as NSString).length), trimmed, lineNo))
        }
        let headingRe = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.+)$"#, options: [.anchorsMatchLines])
        headingRe.enumerateMatches(in: textView.string, range: NSRange(location: 0, length: text.length)) { m, _, _ in
            guard let m else { return }
            let level = m.range(at: 1).length
            let title = String(repeating: "  ", count: level - 1) + text.substring(with: m.range(at: 2))
            let target = NSRange(location: m.range.location, length: 0)
            headings.append((m.range.location, PickerItem(title: title, detail: "H\(level)", action: { [weak self] in self?.jump(to: target) })))
        }

        let outline = (headings.map { ($0.0, $0.1) } + noteItems().map { ($0.0, $0.1) }).sorted { $0.0 < $1.0 }.map { $0.1 }
        let p = showPicker("Search this document", filter: { [weak self] q, _ in
            if q.trimmingCharacters(in: .whitespaces).isEmpty { return outline }
            var scored: [(Int, Int, PickerItem)] = []
            for (i, (range, s, line)) in sentences.enumerated() {
                guard let m = Fuzzy.match(q, in: s), m.score > 0,
                      let first = m.indices.first, let last = m.indices.last else { continue }
                let (title, idx) = PickerView.window(s, m.indices)
                let target = NSRange(location: range.location + first, length: last - first + 1)
                scored.append((m.score, i, PickerItem(title: title, detail: "line \(line)", matches: idx,
                                                      action: { [weak self] in self?.jump(to: target) })))
            }
            scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            return scored.prefix(100).map { $0.2 }
        })
        p.emptyText = outline.isEmpty && !sentences.isEmpty ? "Type to search" : "No matches"
    }

    // MARK: Notes  (<!-- ... --> comments: hidden when the markdown is rendered)

    /// (location, picker item) for every note, in document order.
    private func noteItems() -> [(Int, PickerItem)] {
        let text = textView.ns
        var lineNo = 1, scanned = 0
        return Self.noteRe.matches(in: textView.string, range: NSRange(location: 0, length: text.length)).map { m in
            for i in scanned..<m.range.location where text.character(at: i) == 10 { lineNo += 1 }
            scanned = m.range.location
            let body = text.substring(with: m.range).dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
            let target = NSRange(location: m.range.location + 5, length: 0)
            return (m.range.location, PickerItem(title: "※ " + (body.isEmpty ? "marker" : body), detail: "line \(lineNo)",
                                                 action: { [weak self] in self?.jump(to: target) }))
        }
    }

    @objc func listNotes(_ sender: Any?) {
        let p = showPicker("Jump to a note", items: noteItems().map { $0.1 })
        p.emptyText = "No notes yet. ⌘' adds one."
    }

    @objc func nextNote(_ sender: Any?) { hopNote(forward: true) }
    @objc func previousNote(_ sender: Any?) { hopNote(forward: false) }

    private func hopNote(forward: Bool) {
        let here = textView.selectedRange().location
        let starts = Self.noteRe.matches(in: textView.string, range: NSRange(location: 0, length: textView.ns.length))
            .map { $0.range.location }
        let next = forward ? (starts.first { $0 > here } ?? starts.first) : (starts.last { $0 + 5 < here } ?? starts.last)
        if let n = next { jump(to: NSRange(location: n + 5, length: 0)) }
    }

    private func jump(to r: NSRange) {
        focusEditor()
        textView.resetVim()
        if textView.vimEnabled {
            textView.setCursor(r.location)
            textView.clampNormal()
        } else {
            textView.setSelectedRange(r)
            textView.scrollRangeToVisible(r)
        }
    }

    // MARK: Sidebar

    @objc func toggleFileBrowser(_ sender: Any?) {
        if !sidebarVisible {
            setSidebar(visible: true)
        } else if window.firstResponder !== sidebar.outline {
            window.makeFirstResponder(sidebar.outline)
        } else {
            setSidebar(visible: false)
        }
    }

    private func setSidebar(visible: Bool, focus: Bool = true, remember: Bool = true) {
        picker?.close()
        sidebarVisible = visible
        if remember { defaults.set(visible, forKey: "sidebar") }
        if visible {
            sidebar.current = fileURL
            sidebar.reload(root: rootFolder)
        }
        layoutPanes()
        if visible && focus {
            window.makeFirstResponder(sidebar.outline)
        } else if !visible {
            focusEditor()
        }
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.directoryURL = rootFolder
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            self.defaults.set(url.path, forKey: "rootFolder")
            self.setSidebar(visible: true)
        }
    }

    // MARK: Text delegate

    func textDidChange(_ n: Notification) {
        dirty = true
        updateWordCount()
        textView.updateFocusDim()
        scheduleSave()
    }

    func textViewDidChangeSelection(_ n: Notification) {
        textView.updateFocusDim()
        if textView.selectedRange().length == 0 { textView.centerCaret() }
        updateWordCount()
    }

    private static let noteRe = try! NSRegularExpression(pattern: #"<!--.*?-->"#)

    /// Words, not counting <!-- notes -->.
    private func countWords(_ text: String) -> Int {
        let s = text.contains("<!--")
            ? Self.noteRe.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
            : text
        var n = 0
        s.enumerateSubstrings(in: s.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    /// "1,204 words · 5 min", or "38 of 1,204 words" with a selection.
    private func updateWordCount() {
        let total = countWords(textView.string)
        let sel = textView.selectedRange()
        if sel.length > 0 {
            let picked = countWords(textView.ns.substring(with: sel))
            wordLabel.stringValue = "\(picked.formatted()) of \(total.formatted()) words"
        } else {
            let words = total == 1 ? "1 word" : "\(total.formatted()) words"
            let minutes = max(1, Int((Double(total) / 230).rounded()))
            wordLabel.stringValue = total == 0 ? "" : "\(words) · \(minutes) min"
        }
    }

    // MARK: Files

    private func setText(_ s: String) {
        textView.resetVim()
        recording = false
        textView.string = s
        styler.restyleAll(textView.textStorage!)
        recording = true
        textView.typingAttributes = styler.baseAttributes
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        dirty = false
        updateWordCount()
        textView.updateFocusDim()
        updateLayout()
        if textView.vimEnabled { textView.clampNormal() }
    }

    private func setFile(_ url: URL) {
        fileURL = url
        window.title = isDraft ? "Draft" : url.lastPathComponent
        window.representedURL = isDraft ? nil : url
        defaults.set(url.path, forKey: "lastFile")
        if sidebarVisible {
            sidebar.current = url
            sidebar.reload(root: rootFolder)
        }
    }

    private func load(_ url: URL) {
        do {
            let s = try String(contentsOf: url, encoding: .utf8)
            history?.close(textView.string)
            setFile(url)
            setText(s)
            fileDate = Self.modDate(url)
            history = History(file: url, text: s)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func switchTo(_ url: URL) {
        if url.standardizedFileURL != fileURL?.standardizedFileURL {
            guard saveNow() else { return }
            load(url)
        }
        focusEditor()
    }

    private func newDraft() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = f.string(from: Date())
        var url = draftsDir.appendingPathComponent("Draft \(stamp).md")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = draftsDir.appendingPathComponent("Draft \(stamp)-\(i).md")
            i += 1
        }
        history?.close(textView.string)
        setFile(url)
        setText("")
        fileDate = nil
        history = History(file: url, text: "")
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.saveNow() }
    }

    /// Straight from the file system. (URL.resourceValues caches, which made
    /// every autosave after the first look like an outside edit.)
    private static func modDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Autosave. Empty drafts are never written. Returns false if the text
    /// could not be saved, so callers don't throw it away.
    @discardableResult
    private func saveNow() -> Bool {
        saveTimer?.invalidate()
        guard dirty, let url = fileURL else { return true }
        let s = textView.string
        if isDraft && s.isEmpty && !FileManager.default.fileExists(atPath: url.path) { return true }
        // another app (sync, other editor) changed the file since we read it
        if let known = fileDate, let disk = Self.modDate(url), disk.timeIntervalSince(known) > 0.5 {
            let a = NSAlert()
            a.messageText = "\(url.lastPathComponent) changed on disk"
            a.informativeText = "Another app edited this file while it was open here."
            a.addButton(withTitle: "Keep My Version")
            a.addButton(withTitle: "Load Theirs")
            if a.runModal() == .alertSecondButtonReturn {
                load(url)
                return true
            }
        }
        do {
            try s.write(to: url, atomically: true, encoding: .utf8)
            dirty = false
            fileDate = Self.modDate(url)
            history?.didSave(s)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    private func suggestedName() -> String {
        if !isDraft, let u = fileURL { return u.lastPathComponent }
        let first = textView.string.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var name = first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) } ?? ""
        name = String(name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(50))
        return (name.isEmpty ? "Untitled" : name) + ".md"
    }

    // MARK: Actions

    @objc func newDocument(_ sender: Any?) {
        guard saveNow() else { return }
        newDraft()
        focusEditor()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), .plainText].compactMap { $0 }
        panel.directoryURL = rootFolder
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            self.switchTo(url)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if isDraft { saveDocumentAs(sender); return }
        dirty = true
        saveNow()
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName()
        panel.directoryURL = rootFolder
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            let old = self.fileURL
            let wasDraft = self.isDraft
            do {
                try self.textView.string.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
            self.history?.move(to: url)
            // the draft now lives somewhere real; move the old copy to the Trash
            if wasDraft, let old, FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.trashItem(at: old, resultingItemURL: nil)
            }
            self.dirty = false
            self.setFile(url)
            self.fileDate = Self.modDate(url)
        }
    }

    @objc func showDrafts(_ sender: Any?) { NSWorkspace.shared.open(draftsDir) }

    /// Snapshots, newest first. Picking one replaces the text; ⌘Z undoes it.
    @objc func versionHistory(_ sender: Any?) {
        saveNow()
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let items = (history?.versions() ?? []).map { url, date -> PickerItem in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return PickerItem(title: df.string(from: date), detail: "\(countWords(text).formatted()) words",
                              action: { [weak self] in self?.restore(text) })
        }
        let p = showPicker("Restore a version (⌘Z undoes it)", items: items)
        p.emptyText = "No versions yet. One is kept when you open a file and every 5 minutes you write."
    }

    private func restore(_ text: String) {
        focusEditor()
        textView.resetVim()
        textView.replace(NSRange(location: 0, length: textView.ns.length), with: text)
        textView.setCursor(0)
    }

    /// Watch this piece being written, from the first recorded keystroke.
    @objc func replayWriting(_ sender: Any?) {
        guard let history else { return }
        saveNow()
        let events = history.events()
        guard events.contains(where: { !$0.start }) else {
            let p = showPicker("Replay", items: [])
            p.emptyText = "Nothing recorded for this file yet. Everything you type from now on can be replayed."
            return
        }
        picker?.close()
        hideShortcuts()
        let r = ReplayView(events: events, family: styler.family, fontSize: styler.fontSize)
        r.frame = root.bounds
        r.autoresizingMask = [.width, .height]
        r.onClose = { [weak self] in self?.focusEditor() }
        root.addSubview(r)
        window.makeFirstResponder(r)
    }

    @objc func toggleZen(_ sender: Any?) { window.toggleFullScreen(nil) }

    @objc func toggleTypewriter(_ sender: Any?) {
        textView.typewriter.toggle()
        defaults.set(textView.typewriter, forKey: "typewriter")
        updateLayout()
    }

    @objc func toggleFocus(_ sender: Any?) {
        textView.focusParagraph.toggle()
        defaults.set(textView.focusParagraph, forKey: "focusParagraph")
    }

    @objc func toggleVim(_ sender: Any?) {
        textView.vimEnabled.toggle()
        defaults.set(textView.vimEnabled, forKey: "vim")
    }

    @objc func toggleSmartPunctuation(_ sender: Any?) {
        textView.smartPunctuation.toggle()
        defaults.set(textView.smartPunctuation, forKey: "smartPunctuation")
    }

    // MARK: Export

    /// The selection, or the whole piece, ready to paste into Substack,
    /// Google Docs or Mail with formatting and without notes.
    @objc func copyRichText(_ sender: Any?) {
        let sel = textView.selectedRange()
        Export.copyRich(sel.length > 0 ? textView.ns.substring(with: sel) : textView.string)
        flash(sel.length > 0 ? "selection copied as rich text" : "copied as rich text")
    }

    @objc func exportPDF(_ sender: Any?) {
        chooseExport("pdf") { [weak self] url in
            guard let self else { return }
            let ok = Export.pdf(self.textView.string, title: self.exportTitle, to: url)
            self.flash(ok ? "exported \(url.lastPathComponent)" : "export failed")
        }
    }

    @objc func exportHTML(_ sender: Any?) {
        chooseExport("html") { [weak self] url in
            guard let self else { return }
            let html = Export.page(Export.html(self.textView.string), title: self.exportTitle)
            let ok = (try? html.write(to: url, atomically: true, encoding: .utf8)) != nil
            self.flash(ok ? "exported \(url.lastPathComponent)" : "export failed")
        }
    }

    private var exportTitle: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    private func chooseExport(_ ext: String, _ done: @escaping (URL) -> Void) {
        picker?.close()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext)!]
        panel.nameFieldStringValue = exportTitle + "." + ext
        if let dir = fileURL?.deletingLastPathComponent(), dir.standardizedFileURL != draftsDir.standardizedFileURL {
            panel.directoryURL = dir
        }
        panel.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let url = panel.url { done(url) }
            self?.focusEditor()
        }
    }

    private var flashTimer: Timer?

    /// Shows a short message where the word count sits.
    private func flash(_ message: String) {
        wordLabel.stringValue = message
        revealStatus()
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.updateWordCount()
        }
    }

    @objc func toggleSpelling(_ sender: Any?) {
        textView.isContinuousSpellCheckingEnabled.toggle()
        defaults.set(textView.isContinuousSpellCheckingEnabled, forKey: "spellcheck")
    }

    @objc func chooseFontFamily(_ sender: NSMenuItem) {
        styler.family = sender.tag
        defaults.set(sender.tag, forKey: "family")
        restyle()
    }

    @objc func biggerText(_ sender: Any?) { setFontSize(styler.fontSize + 1) }
    @objc func smallerText(_ sender: Any?) { setFontSize(styler.fontSize - 1) }
    @objc func actualSizeText(_ sender: Any?) { setFontSize(20) }

    private func setFontSize(_ size: CGFloat) {
        styler.fontSize = min(max(size, 12), 40)
        defaults.set(Double(styler.fontSize), forKey: "fontSize")
        restyle()
    }

    private func restyle() {
        styler.restyleAll(textView.textStorage!)
        textView.typingAttributes = styler.baseAttributes
        updateLayout()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleTypewriter(_:)): item.state = textView.typewriter ? .on : .off
        case #selector(toggleFocus(_:)): item.state = textView.focusParagraph ? .on : .off
        case #selector(toggleVim(_:)): item.state = textView.vimEnabled ? .on : .off
        case #selector(toggleZen(_:)): item.state = isFullScreen ? .on : .off
        case #selector(toggleFileBrowser(_:)): item.state = sidebarVisible ? .on : .off
        case #selector(toggleSmartPunctuation(_:)): item.state = textView.smartPunctuation ? .on : .off
        case #selector(toggleSpelling(_:)): item.state = textView.isContinuousSpellCheckingEnabled ? .on : .off
        case #selector(chooseFontFamily(_:)): item.state = item.tag == styler.family ? .on : .off
        default: break
        }
        return true
    }

    // MARK: Menu

    private func buildMenu() {
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            return top
        }
        let finder = #selector(NSResponder.performTextFinderAction(_:))
        let main = NSMenu()

        main.addItem(menu("Blackpage", [
            item("About Blackpage", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Blackpage", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Blackpage", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu("File", [
            item("New Draft", #selector(newDocument(_:)), "n"),
            item("Open…", #selector(openDocument(_:)), "o"),
            item("Find File…", #selector(findFile(_:)), "p"),
            item("Choose Browser Folder…", #selector(openFolder(_:)), "o", [.command, .shift]),
            .separator(),
            item("Save", #selector(saveDocument(_:)), "s"),
            item("Save As…", #selector(saveDocumentAs(_:)), "s", [.command, .shift]),
            .separator(),
            item("Version History…", #selector(versionHistory(_:))),
            item("Replay Writing", #selector(replayWriting(_:))),
            item("Show Drafts Folder", #selector(showDrafts(_:))),
            .separator(),
            item("Copy as Rich Text", #selector(copyRichText(_:)), "c", [.command, .shift]),
            item("Export PDF…", #selector(exportPDF(_:)), "e", [.command, .shift]),
            item("Export HTML…", #selector(exportHTML(_:))),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Search Document…", #selector(searchDocument(_:)), "f"),
            item("Jump to Note…", #selector(listNotes(_:)), "j"),
            item("Next Note", #selector(nextNote(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            item("Previous Note", #selector(previousNote(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item("Find and Replace…", finder, "f", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue),
            item("Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue),
            item("Find Previous", finder, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue),
        ]))
        main.addItem(menu("Format", [
            item("Bold", #selector(ZenTextView.markdownBold(_:)), "b"),
            item("Italic", #selector(ZenTextView.markdownItalic(_:)), "i"),
            .separator(),
            item("Add Note", #selector(ZenTextView.insertNote(_:)), "'"),
            .separator(),
            item("Indent", #selector(ZenTextView.indentLines(_:)), "]"),
            item("Outdent", #selector(ZenTextView.outdentLines(_:)), "["),
        ]))
        main.addItem(menu("View", [
            item("Command Palette…", #selector(commandPalette(_:)), "k"),
            item("File Browser", #selector(toggleFileBrowser(_:)), "e"),
            item("Zen Mode", #selector(toggleZen(_:)), "\r"),
            .separator(),
            item("Typewriter Scrolling", #selector(toggleTypewriter(_:)), "t"),
            item("Dim Other Paragraphs", #selector(toggleFocus(_:)), "d", [.command, .shift]),
            item("Spell Check", #selector(toggleSpelling(_:)), ";"),
            item("Smart Punctuation", #selector(toggleSmartPunctuation(_:))),
            item("Vim Keys", #selector(toggleVim(_:)), "v", [.command, .control]),
            .separator(),
            menu("Font", MarkdownStyler.familyNames.enumerated().map { i, name in
                item(name, #selector(chooseFontFamily(_:)), tag: i)
            }),
            item("Bigger", #selector(biggerText(_:)), "="),
            item("Smaller", #selector(smallerText(_:)), "-"),
            item("Actual Size", #selector(actualSizeText(_:)), "0"),
        ]))
        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        main.addItem(windowMenu)
        let helpMenu = menu("Help", [
            item("Keyboard Shortcuts", #selector(toggleShortcuts(_:)), "/"),
        ])
        main.addItem(helpMenu)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu.submenu
        NSApp.helpMenu = helpMenu.submenu
    }
}
