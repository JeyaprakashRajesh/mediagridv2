import Foundation

/// Cleans up artist tags: one artist, one name, however the files spell it.
/// "A. R. Rahman", "A R Rahman", "AR Rahman" and "a.r.rahman" all become the spelling used most in your library.
enum ArtistNames {
    /// "A.R. Rahman feat. Hariharan & Sadhana Sargam" -> ["A.R. Rahman", "Hariharan", "Sadhana Sargam"]
    static func split(_ raw: String) -> [String] {
        var s = raw
        for sep in [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " & ", "&", " / ", ";"] {
            s = s.replacingOccurrences(of: sep, with: ",", options: .caseInsensitive)
        }
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? [raw] : parts
    }

    /// Spelling-independent key: lower case, no accents or punctuation, initials joined ("a r rahman" -> "ar rahman").
    static func key(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var tokens = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").map(String.init)
        if tokens.count > 1, tokens[0] == "the" { tokens.removeFirst() }
        var out: [String] = []
        var run = ""
        for t in tokens {
            if t.count == 1 { run += t } else { if !run.isEmpty { out.append(run); run = "" }; out.append(t) }
        }
        if !run.isEmpty { out.append(run) }
        return out.joined(separator: " ")
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Same artist? Same words in any order, or one typo in a longer name ("Yuvan Shankar Raja" / "Yuvan Shankar Rajaa").
    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let n = max(a.count, b.count)
        guard n >= 8, abs(a.count - b.count) <= 2 else { return false }
        return levenshtein(Array(a), Array(b)) <= (n >= 14 ? 2 : 1)
    }

    static func canonicalize(_ tracks: [Track]) -> [Track] {
        var variants: [String: [String: Int]] = [:]          // key -> spelling -> songs
        for t in tracks { for n in split(t.artist) { variants[key(n), default: [:]][n, default: 0] += 1 } }
        let keys = Array(variants.keys)
        let sorted = keys.map { $0.split(separator: " ").sorted().joined(separator: " ") }   // word order doesn't matter
        var parent = Array(0..<keys.count)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        for i in keys.indices {
            for j in (i + 1)..<keys.count where sorted[i].first == sorted[j].first && same(sorted[i], sorted[j]) {
                parent[find(i)] = find(j)
            }
        }
        // per cluster, the spelling used by the most songs wins
        var tally: [Int: [String: Int]] = [:]
        for (i, k) in keys.enumerated() { for (spelling, n) in variants[k] ?? [:] { tally[find(i), default: [:]][spelling, default: 0] += n } }
        var canon: [String: String] = [:]
        for (i, k) in keys.enumerated() {
            if let best = tally[find(i)]?.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) { canon[k] = best.key }
        }
        return tracks.map { t in
            var t = t
            var seen = Set<String>()
            let names = split(t.artist).map { canon[key($0)] ?? $0 }.filter { seen.insert($0).inserted }
            t.artist = names.joined(separator: ", ")
            return t
        }
    }
}

/// Turns the PC's audio measurements (tempo, energy, punch) into a mood/genre label.
/// Tempo uses fixed limits; energy and punch are ranked against the rest of your library, so it works for any collection.
enum Genres {
    static func classify(_ tracks: [Track]) -> [Track] {
        let e = tracks.compactMap(\.energy).sorted(), p = tracks.compactMap(\.punch).sorted()
        guard e.count >= 8 else { return tracks }
        func rank(_ a: [Double], _ x: Double) -> Double { Double(a.firstIndex { $0 >= x } ?? a.count) / Double(a.count) }
        return tracks.map { t in
            var t = t
            if let bpm = t.bpm, let en = t.energy, let pu = t.punch {
                let er = rank(e, en), pr = rank(p, pu)
                t.genre = er <= 0.25 && bpm < 100 ? "Chill"
                    : er >= 0.75 && bpm >= 110 ? "Energetic"
                    : bpm >= 100 && pr >= 0.6 ? "Dance"
                    : bpm < 105 ? "Melody"
                    : "Upbeat"
            }
            return t
        }
    }

    static let symbols = ["Melody": "music.quarternote.3", "Chill": "leaf.fill", "Dance": "figure.socialdance", "Energetic": "bolt.fill", "Upbeat": "sun.max.fill"]
}
