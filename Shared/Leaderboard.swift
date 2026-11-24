import Foundation
import AppIntents
import SwiftUI

// MARK: - Data model (mirrors https://www.benchleader.com/data/leaderboard.json)

struct LeaderboardFile: Codable, Hashable {
    let asOf: String
    let generatedAt: String?
    let rows: [ModelRow]
}

struct ModelRow: Codable, Hashable, Identifiable {
    let rank: Int
    let model: String
    let effort: String?
    let configurationId: String
    let provider: String
    let openWeights: Bool?
    let index: Double?
    let indexCi: Double?
    let reasoning: Double?
    let coding: Double?
    let agentic: Double?
    let math: Double?
    let knowledge: Double?
    let priceBlendedUsdPerMtok: Double?
    let outputTokensPerSecond: Double?
    let url: String?

    var id: String { configurationId }
}

/// A row as displayed: its position in the chosen ranking plus the score shown.
struct RankedRow: Hashable, Identifiable {
    let position: Int
    let row: ModelRow
    let score: Double
    var id: String { row.id }
}

// MARK: - Rankings

enum Ranking: String, CaseIterable, AppEnum {
    case index, coding, agentic, reasoning, math, knowledge, speed, value

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Ranking" }
    static var caseDisplayRepresentations: [Ranking: DisplayRepresentation] {
        [
            .index: "Overall (BenchLeader Index)",
            .coding: "Coding",
            .agentic: "Agents",
            .reasoning: "Reasoning",
            .math: "Math",
            .knowledge: "Knowledge",
            .speed: "Speed (tokens/s)",
            .value: "Value (index per $)",
        ]
    }

    var shortTitle: String {
        switch self {
        case .index: "Overall"
        case .coding: "Coding"
        case .agentic: "Agents"
        case .reasoning: "Reasoning"
        case .math: "Math"
        case .knowledge: "Knowledge"
        case .speed: "Speed"
        case .value: "Value"
        }
    }

    func score(_ r: ModelRow) -> Double? {
        switch self {
        case .index: r.index
        case .coding: r.coding
        case .agentic: r.agentic
        case .reasoning: r.reasoning
        case .math: r.math
        case .knowledge: r.knowledge
        case .speed: r.outputTokensPerSecond
        case .value:
            if let i = r.index, let p = r.priceBlendedUsdPerMtok, p > 0 { i / p } else { nil }
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .speed: String(format: "%.0f t/s", v)
        case .value: String(format: "%.1f/$", v)
        default: String(format: "%.1f", v)
        }
    }

    func rank(_ rows: [ModelRow], openWeightsOnly: Bool = false) -> [RankedRow] {
        let pool = rows.filter { !openWeightsOnly || ($0.openWeights ?? false) }
        let scored: [(ModelRow, Double)] = pool.compactMap { r in score(r).map { (r, $0) } }
        let sorted = self == .index
            ? scored.sorted { $0.0.rank < $1.0.rank }
            : scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rank < $1.0.rank }
        return sorted.enumerated().map { RankedRow(position: $0.offset + 1, row: $0.element.0, score: $0.element.1) }
    }
}

// MARK: - Search

/// Matches rows against a search like "claude", "sonnet 5.5", "OpenAI max" or "anthropic, google".
///
/// - Commas separate alternatives: a row matches if it matches any of them.
/// - Within one alternative, every word must match the model name, provider, effort or configuration id.
/// - Case, accents and punctuation are ignored, so "gpt6" matches "GPT-6" and "opus 5.5" matches "Opus 5.5".
/// - A word that is only a number (like "4" or "5.5") must match a whole version number:
///   "llama 4" finds Llama 4 and Llama 4.1, but not Llama 3.1 405B.
struct ModelSearch {
    private enum Term {
        case text(String)    // normalized; matched anywhere
        case number(String)  // like "4" or "5.5"; matched against version numbers
    }

    private let alternatives: [[Term]]
    /// The original words of each comma-separated alternative, for sources that also search on their server.
    let rawAlternatives: [[String]]

