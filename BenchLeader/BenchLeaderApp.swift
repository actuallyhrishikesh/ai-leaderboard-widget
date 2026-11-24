import SwiftUI
import WidgetKit

@main
struct BenchLeaderApp: App {
    var body: some Scene {
        WindowGroup("AI Leaderboard") {
            ContentView().frame(minWidth: 760, minHeight: 520)
        }
    }
}

struct ContentView: View {
    @State private var file: LeaderboardFile? = LeaderboardAPI.cached()
    @State private var ranking: Ranking = .index
    @State private var openOnly = false
    @State private var query = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        let ranked = file.map { ranking.rank($0.rows, openWeightsOnly: openOnly) } ?? []
        let search = ModelSearch(query)
        let rows = ranked.filtered(by: search)
        VStack(spacing: 0) {
            HStack {
                Picker("Rank by", selection: $ranking) {
                    ForEach(Ranking.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
                }
                .frame(width: 220)
                Toggle("Open weights only", isOn: $openOnly)
                if !search.isEmpty {
                    Text("\(rows.count) of \(ranked.count) match").foregroundStyle(.secondary)
                }
                Spacer()
                if let f = file { Text("Data as of \(f.asOf)").foregroundStyle(.secondary) }
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
            }
            .padding(12)

            if let error { Text(error).foregroundStyle(.red).padding(.bottom, 6) }

            Table(rows) {
                TableColumn("#") { Text("\($0.position)").monospacedDigit() }.width(32)
                TableColumn("Model") { r in
                    HStack(spacing: 6) {
                        Circle().fill(ProviderStyle.color(r.row.provider)).frame(width: 7, height: 7)
                        Text(r.row.model)
                        if let e = r.row.effort { Text(e).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                TableColumn("Provider") { Text($0.row.provider) }.width(100)
                TableColumn(ranking.shortTitle) { Text(ranking.format($0.score)).monospacedDigit().bold() }.width(80)
                TableColumn("Index") { r in Text(r.row.index.map { String(format: "%.1f ±%.1f", $0, r.row.indexCi ?? 0) } ?? "—").monospacedDigit() }.width(90)
                TableColumn("$/M (blended)") { Text($0.row.priceBlendedUsdPerMtok.map { String(format: "$%.2f", $0) } ?? "—").monospacedDigit() }.width(95)
                TableColumn("Speed") { Text($0.row.outputTokensPerSecond.map { String(format: "%.0f t/s", $0) } ?? "—").monospacedDigit() }.width(70)
            }
            .overlay {
                if rows.isEmpty && !search.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }

            HStack {
                Text("To add the widget: right-click the desktop → Edit Widgets… → search “AI Leaderboard”.")
                Spacer()
                Link("Source: BenchLeader (CC BY 4.0)", destination: LeaderboardAPI.homepage)
            }
            .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Model or provider, e.g. Claude, OpenAI")
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            file = try await LeaderboardAPI.fetch()
            error = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            self.error = "Couldn't refresh: \(error.localizedDescription)"
        }
    }
}
