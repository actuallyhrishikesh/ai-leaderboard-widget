# AI Leaderboard: a macOS widget

A native macOS desktop / Notification Center widget that shows the current AI model standings from [BenchLeader](https://www.benchleader.com), refreshed every hour.

> **Unofficial.** This project isn't affiliated with or endorsed by BenchLeader. It only reads the public data file they publish for reuse.

## Features

- **Four sizes:** small (top 4), medium (top 5), large (top 12), extra-large (top 24 in two columns).
- **Choose the ranking:** Overall (BenchLeader Index), Coding, Agents, Reasoning, Math, Knowledge, Speed (tokens/s) or Value (index per dollar). You can also show open-weights models only.
- Each row shows the rank, provider, model name, reasoning effort, blended price per million tokens and score. Click a row to open that model's page.
- Refreshes hourly, shortly after BenchLeader's own hourly rebuild. If it can't connect, it shows the last saved data marked "(cached)".
- A small companion app shows all 100 rows in a table.

## Install (prebuilt)

1. Download `AI-Leaderboard.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move `BenchLeader.app` to `/Applications` or `~/Applications`.
3. The app isn't signed with an Apple Developer ID, so macOS will block it the first time. Either:
   - try to open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**, or
   - run: `xattr -dr com.apple.quarantine ~/Applications/BenchLeader.app` (adjust the path if needed).
4. Open the app once so macOS registers the widget.
5. Right-click the desktop → **Edit Widgets…** → search for **AI Leaderboard**.

To change the ranking, right-click the widget → **Edit "AI Leaderboard"**.

## Build from source

Requirements: macOS 14 or later and Xcode 16 or later. You don't need an Apple Developer account.

```bash
git clone https://github.com/actuallyhrishikesh/ai-leaderboard-widget.git
cd ai-leaderboard-widget
xcodebuild -project BenchLeader.xcodeproj -scheme BenchLeader -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/BenchLeader.app ~/Applications/
open ~/Applications/BenchLeader.app
```

Or open `BenchLeader.xcodeproj` in Xcode and run the **BenchLeader** scheme. The project is ad-hoc signed ("Sign to Run Locally"). To distribute your own build without Gatekeeper warnings, set your team in Signing & Capabilities and notarize it.

## How it works

| Path | Contents |
| --- | --- |
| `Shared/Leaderboard.swift` | Data model, ranking logic, fetching and on-disk cache (used by both targets) |
| `Widget/BenchLeaderWidget.swift` | WidgetKit extension: configuration intent, timeline provider, views |
| `BenchLeader/BenchLeaderApp.swift` | Host app with the full table |
| `Config/` | Widget `Info.plist` and sandbox entitlements (network client only) |

The widget fetches [`https://www.benchleader.com/data/leaderboard.json`](https://www.benchleader.com/data/leaderboard.json), the top 100 model configurations on the BenchLeader Index. A configuration is one model at one reasoning effort. Rankings other than Overall re-sort those 100 rows, so they aren't BenchLeader's full category leaderboards.

## Data and licensing

- The **code** in this repository is released under the [MIT License](LICENSE).
- The **data** isn't included in this repository; the widget downloads it at runtime. BenchLeader's computed figures (the index, its interval, category scores and rank) are published under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), and the widget credits "BenchLeader" on screen. Prices, speeds and benchmark results remain under their original publishers' terms. See BenchLeader's [methodology page](https://www.benchleader.com/methodology) for details.