    init(_ query: String) {
        let raw = query
            .split(separator: ",")
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        rawAlternatives = raw.filter { words in words.contains { !Self.normalize($0).isEmpty } }
        alternatives = raw
            .map { words in words.compactMap(Self.term) }
            .filter { !$0.isEmpty }
    }

    var isEmpty: Bool { alternatives.isEmpty }

    /// `text` is everything searchable about a row (name, provider, effort…). Numbers are only looked for
    /// in `versionsFrom` (the model's name) when given, so an organisation like "HuggingFaceM4" isn't a "4".
    func matches(_ text: String, versionsFrom: String? = nil) -> Bool {
        if isEmpty { return true }
        let haystack = Self.normalize(text)
        let numbers = Self.versionNumbers(in: versionsFrom ?? text)
        return alternatives.contains { terms in
            terms.allSatisfy { term in
                switch term {
                case .text(let t): haystack.contains(t)
                case .number(let n): numbers.contains { $0 == n || $0.hasPrefix(n + ".") }
                }
            }
        }
    }

    private static func term(_ word: String) -> Term? {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: ".-_()"))
        let isNumber = !trimmed.isEmpty && trimmed.first!.isNumber
            && trimmed.allSatisfy { $0.isNumber || $0 == "." } && !trimmed.contains("..")
        if isNumber { return .number(trimmed) }
        let n = normalize(word)
        return n.isEmpty ? nil : .text(n)
    }

    private static let versionPattern = try! NSRegularExpression(pattern: "(?<![a-z\\d.])(\\d+(?:\\.\\d+)*)([a-z]*)")

    /// Version numbers in a name: "Llama-3.1-405B-4bit" → ["3.1"], "GPT-4o" → ["4"].
    /// Numbers glued to letters are sizes or quantization ("405B", "4bit", "INT4", "Q4_K_M", "FP8") and
    /// don't count, except a trailing "o" as in GPT-4o. Names like "Qwen3" are still found by typing "qwen3".
    private static func versionNumbers(in text: String) -> [String] {
        let s = text.lowercased()
        let ns = s as NSString
        return versionPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let suffix = ns.substring(with: m.range(at: 2))
            return suffix.isEmpty || suffix == "o" ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    /// Lowercased, accent-free, letters and digits only.
    private static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

// MARK: - Fetching

enum LeaderboardAPI {
    static let endpoint = URL(string: "https://www.benchleader.com/data/leaderboard.json")!
    static let homepage = URL(string: "https://www.benchleader.com")!

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("benchleader-leaderboard.json")
    }

    static func fetch() async throws -> LeaderboardFile {
        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("BenchLeaderMacWidget/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let file = try decoder.decode(LeaderboardFile.self, from: data)
        try? data.write(to: cacheURL, options: .atomic)
        return file
    }

    static func cached() -> LeaderboardFile? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? decoder.decode(LeaderboardFile.self, from: data)
    }
}

// MARK: - Styling helpers

enum ProviderStyle {
    static func color(_ provider: String) -> Color {
        switch provider.lowercased() {
        case "anthropic": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "google": Color(red: 0.26, green: 0.52, blue: 0.96)
        case "openai": Color(red: 0.10, green: 0.65, blue: 0.50)
        case "meta": Color(red: 0.0, green: 0.45, blue: 0.85).opacity(0.8)
        case "alibaba": Color.orange
        case "moonshot ai": Color.indigo
        case "spacexai", "xai": Color.gray
        case "deepseek": Color.blue
        case "zhipu ai": Color.teal
        case "mistral": Color(red: 0.98, green: 0.36, blue: 0.13)
        case "nvidia": Color(red: 0.46, green: 0.73, blue: 0.0)
        case "microsoft": Color.cyan
        case "hugging face": Color.yellow
        case "minimax": Color.pink
        case "tencent", "bytedance": Color.mint
        default: Color.purple
        }
    }
}
