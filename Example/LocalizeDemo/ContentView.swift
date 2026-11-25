import LocalizeWork
import SwiftUI

struct ContentView: View {
    @AppStorage("language") private var language = "en"
    @State private var arrivals = 0
    @State private var status = ""

    var body: some View {
        let localize = Localize.shared
        VStack(alignment: .leading, spacing: 10) {
            row("version", localize.version ?? "none")
            row("locale", localize.configuration.locale)
            Divider()
            row("title", localize.string("title"))
            row("greeting", localize.string("greeting", ["name": "Ann"]))
            row("items-1", localize.string("items", count: 1))
            row("items-5", localize.string("items", count: 5))
            row("only_source", localize.string("only_source"))
            row("only_bundled", localize.string("only_bundled"))
            row("added_later", localize.string("added_later", fallback: "(not published yet)"))
            row("missing", localize.string("missing"))
            Divider()
            HStack {
                ForEach(["en", "et", "de"], id: \.self) { code in
                    Button(code) { choose(code) }
                        .accessibilityIdentifier("language-\(code)")
                }
                Spacer()
                Button("Refresh now") { Task { await refresh() } }
                    .accessibilityIdentifier("refresh")
            }
            .buttonStyle(.bordered)
            row("status", status)
            Spacer()
        }
        .padding()
        // Drawn again when the language changes and each time a release
        // starts being used. That is counted, not compared: after a change of
        // language the same release arrives again, with the new language.
        .id("\(language) \(arrivals)")
        .task {
            for await _ in Localize.shared.updates {
                arrivals += 1
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundColor(.secondary)
            Text(value).accessibilityIdentifier(name)
        }
    }

    /// Configure first, then change what the views read.
    private func choose(_ code: String) {
        Localize.configure(DemoSettings.configuration(locale: code))
        language = code
    }

    private func refresh() async {
        do {
            switch try await Localize.shared.refresh() {
            case .updated(let version): status = "updated \(version)"
            case .upToDate(let version): status = "upToDate \(version)"
            case .pendingNextLaunch(let version): status = "pendingNextLaunch \(version)"
            }
        } catch {
            status = "error: \(error)"
        }
    }
}
