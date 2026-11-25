import LocalizeWork
import SwiftUI

/// What the demo reads from its launch arguments, for example
/// `-projectSlug my-app -cdnBaseURL http://127.0.0.1:3001/cdn -updatePolicy nextLaunch`.
enum DemoSettings {
    private static let arguments = UserDefaults.standard

    static func configuration(locale: String) -> LocalizeConfiguration {
        let namespace = arguments.string(forKey: "namespace") ?? "translation"
        return LocalizeConfiguration(
            projectSlug: arguments.string(forKey: "projectSlug") ?? "my-app",
            locale: locale,
            fallbackLocale: "en",
            namespaces: [namespace],
            updatePolicy: arguments.string(forKey: "updatePolicy") == "nextLaunch" ? .nextLaunch : .immediately,
            cdnBaseURL: arguments.string(forKey: "cdnBaseURL").flatMap(URL.init(string:))
                ?? LocalizeConfiguration.defaultCDNBaseURL
        )
    }
}

@main
struct LocalizeDemoApp: App {
    init() {
        // Once, as early as possible: this loads the release saved on the
        // device and starts downloading the latest one.
        let language = UserDefaults.standard.string(forKey: "language") ?? "en"
        Localize.configure(DemoSettings.configuration(locale: language))
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
