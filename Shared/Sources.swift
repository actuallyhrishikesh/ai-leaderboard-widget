import Foundation

// MARK: - Data sources

// Plain enums on purpose, like Ranking: see Widget/WidgetSettings.swift.
enum DataSource: String, CaseIterable {
    case benchleader, lmarena, huggingface

    var shortName: String {
        switch self {
        case .benchleader: "BenchLeader"
        case .lmarena: "LMArena"
        case .huggingface: "Hugging Face"
        }
    }

    var homepage: URL {
        switch self {
        case .benchleader: LeaderboardAPI.homepage
        case .lmarena: URL(string: "https://lmarena.ai/leaderboard")!
        case .huggingface: URL(string: "https://huggingface.co/models?pipeline_tag=text-generation&sort=trending")!
        }
    }

    /// Whether "open weights only" means anything for this source (every Hub model is open).
    var supportsOpenWeightsFilter: Bool { self != .huggingface }
}

/// LMArena text-leaderboard categories (a subset of what the dataset publishes).
enum ArenaCategory: String, CaseIterable {
    case overall, coding, math, expert, english
    case creativeWriting = "creative_writing"
    case hardPrompts = "hard_prompts"
    case instructionFollowing = "instruction_following"
    case multiTurn = "multi_turn"
    case longerQuery = "longer_query"
    case nonEnglish = "non_english"

    var shortTitle: String {
        switch self {
        case .overall: "Overall"
        case .coding: "Coding"
        case .math: "Math"
        case .expert: "Expert"
        case .english: "English"
        case .creativeWriting: "Creative writing"
        case .hardPrompts: "Hard prompts"
        case .instructionFollowing: "Instruction following"
        case .multiTurn: "Multi-turn"
        case .longerQuery: "Longer queries"
        case .nonEnglish: "Non-English"
        }
    }
}

/// How Hugging Face Hub models are ordered.
enum HubSort: String, CaseIterable {
    case trending = "trendingScore"
    case downloads, likes

    var shortTitle: String {
        switch self {
        case .trending: "Trending"
        case .downloads: "Downloads"
        case .likes: "Likes"
        }
    }
}

// MARK: - Common board format (what the app and widget display)

struct BoardRow: Hashable, Identifiable {
    let id: String
    let position: Int
    let name: String
    let badge: String?
    let provider: String
    let score: Double
    let scoreText: String
    let subtitle: String
    /// Three extra values shown as table columns in the app; titles come from `Board.metricTitles`.
    let metrics: [String]
    let url: URL?
    let searchText: String
}

struct Board: Hashable {
    let source: DataSource
    let rankingTitle: String
    let scoreTitle: String
    let asOf: String
    let metricTitles: [String]
    let rows: [BoardRow]
    let credit: String

    /// Keeps each row's position, so a search for "claude" still shows where each model stands.
    func filtered(by search: ModelSearch) -> Board {
        guard !search.isEmpty else { return self }
        return Board(source: source, rankingTitle: rankingTitle, scoreTitle: scoreTitle, asOf: asOf,
                     metricTitles: metricTitles,
                     rows: rows.filter { search.matches($0.searchText, versionsFrom: $0.name) }, credit: credit)
    }
}

/// Everything that decides which board to show.
struct BoardRequest: Hashable {
    var source: DataSource = .benchleader
    var ranking: Ranking = .index
    var arenaCategory: ArenaCategory = .overall
    var hubSort: HubSort = .trending
    var openWeightsOnly = false
}

// MARK: - Loading

enum BoardLoader {
    /// Loads a board, falling back to the last saved copy when offline. `fresh` is false for a saved copy.
    /// `needsAllRows` is false when only the top of the list will be shown (widgets without filters).
    static func load(_ req: BoardRequest, needsAllRows: Bool = true) async -> (board: Board?, fresh: Bool) {
        switch req.source {
        case .benchleader:
            let fetched = try? await LeaderboardAPI.fetch()
            guard let file = fetched ?? LeaderboardAPI.cached() else { return (nil, false) }
            return (benchleaderBoard(file, req), fetched != nil)
        case .lmarena:
            let pages = needsAllRows || req.openWeightsOnly ? nil : 1
            let fetched = try? await ArenaAPI.fetch(req.arenaCategory, maxPages: pages)
            guard let rows = fetched ?? ArenaAPI.cached(req.arenaCategory) else { return (nil, false) }
            return (arenaBoard(rows, req), fetched != nil)
        case .huggingface:
            let fetched = try? await HubAPI.fetch(sort: req.hubSort)
            guard let models = fetched ?? HubAPI.cached(req.hubSort) else { return (nil, false) }
            return (hubBoard(models, sort: req.hubSort, positionsAreRanks: true), fetched != nil)
        }
    }

