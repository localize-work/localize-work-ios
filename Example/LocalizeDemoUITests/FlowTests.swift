import XCTest

/// The demo's whole flow, one phase per test. `flow.sh` runs them in this
/// order on one simulator and makes the server reachable or not in between.
///
/// The texts expected here are the ones the flow's project publishes: its
/// title names the release ("Demo (release v3)"), and from the second
/// release on English has the key `added_later`.
@MainActor
final class FlowTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private let app = XCUIApplication()
    private var cdn: String { environment["FLOW_CDN"] ?? "http://127.0.0.1:3421/cdn" }
    private var control: String { environment["FLOW_CONTROL"] ?? "http://127.0.0.1:3412" }
    private var slug: String { environment["FLOW_SLUG"] ?? "demo-ios" }

    override func setUp() async throws {
        // Every line of the screen is reported, not only the first wrong one.
        continueAfterFailure = true
    }

    // MARK: Phases

    /// A fresh install that cannot reach the server shows the app's own strings.
    func test1BundledWhileUnreachable() {
        launch()
        expect("version", "none")
        expect("title", "Demo (bundled)")
        expect("greeting", "Hello, Ann! (bundled)")
        expect("items-1", "1 item (bundled)")
        expect("items-5", "5 items (bundled)")
        expect("only_source", "only_source")
        expect("only_bundled", "Only in the app")
        expect("added_later", "(not published yet)")
        expect("missing", "missing")
        app.buttons["refresh"].tap()
        expectStatus(startsWith: "error")
        expect("title", "Demo (bundled)")
        shot("phase1-bundled")
    }

    /// The first launch that reaches the server shows the release while the
    /// app is open, and the next launch shows it again.
    func test2DownloadsTheRelease() async throws {
        let version = try await live()
        launch()
        expectEnglish(version)
        shot("phase2-arrived")
        app.terminate()
        launch()
        expectEnglish(version)
        shot("phase2-relaunched")
    }

    /// Estonian and German come from the release; a text the release lacks
    /// in the language comes from the app, then from the release's English.
    func test3ChangesLanguage() async throws {
        let version = try await live()
        launch()
        expectEnglish(version)
        app.buttons["language-et"].tap()
        expectEstonian(version)
        shot("phase3-et")
        app.buttons["language-de"].tap()
        expectGerman(version)
        shot("phase3-de")
        app.buttons["language-en"].tap()
        expectEnglish(version)
    }

    /// With `.nextLaunch` a new release waits for the next launch.
    func test4aNextLaunchWaits() async throws {
        let before = try await live()
        let published = try await publishNext()
        XCTAssertNotEqual(before, published)
        launch(["-updatePolicy", "nextLaunch"])
        expectEnglish(before)
        app.buttons["refresh"].tap()
        expectStatus(startsWith: "pendingNextLaunch \(published)")
        expectEnglish(before)
        shot("phase4a-waiting")
        app.terminate()
        launch(["-updatePolicy", "nextLaunch"])
        expectEnglish(published)
        shot("phase4a-next-launch")
    }

    /// With `.immediately` a new release changes the open screen.
    func test4bImmediatelyChangesTheScreen() async throws {
        let before = try await live()
        launch()
        expectEnglish(before)
        let published = try await publishNext()
        app.buttons["refresh"].tap()
        expectStatus(startsWith: "updated \(published)")
        expectEnglish(published)
        shot("phase4b-updated")
        // Estonian of the new release, so the next phase has it on the device.
        app.buttons["language-et"].tap()
        expectEstonian(published)
        app.buttons["language-en"].tap()
        expectEnglish(published)
    }

    /// A cold start that cannot reach the server shows the saved release, in
    /// every language it was used in.
    func test5SavedReleaseWhileUnreachable() async throws {
        let version = try await live()
        launch()
        expectEnglish(version, timeout: 5)
        app.buttons["refresh"].tap()
        expectStatus(startsWith: "error")
        expectEnglish(version)
        shot("phase5-offline")
        app.buttons["language-et"].tap()
        expectEstonian(version)
        shot("phase5-offline-et")
        app.buttons["language-en"].tap()
    }

    /// The default CDN over HTTPS, read only. Runs when `FLOW_REAL_SLUG`
    /// names a published project. Its keys are not the demo's, so only the
    /// release in use is checked.
    func test6RealCDN() throws {
        guard let real = environment["FLOW_REAL_SLUG"], !real.isEmpty else {
            throw XCTSkip("FLOW_REAL_SLUG is not set")
        }
        app.launchArguments = ["-projectSlug", real]
        app.launch()
        let version = text("version")
        let arrived = NSPredicate(format: "label MATCHES %@", "v[0-9]+")
        let result = XCTWaiter().wait(for: [expectation(for: arrived, evaluatedWith: version)], timeout: 30)
        if result != .completed {
            // Say why: a refresh by hand puts the error on the screen.
            app.buttons["refresh"].tap()
            _ = XCTWaiter().wait(
                for: [expectation(for: NSPredicate(format: "label != ''"), evaluatedWith: text("status"))],
                timeout: 30)
            XCTFail("version is \(version.label), a refresh says: \(text("status").label)")
        }
        shot("phase6-real-cdn")
    }

    // MARK: What a screen should show

    private func expectEnglish(_ version: String, timeout: TimeInterval = 30) {
        expect("version", version, timeout: timeout)
        expect("locale", "en")
        expect("title", "Demo (release \(version))")
        expect("greeting", "Hello, Ann!")
        expect("items-1", "1 item")
        expect("items-5", "5 items")
        expect("only_source", "Only in English on the server")
        expect("only_bundled", "Only in the app")
        expect("added_later", addedLater(version))
        expect("missing", "missing")
    }

    private func expectEstonian(_ version: String) {
        expect("title", "Demo (väljalase \(version))")
        expect("version", version)
        expect("locale", "et")
        expect("greeting", "Tere, Ann!")
        expect("items-1", "1 asi")
        expect("items-5", "5 asja")
        // Not in the release's Estonian nor in the app's: the release's English.
        expect("only_source", "Only in English on the server")
        // Not in the release at all: the app's Estonian.
        expect("only_bundled", "Ainult rakenduses")
        expect("added_later", addedLater(version))
        expect("missing", "missing")
    }

    private func expectGerman(_ version: String) {
        expect("title", "Demo (Version \(version))")
        expect("version", version)
        expect("locale", "de")
        expect("greeting", "Hallo, Ann!")
        expect("items-1", "1 Artikel")
        expect("items-5", "5 Artikel")
        expect("only_source", "Only in English on the server")
        // The app has no German: the language iOS picks for it, English.
        expect("only_bundled", "Only in the app")
        expect("added_later", addedLater(version))
    }

    /// English only, and only from the second release on.
    private func addedLater(_ version: String) -> String {
        version == "v1" ? "(not published yet)" : "Added in release \(version)"
    }

    // MARK: Helpers

    private func launch(_ extra: [String] = []) {
        app.launchArguments = ["-cdnBaseURL", cdn, "-projectSlug", slug] + extra
        app.launch()
    }

    /// The value of a row. The row's caption reads the same as the value's
    /// identifier, so the identifier alone is asked for.
    private func text(_ identifier: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func expect(_ identifier: String, _ value: String, timeout: TimeInterval = 30,
                        file: StaticString = #filePath, line: UInt = #line) {
        let element = text(identifier)
        let matches = NSPredicate(format: "label == %@", value)
        let result = XCTWaiter().wait(for: [expectation(for: matches, evaluatedWith: element)], timeout: timeout)
        if result != .completed {
            let seen = element.exists ? element.label : "(not on screen)"
            XCTFail("\(identifier): expected \"\(value)\", the screen shows \"\(seen)\"", file: file, line: line)
        }
    }

    private func expectStatus(startsWith prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = text("status")
        let matches = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let result = XCTWaiter().wait(for: [expectation(for: matches, evaluatedWith: element)], timeout: 30)
        if result != .completed {
            let seen = element.exists ? element.label : "(nothing)"
            XCTFail("status: expected \"\(prefix)…\", the screen shows \"\(seen)\"", file: file, line: line)
        }
    }

    /// The version the server has live.
    private func live() async throws -> String {
        try await version(from: "state")
    }

    /// Publishes the next release and returns its version.
    private func publishNext() async throws -> String {
        try await version(from: "publish-next")
    }

    private func version(from action: String) async throws -> String {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(control)/\(action)/\(slug)")))
        request.timeoutInterval = 120
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(body["version"] as? String, String(decoding: data, as: UTF8.self))
    }

    /// Saves the screen as `<FLOW_SHOTS>/<FLOW_TAG>-<name>.png`.
    private func shot(_ name: String) {
        guard let folder = environment["FLOW_SHOTS"] else { return }
        let file = URL(fileURLWithPath: folder)
            .appendingPathComponent("\(environment["FLOW_TAG"] ?? "ios")-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
    }
}
