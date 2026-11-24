import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Configuration

struct LeaderboardIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "AI Leaderboard"
    static let description = IntentDescription("Live AI model standings from BenchLeader.")

    @Parameter(title: "Rank by", default: .index)
    var ranking: Ranking

    @Parameter(title: "Open-weights models only", default: false)
    var openWeightsOnly: Bool

    @Parameter(title: "Show only", description: "Model or provider names, e.g. \"Claude\", \"Sonnet\" or \"OpenAI, Google\". Leave empty to show all.")
    var filter: String?
}

// MARK: - Timeline

struct LeaderboardEntry: TimelineEntry {
    let date: Date
    let file: LeaderboardFile?
    let ranking: Ranking
    let openWeightsOnly: Bool
    var filter: String = ""
    let isStale: Bool

    var search: ModelSearch { ModelSearch(filter) }
    var rows: [RankedRow] {
        (file.map { ranking.rank($0.rows, openWeightsOnly: openWeightsOnly) } ?? []).filtered(by: search)
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LeaderboardEntry {
        LeaderboardEntry(date: .now, file: LeaderboardAPI.cached() ?? .sample, ranking: .index, openWeightsOnly: false, isStale: false)
    }

    func snapshot(for configuration: LeaderboardIntent, in context: Context) async -> LeaderboardEntry {
        let file = context.isPreview ? (LeaderboardAPI.cached() ?? .sample) : await load().file
        return LeaderboardEntry(date: .now, file: file, ranking: configuration.ranking,
                                openWeightsOnly: configuration.openWeightsOnly,
                                filter: configuration.filter ?? "", isStale: false)
    }

    func timeline(for configuration: LeaderboardIntent, in context: Context) async -> Timeline<LeaderboardEntry> {
        let (file, fresh) = await load()
        let entry = LeaderboardEntry(date: .now, file: file, ranking: configuration.ranking,
                                     openWeightsOnly: configuration.openWeightsOnly,
                                     filter: configuration.filter ?? "", isStale: !fresh)
        // BenchLeader rebuilds at :03 past each hour (UTC); ask for a refresh shortly after.
        // On failure, retry in 15 minutes.
        let next = fresh ? Self.nextHourlyRefresh() : Date.now.addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func load() async -> (file: LeaderboardFile?, fresh: Bool) {
        if let f = try? await LeaderboardAPI.fetch() { return (f, true) }
        return (LeaderboardAPI.cached(), false)
    }

    static func nextHourlyRefresh() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date.now
        let comps = DateComponents(minute: 10)
        return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
    }
}

// MARK: - Views

struct LeaderboardWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: LeaderboardEntry

    var body: some View {
        if entry.file == nil {
            VStack(spacing: 6) {
                Image(systemName: "wifi.exclamationmark").font(.title2)
                Text("Couldn't reach benchleader.com").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        } else if entry.rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Header(entry: entry, compact: family == .systemSmall)
                Spacer()
                Text("No models match “\(entry.filter)”.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Right-click → Edit to change the filter.")
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
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "trophy.fill").foregroundStyle(.purple).font(.caption)
            Text(compact ? entry.ranking.shortTitle : "AI Leaderboard · \(entry.ranking.shortTitle)")
                .font(.caption.weight(.semibold))
            if entry.openWeightsOnly { Text("open").font(.caption2).foregroundStyle(.secondary) }
            if !entry.search.isEmpty {
                Label(entry.filter.trimmingCharacters(in: .whitespaces), systemImage: "line.3.horizontal.decrease")
                    .font(.caption2).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
            if !compact, let asOf = entry.file?.asOf {
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
                        .frame(width: 12, alignment: .trailing)
                    Circle().fill(ProviderStyle.color(r.row.provider)).frame(width: 5, height: 5)
                    Text(r.row.model).font(.caption2.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(String(format: entry.ranking == .speed ? "%.0f" : "%.1f", r.score))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text("benchleader.com").font(.system(size: 8)).foregroundStyle(.tertiary)
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
                            RowView(r: r, ranking: entry.ranking)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            HStack {
                Text("Source: BenchLeader (CC BY 4.0)")
                Spacer()
                Text(entry.search.isEmpty ? "\(entry.rows.count) ranked" : "\(entry.rows.count) match")
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

private struct RowView: View {
    let r: RankedRow
    let ranking: Ranking

    var body: some View {
        let link = r.row.url.flatMap(URL.init(string:)) ?? LeaderboardAPI.homepage
        Link(destination: link) {
            HStack(spacing: 6) {
                Text("\(r.position)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(r.position == 1 ? .purple : .secondary)
                    .frame(width: 18, alignment: .trailing)
                Circle().fill(ProviderStyle.color(r.row.provider)).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(r.row.model).font(.caption.weight(.medium)).lineLimit(1)
                        if let e = r.row.effort, !e.isEmpty {
                            Text(e).font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(ranking.format(r.score))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(r.position == 1 ? .purple : .primary)
            }
        }
    }

    private var subtitle: String {
        var parts = [r.row.provider]
        if let p = r.row.priceBlendedUsdPerMtok { parts.append(String(format: "$%.2f/M", p)) }
        if ranking != .index, let i = r.row.index { parts.append(String(format: "idx %.1f", i)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Widget

struct BenchLeaderLeaderboardWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "BenchLeaderLeaderboard", intent: LeaderboardIntent.self, provider: Provider()) { entry in
            LeaderboardWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(LeaderboardAPI.homepage)
        }
        .configurationDisplayName("AI Leaderboard")
        .description("AI model standings from benchleader.com, refreshed hourly.")
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