    /// Hugging Face has far more models than one list can hold, so searches go to the Hub itself.
    static func hubSearch(_ search: ModelSearch, sort: HubSort) async throws -> Board {
        let models = try await HubAPI.search(search, sort: sort)
        return hubBoard(models, sort: sort, positionsAreRanks: false)
    }

    // MARK: BenchLeader

    static func benchleaderBoard(_ file: LeaderboardFile, _ req: BoardRequest) -> Board {
        let ranking = req.ranking
        let rows = ranking.rank(file.rows, openWeightsOnly: req.openWeightsOnly).map { r -> BoardRow in
            let m = r.row
            var sub = [m.provider]
            if let p = m.priceBlendedUsdPerMtok { sub.append(String(format: "$%.2f/M", p)) }
            if ranking != .index, let i = m.index { sub.append(String(format: "idx %.1f", i)) }
            return BoardRow(
                id: m.id, position: r.position, name: m.model, badge: m.effort, provider: m.provider,
                score: r.score, scoreText: ranking.format(r.score), subtitle: sub.joined(separator: " · "),
                metrics: [
                    m.index.map { String(format: "%.1f ±%.1f", $0, m.indexCi ?? 0) } ?? "—",
                    m.priceBlendedUsdPerMtok.map { String(format: "$%.2f", $0) } ?? "—",
                    m.outputTokensPerSecond.map { String(format: "%.0f t/s", $0) } ?? "—",
                ],
                url: m.url.flatMap(URL.init(string:)),
                // Not the configuration id: it writes versions with dashes ("gpt-5-6"), which would
                // make a search for "gpt 6" match GPT-5.6.
                searchText: [m.model, m.provider, m.effort ?? ""].joined(separator: " "))
        }
        return Board(source: .benchleader, rankingTitle: ranking.shortTitle, scoreTitle: ranking.shortTitle,
                     asOf: file.asOf, metricTitles: ["Index", "$/M (blended)", "Speed"], rows: rows,
                     credit: "Source: BenchLeader (CC BY 4.0)")
    }

    // MARK: LMArena

    static func arenaBoard(_ all: [ArenaRow], _ req: BoardRequest) -> Board {
        let pool = all
            .filter { !req.openWeightsOnly || $0.isOpenLicense }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.rating > $1.rating }
        let rows = pool.map { a -> BoardRow in
            let (name, badge) = splitEffort(a.modelName)
            let provider = ProviderNames.display(a.organization)
            let votes = a.voteCount.map { Formatters.compact($0) } ?? "—"
            let ci = (a.ratingUpper != nil && a.ratingLower != nil) ? (a.ratingUpper! - a.ratingLower!) / 2 : nil
            return BoardRow(
                id: a.modelName, position: Int(a.rank), name: name, badge: badge, provider: provider,
                score: a.rating, scoreText: String(format: "%.0f", a.rating),
                subtitle: "\(provider) · \(votes) votes",
                metrics: [ci.map { String(format: "±%.0f", $0) } ?? "—", votes, a.license ?? "—"],
                url: URL(string: "https://lmarena.ai/leaderboard/text"),
                searchText: [a.modelName, a.organization ?? "", provider, a.license ?? ""].joined(separator: " "))
        }
        return Board(source: .lmarena, rankingTitle: req.arenaCategory.shortTitle, scoreTitle: "Arena score",
                     asOf: all.first?.leaderboardPublishDate ?? "—", metricTitles: ["95% range", "Votes", "Licence"],
                     rows: rows, credit: "Source: LMArena (CC BY 4.0), via Hugging Face")
    }

    /// "Gemini 4 Carbon (High)" → ("Gemini 4 Carbon", "high")
    static func splitEffort(_ name: String) -> (String, String?) {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "("), open > name.startIndex else { return (name, nil) }
        let base = name[..<open].trimmingCharacters(in: .whitespaces)
        let inner = name[name.index(after: open)..<name.index(before: name.endIndex)]
        return base.isEmpty ? (name, nil) : (base, inner.lowercased())
    }

    // MARK: Hugging Face Hub

    static func hubBoard(_ models: [HubModel], sort: HubSort, positionsAreRanks: Bool) -> Board {
        let sorted = models.sorted { sort.value($0) > sort.value($1) }
        let rows = sorted.enumerated().map { i, m -> BoardRow in
            let parts = m.id.split(separator: "/", maxSplits: 1).map(String.init)
            let author = m.author ?? (parts.count == 2 ? parts[0] : "")
            let provider = ProviderNames.display(author)
            let downloads = m.downloads.map { Formatters.compact(Double($0)) } ?? "—"
            let likes = m.likes.map { Formatters.compact(Double($0)) } ?? "—"
            let value = sort.value(m)
            let scoreText = sort == .trending ? String(format: "%.0f", value) : Formatters.compact(value)
            return BoardRow(
                id: m.id, position: i + 1, name: parts.last ?? m.id, badge: nil, provider: provider,
                score: value, scoreText: scoreText,
                subtitle: "\(provider) · \(downloads) downloads · \(likes) likes",
                metrics: [downloads, likes, m.lastModified.map { String($0.prefix(10)) } ?? "—"],
                url: URL(string: "https://huggingface.co/\(m.id)"),
                searchText: [m.id, author, provider].joined(separator: " "))
        }
        return Board(source: .huggingface,
                     rankingTitle: sort.shortTitle + (positionsAreRanks ? "" : " (search)"),
                     scoreTitle: sort.shortTitle, asOf: Formatters.today(),
                     metricTitles: ["Downloads (30 days)", "Likes", "Updated"], rows: rows,
                     credit: "Source: Hugging Face Hub")
    }
}

