import AppIntents

// Widget settings menus.
//
// These are plain String settings whose choices the widget supplies itself (DynamicOptionsProvider),
// not AppEnum types. macOS's App Intents service only loads custom types (AppEnum) for apps signed with
// an Apple Developer Team ID; this app is signed "to run locally" (no Team ID), so AppEnum settings
// always reached the widget empty and it fell back to BenchLeader / Overall. Strings need no lookup.

protocol SettingChoice: CaseIterable, Equatable {
    var settingName: String { get }
}

extension SettingChoice {
    /// The choice whose menu name is `name`, or `fallback` for an empty or unknown value.
    static func named(_ name: String?, fallback: Self) -> Self {
        allCases.first { $0.settingName == name } ?? fallback
    }
}

extension DataSource: SettingChoice {
    var settingName: String { shortName }
}

extension Ranking: SettingChoice {
    var settingName: String { shortTitle }
}

extension ArenaCategory: SettingChoice {
    var settingName: String { shortTitle }
}

extension HubSort: SettingChoice {
    var settingName: String { shortTitle }
}

struct SourceOptions: DynamicOptionsProvider {
    func results() async throws -> [String] { DataSource.allCases.map(\.settingName) }
}

struct RankingOptions: DynamicOptionsProvider {
    func results() async throws -> [String] { Ranking.allCases.map(\.settingName) }
}

struct ArenaCategoryOptions: DynamicOptionsProvider {
    func results() async throws -> [String] { ArenaCategory.allCases.map(\.settingName) }
}

struct HubSortOptions: DynamicOptionsProvider {
    func results() async throws -> [String] { HubSort.allCases.map(\.settingName) }
}
