import Foundation

/// fzf-style subsequence matching. Space-separated terms must all match.
/// Scores reward consecutive characters and word starts, punish gaps.
enum Fuzzy {
    struct Match {
        let score: Int
        let indices: [Int]  // UTF-16 offsets into the candidate
    }

    static func match(_ query: String, in candidate: String) -> Match? {
        let terms = query.split(separator: " ").map { Array(String($0).utf16).map(lower) }
        guard !terms.isEmpty else { return Match(score: 0, indices: []) }
        let orig = Array(candidate.utf16)
        let c = orig.map(lower)
        var total = 0
        var all: [Int] = []
        for t in terms {
            guard let m = best(t, c, orig) else { return nil }
            total += m.score
            all += m.indices
        }
        return Match(score: total, indices: all.sorted())
    }

    private static func lower(_ u: UInt16) -> UInt16 { (65...90).contains(u) ? u + 32 : u }

    /// Try every start position of the first character, keep the tightest match.
    private static func best(_ q: [UInt16], _ c: [UInt16], _ orig: [UInt16]) -> Match? {
        guard let first = q.first else { return nil }
        var best: Match?
        var start = 0
        var tries = 0
        while start < c.count && tries < 200 {
            guard let s = c[start...].firstIndex(of: first) else { break }
            tries += 1
            var idx = [s]
            var j = s + 1
            var ok = true
            for ch in q.dropFirst() {
                while j < c.count && c[j] != ch { j += 1 }
                if j >= c.count { ok = false; break }
                idx.append(j)
                j += 1
            }
            if !ok { break }  // fails from here means fails from any later start
            let sc = score(idx, orig)
            if best == nil || sc > best!.score { best = Match(score: sc, indices: idx) }
            start = s + 1
        }
        return best
    }

    private static func score(_ idx: [Int], _ orig: [UInt16]) -> Int {
        var s = 0
        for (k, i) in idx.enumerated() {
            s += 16
            if k > 0 {
                let gap = i - idx[k - 1] - 1
                s += gap == 0 ? 24 : -min(gap, 24)
            }
            if i == 0 || isBoundary(orig[i - 1]) || (isUpper(orig[i]) && !isUpper(orig[i - 1])) { s += 18 }
        }
        s -= min(idx[0], 30) / 3
        return s
    }

    private static func isUpper(_ u: UInt16) -> Bool { (65...90).contains(u) }

    private static func isBoundary(_ u: UInt16) -> Bool {
        // space / - _ . tab newline ( " '
        [32, 47, 45, 95, 46, 9, 10, 40, 34, 39].contains(u)
    }
}