// MARK: - LMArena via the Hugging Face dataset viewer

struct ArenaRow: Codable, Hashable {
    let modelName: String
    let organization: String?
    let license: String?
    let rating: Double
    let ratingLower: Double?
    let ratingUpper: Double?
    let voteCount: Double?
    let rank: Double
    let category: String?
    let leaderboardPublishDate: String?

    var isOpenLicense: Bool {
        guard let l = license?.trimmingCharacters(in: .whitespaces), !l.isEmpty else { return false }
        return l.lowercased() != "proprietary"
    }
}

enum ArenaAPI {
    private struct Page: Decodable {
        struct Item: Decodable { let row: ArenaRow }
        let rows: [Item]
        let numRowsTotal: Int?
    }

    private static let pageSize = 100

    /// `maxPages` nil fetches the whole category (around 430 models, five requests).
    static func fetch(_ category: ArenaCategory, maxPages: Int? = nil) async throws -> [ArenaRow] {
        // The first page also says how many rows there are; the rest are fetched in parallel.
        let first = try await fetchPage(category, offset: 0)
        let total = first.numRowsTotal ?? first.rows.count
        let pageCount = min(Int((Double(total) / Double(pageSize)).rounded(.up)), maxPages ?? .max)
        var pages: [Int: [ArenaRow]] = [0: first.rows.map(\.row)]
        if pageCount > 1 {
            try await withThrowingTaskGroup(of: (Int, [ArenaRow]).self) { group in
                for index in 1..<pageCount {
                    group.addTask { (index, try await fetchPage(category, offset: index * pageSize).rows.map(\.row)) }
                }
                for try await (index, rows) in group { pages[index] = rows }
            }
        }
        let all = pages.keys.sorted().flatMap { pages[$0]! }
        // Only save complete lists, so an offline search still covers every model.
        if all.count >= total, let data = try? encoder.encode(all) {
            try? data.write(to: cacheURL(category), options: .atomic)
        }
        return all
    }

    static func cached(_ category: ArenaCategory) -> [ArenaRow]? {
        guard let data = try? Data(contentsOf: cacheURL(category)) else { return nil }
        return try? decoder.decode([ArenaRow].self, from: data)
    }

    private static func fetchPage(_ category: ArenaCategory, offset: Int) async throws -> Page {
        let params: [(String, String)] = [
            ("dataset", "lmarena-ai/leaderboard-dataset"), ("config", "text"), ("split", "latest"),
            ("where", "\"category\"='\(category.rawValue)'"), ("orderby", "\"rank\""),
            ("offset", String(offset)), ("length", String(pageSize)),
        ]
        let url = URL(string: "https://datasets-server.huggingface.co/filter?" + Formatters.query(params))!
        return try decoder.decode(Page.self, from: try await HTTP.get(url))
    }

    private static func cacheURL(_ c: ArenaCategory) -> URL { HTTP.cacheDir.appendingPathComponent("lmarena-\(c.rawValue).json") }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }
}

// MARK: - Hugging Face Hub

struct HubModel: Codable, Hashable {
    let id: String
    let author: String?
    let downloads: Int?
    let likes: Int?
    let trendingScore: Double?
    let lastModified: String?
}

extension HubSort {
    func value(_ m: HubModel) -> Double {
        switch self {
        case .trending: m.trendingScore ?? 0
        case .downloads: Double(m.downloads ?? 0)
        case .likes: Double(m.likes ?? 0)
        }
    }
}

