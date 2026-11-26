import AppKit

/// Plays a file's edit journal back on a read-only page. Pauses longer
/// than 1.5s are squeezed out, so you watch the writing, not the thinking.
final class ReplayView: NSView {
    var onClose: (() -> Void)?

    private let styler = MarkdownStyler()
    private let scroll = NSScrollView()
    private var tv: ZenTextView!
    private let caret = NSView()
    private let status = NSTextField(labelWithString: "")
    private let bar = NSView()
    private let fill = NSView()

    private let events: [History.Event]
    private var times: [Double] = []  // compressed playback time of each event
    private var idx = 0
    private var clock = 0.0
    private var speed = 4.0
    private var paused = false
    private var caretLoc = 0
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var total: Double { times.last ?? 0 }

    init(events: [History.Event], family: Int, fontSize: CGFloat) {
        self.events = events
        var t = 0.0
        var prev: Double?
        for e in events {
            if let p = prev { t += min(max(e.t - p, 0), 1.5) }
            times.append(t)
            prev = e.t
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        styler.family = family
        styler.fontSize = fontSize
        let storage = NSTextStorage()
        storage.delegate = styler
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = true
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        tv = ZenTextView(frame: .zero, textContainer: tc)
        tv.isEditable = false
        tv.isSelectable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.backgroundColor = .black
        tv.typewriter = true

        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        scroll.hasVerticalScroller = false
        scroll.documentView = tv
        addSubview(scroll)

        caret.wantsLayer = true
        caret.layer?.backgroundColor = Theme.accent.cgColor
        tv.addSubview(caret)

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        fill.wantsLayer = true
        fill.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.7).cgColor
        bar.addSubview(fill)
        addSubview(bar)
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = NSColor(white: 0.4, alpha: 1)
        addSubview(status)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        scroll.frame = bounds
        let w = scroll.contentSize.width
        let column = min(styler.fontSize * 34, w - 64)
        tv.frame.size.width = w
        tv.minSize = NSSize(width: 0, height: size.height)
        tv.textContainerInset = NSSize(width: max(32, floor((w - column) / 2)), height: floor(size.height / 2))
        bar.frame = NSRect(x: 0, y: 0, width: size.width, height: 2)
        status.frame = NSRect(x: 16, y: 10, width: size.width - 32, height: 16)
        render()
    }

    // MARK: Playback

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        guard !paused else { return }
        advance(to: clock + dt * speed)
        if idx >= events.count { paused = true }
        render()
    }

    private func advance(to target: Double) {
        clock = min(target, total)
        while idx < events.count && times[idx] <= clock {
            apply(events[idx])
            idx += 1
        }
    }

    private func seek(to target: Double) {
        let t = max(0, min(target, total))
        if t < clock {
            tv.textStorage?.setAttributedString(NSAttributedString(string: ""))
            idx = 0
            clock = 0
        }
        advance(to: t)
        render()
    }

    private func apply(_ e: History.Event) {
        guard let ts = tv.textStorage else { return }
        let s = e.s
        if e.start {
            ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: s)
            caretLoc = 0
        } else {
            let l = e.l, d = e.d
            guard l >= 0, d >= 0, l + d <= ts.length else { return }  // journal out of sync: skip
            ts.replaceCharacters(in: NSRange(location: l, length: d), with: s)
            caretLoc = l + (s as NSString).length
        }
    }

    private func render() {
        guard let win = window, let ts = tv.textStorage else { return }
        let loc = min(caretLoc, ts.length)
        tv.centerCaret(at: loc, animated: false)
        let screen = tv.firstRect(forCharacterRange: NSRange(location: loc, length: 0), actualRange: nil)
        let r = tv.convert(win.convertFromScreen(screen), from: nil)
        caret.frame = NSRect(x: r.minX, y: r.minY, width: 2, height: max(r.height, styler.fontSize))

        fill.frame = NSRect(x: 0, y: 0, width: total > 0 ? bar.bounds.width * clock / total : 0, height: 2)
        let state = idx >= events.count ? "done" : (paused ? "paused" : "\(Int(speed))×")
        status.stringValue = "replay  \(state)   \(Self.time(clock)) / \(Self.time(total))"
            + "      space pause   1 2 3 4 speed   ← → skip   esc close"
    }

    private static func time(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    // MARK: Input

    override func keyDown(with e: NSEvent) {
        switch (e.keyCode, e.charactersIgnoringModifiers ?? "") {
        case (53, _): close()
        case (_, " "):
            if idx >= events.count { seek(to: 0) }
            paused.toggle()
            lastTick = CACurrentMediaTime()
        case (_, "1"): speed = 1
        case (_, "2"): speed = 4
        case (_, "3"): speed = 16
        case (_, "4"): speed = 64
        case (123, _): seek(to: clock - 30)
        case (124, _): seek(to: clock + 30)
        default: super.keyDown(with: e)
        }
        render()
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if p.y < 24 && total > 0 { seek(to: total * Double(p.x / bounds.width)) }  // click the bar to scrub
    }

    func close() {
        timer?.invalidate()
        timer = nil
        removeFromSuperview()
        onClose?()
    }
}
