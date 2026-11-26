import CryptoKit
import Foundation

/// Per-file history in ~/Library/Application Support/Blackpage/History/<hash>/
///   versions/<date>.md     snapshot on open, every 5 min of writing, on close
///   sessions/<ms>.lzfse    every edit of one writing session, for replay
///   path.txt               which file this is
///
/// Session format, one line each, tab separated, text escaped:
///   S  <unix time>  <text at session start>
///   <ms since previous>  <location>  <chars deleted>  <text inserted>
/// Typing costs ~14 bytes a keystroke before compression; a finished
/// session is LZFSE-compressed (~4-5x smaller).
final class History {
    struct Event {
        var t: Double
        var start: Bool
        var l = 0
        var d = 0
        var s = ""
    }

    static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Blackpage/History", isDirectory: true)

    private(set) var dir: URL
    private var file: URL
    private var base: String
    private var pending: [String] = []
    private var session: URL?
    private var lastT = 0.0
    private var lastSnapshot = Date()
    private var lastSnapshotText: String?

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    static func dir(for file: URL) -> URL {
        let hash = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8))
        return root.appendingPathComponent(hash.prefix(8).map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    init(file: URL, text: String) {
        self.file = file
        self.dir = History.dir(for: file)
        self.base = text
        compressLeftovers()
        lastSnapshotText = versions().first.flatMap { try? String(contentsOf: $0.0, encoding: .utf8) }
        if !text.isEmpty && text != lastSnapshotText { snapshot(text) }
    }

    private var versionsDir: URL { dir.appendingPathComponent("versions", isDirectory: true) }
    private var sessionsDir: URL { dir.appendingPathComponent("sessions", isDirectory: true) }

    private func ensureDirs() {
        guard !FileManager.default.fileExists(atPath: sessionsDir.path) else { return }
        try? FileManager.default.createDirectory(at: versionsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try? file.path.write(to: dir.appendingPathComponent("path.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Recording

    /// `range` is the edited range after the edit, `delta` the change in length.
    func recordEdit(range: NSRange, delta: Int, inserted: String) {
        let now = Date().timeIntervalSince1970
        if session == nil {
            session = sessionsDir.appendingPathComponent("\(Int(now * 1000)).txt")
            pending.append("S\t\(now)\t\(Self.esc(base))")
            lastT = now
        }
        let dt = max(0, Int(((now - lastT) * 1000).rounded()))
        lastT = now
        pending.append("\(dt)\t\(range.location)\t\(range.length - delta)\t\(Self.esc(inserted))")
    }

    func flush() {
        guard !pending.isEmpty, let session else { return }
        ensureDirs()
        let data = Data((pending.joined(separator: "\n") + "\n").utf8)
        pending.removeAll()
        if !FileManager.default.fileExists(atPath: session.path) {
            FileManager.default.createFile(atPath: session.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: session) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        }
    }

    /// After each autosave: flush the journal, snapshot every 5 minutes.
    func didSave(_ text: String) {
        flush()
        if Date().timeIntervalSince(lastSnapshot) >= 300 && text != lastSnapshotText && !text.isEmpty {
            snapshot(text)
        }
    }

    /// When the file is closed or the app quits.
    func close(_ text: String) {
        flush()
        if let session { compress(session) }
        session = nil
        if text != lastSnapshotText && !text.isEmpty { snapshot(text) }
    }

    /// Save As: carry the history over to the new path.
    func move(to newFile: URL) {
        flush()
        let newDir = History.dir(for: newFile)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) && !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: dir, to: newDir)
        }
        if let s = session { session = newDir.appendingPathComponent("sessions").appendingPathComponent(s.lastPathComponent) }
        dir = newDir
        file = newFile
        if fm.fileExists(atPath: dir.path) {
            try? newFile.path.write(to: dir.appendingPathComponent("path.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func compress(_ raw: URL) {
        guard let data = try? Data(contentsOf: raw),
              let z = try? (data as NSData).compressed(using: .lzfse) as Data else { return }
        let out = raw.deletingPathExtension().appendingPathExtension("lzfse")
        if (try? z.write(to: out, options: .atomic)) != nil {
            try? FileManager.default.removeItem(at: raw)
        }
    }

    /// Sessions left raw by a crash get compressed next time.
    private func compressLeftovers() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        for u in urls where u.pathExtension == "txt" { compress(u) }
    }

    private func snapshot(_ text: String) {
        ensureDirs()
        let url = versionsDir.appendingPathComponent(History.stamp.string(from: Date()) + ".md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        lastSnapshotText = text
        lastSnapshot = Date()
        thinVersions()
    }

    /// Keep the newest 50 snapshots, then one per day.
    private func thinVersions() {
        var seenDays = Set<Date>()
        for (i, (url, date)) in versions().enumerated() where i >= 50 {
            let day = Calendar.current.startOfDay(for: date)
            if seenDays.contains(day) {
                try? FileManager.default.removeItem(at: url)
            } else {
                seenDays.insert(day)
            }
        }
    }

    // MARK: Reading

    /// Newest first.
    func versions() -> [(URL, Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { u in
            History.stamp.date(from: u.deletingPathExtension().lastPathComponent).map { (u, $0) }
        }.sorted { $0.1 > $1.1 }
    }

    /// Every recorded edit of this file, oldest first.
    func events() -> [Event] {
        flush()
        let urls = ((try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [Event] = []
        for u in urls {
            guard var data = try? Data(contentsOf: u) else { continue }
            if u.pathExtension == "lzfse" {
                guard let raw = try? (data as NSData).decompressed(using: .lzfse) as Data else { continue }
                data = raw
            }
            var t = 0.0
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let p = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                if p.first == "S", p.count == 3 {
                    t = Double(p[1]) ?? t
                    out.append(Event(t: t, start: true, s: Self.unesc(p[2])))
                } else if p.count == 4, let dt = Int(p[0]), let l = Int(p[1]), let d = Int(p[2]) {
                    t += Double(dt) / 1000
                    out.append(Event(t: t, start: false, l: l, d: d, s: Self.unesc(p[3])))
                }
            }
        }
        return out
    }

    // MARK: Escaping

    static func esc(_ s: String) -> String {
        guard s.contains(where: { $0 == "\\" || $0 == "\n" || $0 == "\t" || $0 == "\r" || $0 == "\r\n" }) else { return s }
        var o = ""
        for u in s.unicodeScalars {
            switch u {
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\t": o += "\\t"
            case "\r": o += "\\r"
            default: o.unicodeScalars.append(u)
            }
        }
        return o
    }

    static func unesc<S: StringProtocol>(_ s: S) -> String {
        guard s.contains("\\") else { return String(s) }
        var o = ""
        var it = s.unicodeScalars.makeIterator()
        while let u = it.next() {
            guard u == "\\", let n = it.next() else { o.unicodeScalars.append(u); continue }
            switch n {
            case "n": o += "\n"
            case "t": o += "\t"
            case "r": o += "\r"
            default: o.unicodeScalars.append(n)
            }
        }
        return o
    }
}