enum HubAPI {
    /// Text-generation models only, so the list is about language models rather than every kind of model.
    static func fetch(sort: HubSort, search: String? = nil, limit: Int = 100) async throws -> [HubModel] {
        var params: [(String, String)] = [
            ("pipeline_tag", "text-generation"), ("sort", sort.rawValue), ("direction", "-1"), ("limit", String(limit)),
        ]
        if let search { params.append(("search", search)) }
        for field in ["author", "downloads", "likes", "trendingScore", "lastModified"] { params.append(("expand[]", field)) }
        let url = URL(string: "https://huggingface.co/api/models?" + Formatters.query(params))!
        let data = try await HTTP.get(url)
        let models = try JSONDecoder().decode([HubModel].self, from: data)
        if search == nil { try? data.write(to: cacheURL(sort), options: .atomic) }
        return models
    }

    static func cached(_ sort: HubSort) -> [HubModel]? {
        guard let data = try? Data(contentsOf: cacheURL(sort)) else { return nil }
        return try? JSONDecoder().decode([HubModel].self, from: data)
    }

    /// Asks the Hub for each comma-separated alternative (its search is loose: "llama 4" also returns
    /// Llama 3), then applies the app's own matching so every word, and every version number, must match.
    static func search(_ search: ModelSearch, sort: HubSort) async throws -> [HubModel] {
        var seen = Set<String>()
        var results: [HubModel] = []
        for words in search.rawAlternatives {
            for m in try await fetch(sort: sort, search: words.joined(separator: " ")) where seen.insert(m.id).inserted {
                results.append(m)
            }
        }
        return results.filter { m in
            let name = m.id.split(separator: "/").last.map(String.init) ?? m.id
            let author = m.author ?? ""
            return search.matches([m.id, author, ProviderNames.display(author)].joined(separator: " "), versionsFrom: name)
        }
    }

    private static func cacheURL(_ s: HubSort) -> URL { HTTP.cacheDir.appendingPathComponent("hf-\(s.rawValue).json") }
}

// MARK: - Helpers

enum HTTP {
    static var cacheDir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    /// GET with up to three attempts: the Hugging Face dataset viewer occasionally stalls on one request.
    static func get(_ url: URL, attempts: Int = 3) async throws -> Data {
        var lastError: Error = URLError(.unknown)
        for attempt in 1...attempts {
            do {
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                req.setValue("AILeaderboardMacWidget/1.3", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                lastError = URLError(.badServerResponse)
                if (400..<500).contains(status) && status != 429 { break }  // won't succeed on retry
            } catch {
                lastError = error
            }
            if attempt < attempts { try await Task.sleep(for: .milliseconds(400 * attempt)) }
        }
        throw lastError
    }
}

enum Formatters {
    /// 33180429 → "33.2M", 4370 → "4.4K", 395 → "395"
    static func compact(_ v: Double) -> String {
        switch abs(v) {
        case 1_000_000_000...: String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", v / 1_000_000)
        case 10_000...: String(format: "%.0fK", v / 1_000)
        case 1_000...: String(format: "%.1fK", v / 1_000)
        default: String(format: "%.0f", v)
        }
    }

    static func today() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Strict percent-encoding, so values like `"category"='coding'` survive intact.
    static func query(_ params: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return params.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    }
}

/// Turns the lowercase organisation names used by LMArena and the Hub into the names people know.
enum ProviderNames {
    private static let known: [String: String] = [
        "anthropic": "Anthropic", "google": "Google", "openai": "OpenAI", "openai-community": "OpenAI",
        "meta": "Meta", "meta-llama": "Meta", "facebook": "Meta", "xai": "xAI", "xai-org": "xAI",
        "deepseek": "DeepSeek", "deepseek-ai": "DeepSeek", "alibaba": "Alibaba", "qwen": "Alibaba",
        "moonshot": "Moonshot AI", "moonshotai": "Moonshot AI", "mistral": "Mistral", "mistralai": "Mistral",
        "zai": "Zhipu AI", "zai-org": "Zhipu AI", "thudm": "Zhipu AI", "nvidia": "NVIDIA", "microsoft": "Microsoft",
        "ibm": "IBM", "ibm-granite": "IBM", "amazon": "Amazon", "cohere": "Cohere", "coherelabs": "Cohere",
        "cohereforai": "Cohere", "tencent": "Tencent", "bytedance": "ByteDance", "bytedance-seed": "ByteDance",
        "minimax": "MiniMax", "minimaxai": "MiniMax", "baidu": "Baidu", "xiaomi": "Xiaomi", "xiaomimimo": "Xiaomi",
        "allenai": "Ai2", "stepfun": "StepFun", "stepfun-ai": "StepFun", "upstage": "Upstage",
        "inclusionai": "Ant Group", "ant-group": "Ant Group", "meituan": "Meituan", "meituan-longcat": "Meituan",
        "huggingfacetb": "Hugging Face", "huggingface": "Hugging Face",
    ]

    static func display(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "Unknown" }
        return known[raw.lowercased()] ?? raw
    }
}
