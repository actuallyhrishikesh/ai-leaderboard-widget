import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Configuration

struct LeaderboardIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "AI Leaderboard"
    static let description = IntentDescription("AI model standings from BenchLeader, LMArena or the Hugging Face Hub.")

    // Menus are String settings with widget-supplied choices; see Widget/WidgetSettings.swift for why.
    @Parameter(title: "Source", optionsProvider: SourceOptions())
    var sourceName: String?

    @Parameter(title: "Rank by", optionsProvider: RankingOptions())
    var rankingName: String?

    @Parameter(title: "Category", optionsProvider: ArenaCategoryOptions())
    var arenaCategoryName: String?

    @Parameter(title: "Sort by", optionsProvider: HubSortOptions())
    var hubSortName: String?

    @Parameter(title: "Open-weights models only", default: false)
    var openWeightsOnly: Bool

    @Parameter(title: "Show only", description: "Model or provider names, e.g. \"Claude\", \"Sonnet\" or \"OpenAI, Google\". Leave empty to show all.")
    var filter: String?

    /// Shows only the options that apply to the chosen source.
    static var parameterSummary: some ParameterSummary {
        When(\.$sourceName, .equalTo, "LMArena") {
            Summary("\(\.$sourceName): \(\.$arenaCategoryName)") {
                \.$openWeightsOnly
                \.$filter
            }
        } otherwise: {
            When(\.$sourceName, .equalTo, "Hugging Face") {
                Summary("\(\.$sourceName) by \(\.$hubSortName)") {
                    \.$filter
                }
            } otherwise: {
                Summary("\(\.$sourceName) by \(\.$rankingName)") {
                    \.$openWeightsOnly
                    \.$filter
                }
            }
        }
    }

    var source: DataSource { .named(sourceName, fallback: .benchleader) }
    var ranking: Ranking { .named(rankingName, fallback: .index) }
    var arenaCategory: ArenaCategory { .named(arenaCategoryName, fallback: .overall) }
    var hubSort: HubSort { .named(hubSortName, fallback: .trending) }

    var request: BoardRequest {
        BoardRequest(source: source, ranking: ranking, arenaCategory: arenaCategory,
                     hubSort: hubSort, openWeightsOnly: openWeightsOnly)
    }
}

// MARK: - Timeline

struct LeaderboardEntry: TimelineEntry {
    let date: Date
    let board: Board?
    let source: DataSource
    let openWeightsOnly: Bool
    var filter: String = ""
    let isStale: Bool

    var search: ModelSearch { ModelSearch(filter) }
    var rows: [BoardRow] { board?.rows ?? [] }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LeaderboardEntry {
        let board = LeaderboardAPI.cached().map { BoardLoader.benchleaderBoard($0, BoardRequest()) }
            ?? BoardLoader.benchleaderBoard(.sample, BoardRequest())
        return LeaderboardEntry(date: .now, board: board, source: .benchleader, openWeightsOnly: false, isStale: false)
    }

    func snapshot(for configuration: LeaderboardIntent, in context: Context) async -> LeaderboardEntry {
        if context.isPreview && configuration.source == .benchleader { return placeholder(in: context) }
        return await makeEntry(configuration).entry
    }

    func timeline(for configuration: LeaderboardIntent, in context: Context) async -> Timeline<LeaderboardEntry> {
        let (entry, fresh) = await makeEntry(configuration)
        // BenchLeader rebuilds at :03 past each hour (UTC); refresh shortly after. On failure, retry in 15 minutes.
        let next = fresh ? Self.nextHourlyRefresh() : Date.now.addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func makeEntry(_ config: LeaderboardIntent) async -> (entry: LeaderboardEntry, fresh: Bool) {
        let filter = config.filter ?? ""
        let search = ModelSearch(filter)
        var board: Board?
        var fresh = false
        if config.source == .huggingface && !search.isEmpty {
            board = try? await BoardLoader.hubSearch(search, sort: config.hubSort)
            fresh = board != nil
        } else {
            let result = await BoardLoader.load(config.request, needsAllRows: !search.isEmpty)
            board = result.board?.filtered(by: search)
            fresh = result.fresh
        }
        let entry = LeaderboardEntry(date: .now, board: board, source: config.source,
                                     openWeightsOnly: config.openWeightsOnly && config.source.supportsOpenWeightsFilter,
                                     filter: filter, isStale: board != nil && !fresh)
        return (entry, fresh)
    }

    static func nextHourlyRefresh() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date.now
        return cal.nextDate(after: now, matching: DateComponents(minute: 10), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(3600)
    }
}

// MARK: - Views

struct LeaderboardWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: LeaderboardEntry

