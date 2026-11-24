import SwiftUI
import WidgetKit

@main
struct BenchLeaderApp: App {
    var body: some Scene {
        WindowGroup("AI Leaderboard") {
            ContentView().frame(minWidth: 900, minHeight: 540)
        }
    }
}

struct ContentView: View {
    @State private var req = BoardRequest()
    @State private var query = ""
    @State private var board: Board?
    @State private var isStale = false
    @State private var hubResults: Board?
    @State private var hubSearching = false
    @State private var loading = false
    @State private var error: String?

    private var search: ModelSearch { ModelSearch(query) }
    private var searchesHub: Bool { req.source == .huggingface && !search.isEmpty }
    private var shown: Board? { searchesHub ? hubResults : board?.filtered(by: search) }

    var body: some View {
        let rows = shown?.rows ?? []
        VStack(spacing: 0) {
            controls(matchCount: rows.count)
            if let error { Text(error).foregroundStyle(.red).padding(.bottom, 6) }
            table(rows)
            footer
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Model or provider, e.g. Claude, OpenAI")
        .task(id: req) { await load() }
        .task(id: "\(req.source.rawValue)|\(req.hubSort.rawValue)|\(query)") { await searchHub() }
    }

    // MARK: Controls

    private func controls(matchCount: Int) -> some View {
        HStack(spacing: 14) {
            Picker("Source", selection: $req.source) {
                ForEach(DataSource.allCases, id: \.self) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            switch req.source {
            case .benchleader:
                Picker("Rank by", selection: $req.ranking) {
                    ForEach(Ranking.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
                }
                .frame(width: 180)
            case .lmarena:
                Picker("Category", selection: $req.arenaCategory) {
                    ForEach(ArenaCategory.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
                }
                .frame(width: 230)
            case .huggingface:
                Picker("Sort by", selection: $req.hubSort) {
                    ForEach(HubSort.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
                }
                .frame(width: 170)
            }

            if req.source.supportsOpenWeightsFilter {
                Toggle("Open weights only", isOn: $req.openWeightsOnly).fixedSize()
            }
            if !search.isEmpty {
                Text(searchesHub ? "\(matchCount) found" : "\(matchCount) of \(board?.rows.count ?? 0) match")
                    .foregroundStyle(.secondary).fixedSize()
            }
            Spacer()
            if loading || hubSearching { ProgressView().controlSize(.small) }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
        }
        .padding(12)
    }

    // MARK: Table

    private func table(_ rows: [BoardRow]) -> some View {
        let titles = shown?.metricTitles ?? ["", "", ""]
        return Table(rows) {
            TableColumn("#") { Text("\($0.position)").monospacedDigit() }.width(40)
            TableColumn("Model") { r in
                HStack(spacing: 6) {
                    Circle().fill(ProviderStyle.color(r.provider)).frame(width: 7, height: 7)
                    Text(r.name)
                    if let e = r.badge { Text(e).font(.caption).foregroundStyle(.secondary) }
                }
            }
            TableColumn("Provider") { Text($0.provider) }.width(110)
            TableColumn(shown?.scoreTitle ?? "Score") { Text($0.scoreText).monospacedDigit().bold() }.width(90)
            TableColumn(titles[0]) { Text($0.metrics[0]).monospacedDigit() }.width(100)
            TableColumn(titles[1]) { Text($0.metrics[1]).monospacedDigit() }.width(95)
            TableColumn(titles[2]) { Text($0.metrics[2]).monospacedDigit() }.width(110)
        }
        .overlay {
            if rows.isEmpty {
                if (loading && board == nil) || hubSearching {
                    ProgressView("Loading \(req.source.shortName)…")
                } else if !search.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if board == nil && !loading {
                    ContentUnavailableView("Couldn't load \(req.source.shortName)", systemImage: "wifi.exclamationmark",
                                           description: Text("Check your connection, then press Refresh."))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if searchesHub {
                Text("Searching all text-generation models on the Hub; # is the position within these results.")
            } else {
                Text("To add the widget: right-click the desktop → Edit Widgets… → search “AI Leaderboard”.")
            }
            Spacer()
            if let b = board {
                Text("Data as of \(b.asOf)" + (isStale ? " (cached)" : "") + " ·")
            }
            Link(shown?.credit ?? req.source.shortName, destination: req.source.homepage)
        }
        .font(.caption).foregroundStyle(.secondary).padding(10)
    }

    // MARK: Loading

    private func load() async {
        loading = true
        defer { loading = false }
        let requested = req
        // Don't leave another source's rows on screen while this one loads.
        if board?.source != requested.source { board = nil; hubResults = nil }
        let result = await BoardLoader.load(requested)
        guard !Task.isCancelled, requested == req else { return }
        board = result.board
        isStale = result.board != nil && !result.fresh
        error = result.board == nil ? "Couldn't reach \(requested.source.shortName)." : nil
        if result.fresh { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Hub searches go to Hugging Face itself (it has far more models than one list holds); debounced while typing.
    private func searchHub() async {
        guard searchesHub else { hubResults = nil; return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        hubSearching = true
        defer { hubSearching = false }
        let result = try? await BoardLoader.hubSearch(search, sort: req.hubSort)
        guard !Task.isCancelled else { return }
        hubResults = result
    }
}