    var body: some View {
        if entry.board == nil {
            VStack(spacing: 6) {
                Image(systemName: "wifi.exclamationmark").font(.title2)
                Text("Couldn't reach \(entry.source.shortName)").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        } else if entry.rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Header(entry: entry, compact: family == .systemSmall)
                Spacer()
                Text(entry.search.isEmpty ? "No models to show." : "No models match “\(entry.filter)”.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Right-click → Edit to change the settings.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
        } else {
            switch family {
            case .systemSmall: SmallView(entry: entry)
            case .systemExtraLarge: ListView(entry: entry, count: 24, columns: 2)
            case .systemLarge: ListView(entry: entry, count: 12, columns: 1)
            default: ListView(entry: entry, count: 5, columns: 1)
            }
        }
    }
}

private struct Header: View {
    let entry: LeaderboardEntry
    var compact = false

    var body: some View {
        let title = entry.board?.rankingTitle ?? ""
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "trophy.fill").foregroundStyle(.purple).font(.caption)
            Text(compact ? title : "\(entry.source.shortName) · \(title)")
                .font(.caption.weight(.semibold))
            if entry.openWeightsOnly { Text("open").font(.caption2).foregroundStyle(.secondary) }
            if !entry.search.isEmpty {
                Label(entry.filter.trimmingCharacters(in: .whitespaces), systemImage: "line.3.horizontal.decrease")
                    .font(.caption2).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
            if !compact, let asOf = entry.board?.asOf {
                Text(asOf + (entry.isStale ? " (cached)" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

private struct SmallView: View {
    let entry: LeaderboardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Header(entry: entry, compact: true)
            ForEach(entry.rows.prefix(4)) { r in
                HStack(spacing: 5) {
                    Text("\(r.position)").font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(r.position == 1 ? .purple : .secondary)
                        .frame(width: 16, alignment: .trailing)
                    Circle().fill(ProviderStyle.color(r.provider)).frame(width: 5, height: 5)
                    Text(r.name).font(.caption2.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(r.scoreText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(entry.source.shortName.lowercased()).font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }
}

private struct ListView: View {
    let entry: LeaderboardEntry
    let count: Int
    let columns: Int

    var body: some View {
        let rows = Array(entry.rows.prefix(count))
        let perCol = Int((Double(rows.count) / Double(columns)).rounded(.up))
        VStack(alignment: .leading, spacing: 6) {
            Header(entry: entry)
            HStack(alignment: .top, spacing: 16) {
                ForEach(0..<columns, id: \.self) { c in
                    VStack(spacing: 0) {
                        ForEach(rows.dropFirst(c * perCol).prefix(perCol)) { r in
                            RowView(r: r, fallback: entry.source.homepage)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            HStack {
                Text(entry.board?.credit ?? "")
                Spacer()
                Text(entry.search.isEmpty ? "\(entry.rows.count) ranked" : "\(entry.rows.count) match")
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

private struct RowView: View {
    let r: BoardRow
    let fallback: URL

    var body: some View {
        Link(destination: r.url ?? fallback) {
            HStack(spacing: 6) {
                Text("\(r.position)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(r.position == 1 ? .purple : .secondary)
                    .frame(width: 22, alignment: .trailing)
                Circle().fill(ProviderStyle.color(r.provider)).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(r.name).font(.caption.weight(.medium)).lineLimit(1)
                        if let e = r.badge, !e.isEmpty {
                            Text(e).font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .lineLimit(1)
                        }
                    }
                    Text(r.subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(r.scoreText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(r.position == 1 ? .purple : .primary)
            }
        }
    }
}

// MARK: - Widget

struct BenchLeaderLeaderboardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "BenchLeaderLeaderboard", intent: LeaderboardIntent.self, provider: Provider()) { entry in
            LeaderboardWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.source.homepage)
        }
        .configurationDisplayName("AI Leaderboard")
        .description("AI model standings from BenchLeader, LMArena or the Hugging Face Hub, refreshed hourly.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct BenchLeaderWidgetBundle: WidgetBundle {
    var body: some Widget { BenchLeaderLeaderboardWidget() }
}

// MARK: - Sample data for the widget gallery

extension LeaderboardFile {
    static let sample = LeaderboardFile(asOf: "—", generatedAt: nil, rows: [
        ("Claude Fable 5.2", "Anthropic", 70.6), ("Gemini 4 Neon", "Google", 68.9),
        ("Gemini 4 Carbon", "Google", 68.8), ("GPT-6.2 Astra", "OpenAI", 68.5),
        ("GPT-6 Astra", "OpenAI", 68.1), ("Claude Opus 5.5", "Anthropic", 68.0),
    ].enumerated().map { i, m in
        ModelRow(rank: i + 1, model: m.0, effort: nil, configurationId: m.0, provider: m.1, openWeights: false,
                 index: m.2, indexCi: nil, reasoning: nil, coding: nil, agentic: nil, math: nil, knowledge: nil,
                 priceBlendedUsdPerMtok: nil, outputTokensPerSecond: nil, url: nil)
    })
}
