import XCTest
@testable import LocalizeWork

final class RefreshTests: LocalizeTestCase {
    // MARK: The read algorithm

    func testThePointerIsResolvedOnceAndOneVersionServesEveryFile() async throws {
        stub.setPointer("v3")
        stub.publish("v3", [
            "en-FI/translation": ["a": "en-FI"],
            "en/translation": ["a": "en", "b": "en b"],
            "et/translation": ["c": "et c"],
            "en-FI/checkout": ["pay": "en-FI pay"],
            "en/checkout": ["pay": "en pay"],
            "et/checkout": ["pay": "et pay"],
        ])
        let localize = Localize(
            configuration: configuration(locale: "en-FI", fallback: "et", namespaces: ["translation", "checkout"])
        )
        XCTAssertNil(localize.version)

        let result = try await localize.refresh()

        XCTAssertEqual(result, .updated(version: "v3"))
        XCTAssertEqual(localize.version, "v3")
        XCTAssertEqual(stub.requestCount("/demo/latest.json"), 1)
        XCTAssertEqual(stub.requests.first, "/demo/latest.json")
        XCTAssertEqual(stub.requests.count, 7)
        XCTAssertEqual(Set(stub.requests.dropFirst()), [
            "/demo/v3/en-FI/translation.json", "/demo/v3/en/translation.json", "/demo/v3/et/translation.json",
            "/demo/v3/en-FI/checkout.json", "/demo/v3/en/checkout.json", "/demo/v3/et/checkout.json",
        ])
        XCTAssertEqual(localize.string("a"), "en-FI")
        XCTAssertEqual(localize.string("b"), "en b")
        XCTAssertEqual(localize.string("c"), "et c")
        XCTAssertEqual(localize.string("pay", namespace: "checkout"), "en-FI pay")
    }

    func testAnInvalidPointerIsAConfigurationErrorAndNoFileIsRequested() async throws {
        let bodies = [
            #"{ "version": "latest" }"#, #"{ "version": "v0" }"#, #"{ "version": "v01" }"#,
            #"{ "version": "12" }"#, #"{ "version": "v1.2" }"#, #"{ "version": "v12 " }"#,
            #"{ "version": "V12" }"#, #"{ "version": "v१२" }"#, #"{ "version": "v" }"#,
            #"{ "version": 12 }"#, #"{ "version": null }"#, #"{ "release": "v12" }"#,
            #""v12""#, "[\"v12\"]", "v12", "", "<html>Not here</html>",
        ]
        for body in bodies {
            stub = StubTransport()
            stub.respond("/demo/latest.json", body: body)
            let localize = Localize(configuration: configuration())
            let url = URL(string: "https://cdn.test/demo/latest.json")!
            await assertThrows(.invalidPointer(url: url)) { try await localize.refresh() }
            XCTAssertFalse(LocalizeError.invalidPointer(url: url).isRetryable)
            XCTAssertEqual(stub.requests, ["/demo/latest.json"], body)
            XCTAssertNil(localize.version)
        }
    }

    func testAValidPointerMayCarryOtherFields() async throws {
        stub.respond("/demo/latest.json", body: #"{ "version": "v120", "publishedAt": "2026-01-01" }"#)
        stub.publish("v120", ["en/translation": ["a": "A"]])
        let localize = Localize(configuration: configuration())
        let result = try await localize.refresh()
        XCTAssertEqual(result, .updated(version: "v120"))
    }

    func testAPublishLandingMidRefreshDoesNotMixVersions() async throws {
        stub.publish("v1", [
            "en/translation": ["title": "title v1"],
            "en/checkout": ["pay": "pay v1"],
            "et/translation": ["title": "pealkiri v1"],
            "et/checkout": ["pay": "maksa v1"],
        ])
        stub.publish("v2", [
            "en/translation": ["title": "title v2"],
            "en/checkout": ["pay": "pay v2"],
            "et/translation": ["title": "pealkiri v2"],
            "et/checkout": ["pay": "maksa v2"],
        ])
        stub.setPointer("v1")
        // A publish lands the moment the pointer has been read, and again
        // after every file.
        let stub = self.stub
        stub.afterEachRequest { _ in stub.setPointer("v2") }
        let localize = Localize(
            configuration: configuration(fallback: "et", namespaces: ["translation", "checkout"])
        )

        let result = try await localize.refresh()

        XCTAssertEqual(result, .updated(version: "v1"))
        XCTAssertEqual(stub.requestCount("/demo/latest.json"), 1)
        XCTAssertTrue(stub.requests.dropFirst().allSatisfy { $0.hasPrefix("/demo/v1/") }, "\(stub.requests)")
        XCTAssertEqual(localize.string("title"), "title v1")
        XCTAssertEqual(localize.string("pay", namespace: "checkout"), "pay v1")

        // The next refresh reads the pointer again and moves to v2 as a whole.
        let next = try await localize.refresh()
        XCTAssertEqual(next, .updated(version: "v2"))
        XCTAssertEqual(localize.string("title"), "title v2")
        XCTAssertEqual(localize.string("pay", namespace: "checkout"), "pay v2")
    }

    func testAPinnedVersionSkipsThePointer() async throws {
        stub.setPointer("v9")
        stub.publish("v2", ["en/translation": ["a": "pinned"]])
        stub.publish("v9", ["en/translation": ["a": "latest"]])
        let localize = Localize(configuration: configuration(version: "v2"))

        let result = try await localize.refresh()

        XCTAssertEqual(result, .updated(version: "v2"))
        XCTAssertEqual(stub.requests, ["/demo/v2/en/translation.json"])
        XCTAssertEqual(localize.string("a"), "pinned")
        let again = try await localize.refresh()
        XCTAssertEqual(again, .upToDate(version: "v2"))
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testAnInvalidConfigurationFailsBeforeAnyRequest() async throws {
        for version in ["latest", "12", "v0", "v1/..", ""] {
            let localize = Localize(configuration: configuration(version: version))
            do {
                try await localize.refresh()
                XCTFail("version \(version) was accepted")
            } catch LocalizeError.invalidConfiguration {
            } catch {
                XCTFail("\(error)")
            }
        }
        for namespaces in [[], [""], [".."], ["translation", "."]] {
            let localize = Localize(configuration: configuration(namespaces: namespaces))
            do {
                try await localize.refresh()
                XCTFail("namespaces \(namespaces) were accepted")
            } catch LocalizeError.invalidConfiguration {
            } catch {
                XCTFail("\(error)")
            }
        }
        XCTAssertEqual(stub.requests, [])
        XCTAssertFalse(LocalizeError.invalidConfiguration("x").isRetryable)
    }

    func testRequestURLsAreBuiltAsTheJavaScriptSDKBuildsThem() throws {
        let loader = ReleaseLoader(
            projectSlug: "my app",
            cdnBaseURL: URL(string: "https://cdn.test/base//")!,
            transport: stub,
            timeout: 1
        )
        XCTAssertEqual(try loader.pointerURL().absoluteString, "https://cdn.test/base/my%20app/latest.json")
        XCTAssertEqual(
            try loader.fileURL(version: "v12", file: FileKey(locale: "en-FI", namespace: "a/b c?")).absoluteString,
            "https://cdn.test/base/my%20app/v12/en-FI/a%2Fb%20c%3F.json"
        )
        let plain = ReleaseLoader(
            projectSlug: "demo",
            cdnBaseURL: LocalizeConfiguration.defaultCDNBaseURL,
            transport: stub,
            timeout: 1
        )
        XCTAssertEqual(try plain.pointerURL().absoluteString, "https://cdn.localize.work/demo/latest.json")
        XCTAssertEqual(
            try plain.fileURL(version: "v3", file: FileKey(locale: "en", namespace: "common")).absoluteString,
            "https://cdn.localize.work/demo/v3/en/common.json"
        )
    }

    // MARK: 404s and failures

    func testAVariant404IsAnEmptyFileAndFallsBackToTheBaseLanguage() async throws {
        stub.setPointer("v1")
        stub.publish("v1", ["en/translation": ["greeting": "Hello", "bye": "Bye"]])
        let localize = Localize(configuration: configuration(locale: "en-FI"))

        let result = try await localize.refresh()

        XCTAssertEqual(result, .updated(version: "v1"))
        XCTAssertEqual(stub.requestCount("/demo/v1/en-FI/translation.json"), 1)
        XCTAssertEqual(localize.string("greeting"), "Hello")
        XCTAssertEqual(localize.string("bye"), "Bye")
        // The absent file is part of the release: it is not asked for again.
        let again = try await localize.refresh()
        XCTAssertEqual(again, .upToDate(version: "v1"))
        XCTAssertEqual(stub.requestCount("/demo/v1/en-FI/translation.json"), 1)
    }

    func testASparseVariantOverridesOnlyItsOwnKeys() async throws {
        let localize = try await loaded(
            [
                "en-FI/translation": ["greeting": "Moi"],
                "en/translation": ["greeting": "Hello", "bye": "Bye"],
            ],
            locale: "en-FI"
        )
        XCTAssertEqual(localize.string("greeting"), "Moi")
        XCTAssertEqual(localize.string("bye"), "Bye")
    }

    func testAMissingPointerMeansNothingIsPublished() async throws {
        let localize = Localize(configuration: configuration())
        let url = URL(string: "https://cdn.test/demo/latest.json")!
        await assertThrows(.projectNotPublished(url: url)) { try await localize.refresh() }
        XCTAssertFalse(LocalizeError.projectNotPublished(url: url).isRetryable)
        XCTAssertEqual(stub.requests, ["/demo/latest.json"])
    }

    func testAFailedDownloadKeepsTheCurrentRelease() async throws {
        let localize = try await loaded(["en/translation": ["a": "v1"]])
        stub.setPointer("v2")
        stub.publish("v2", ["en/translation": ["a": "v2"]])
        let fileURL = URL(string: "https://cdn.test/demo/v2/en/translation.json")!
        let pointerURL = URL(string: "https://cdn.test/demo/latest.json")!

        // A server error on a file.
        stub.respond("/demo/v2/en/translation.json", status: 500)
        await assertThrows(.http(status: 500, url: fileURL)) { try await localize.refresh() }
        XCTAssertTrue(LocalizeError.http(status: 500, url: fileURL).isRetryable)
        XCTAssertEqual(localize.string("a"), "v1")
        XCTAssertEqual(localize.version, "v1")

        // A client error other than 404 is an error too, and not retryable.
        stub.respond("/demo/v2/en/translation.json", status: 403)
        await assertThrows(.http(status: 403, url: fileURL)) { try await localize.refresh() }
        XCTAssertFalse(LocalizeError.http(status: 403, url: fileURL).isRetryable)

        // A body that is not a JSON object.
        for body in ["<html>", "[1, 2]", #""text""#, ""] {
            stub.respond("/demo/v2/en/translation.json", body: body)
            await assertThrows(.invalidFile(url: fileURL)) { try await localize.refresh() }
        }

        // No response at all.
        stub.fail("/demo/v2/en/translation.json")
        do {
            try await localize.refresh()
            XCTFail("expected a network error")
        } catch let error as LocalizeError {
            guard case .network(let url, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(url, fileURL)
            XCTAssertTrue(error.isRetryable)
        }

        // The pointer failing.
        stub.respond("/demo/latest.json", status: 503)
        await assertThrows(.http(status: 503, url: pointerURL)) { try await localize.refresh() }
        stub.fail("/demo/latest.json")
        do {
            try await localize.refresh()
            XCTFail("expected a network error")
        } catch let error as LocalizeError {
            guard case .network = error else { return XCTFail("\(error)") }
        }

        XCTAssertEqual(localize.string("a"), "v1")
        XCTAssertEqual(localize.version, "v1")
        // What is saved on the device is still v1 as well.
        XCTAssertEqual(savedFiles, ["current.json", "v1.json"])
        XCTAssertEqual(Localize(configuration: configuration()).string("a"), "v1")

        // Once the file can be downloaded, the release is applied.
        stub.setPointer("v2")
        stub.publish("v2", ["en/translation": ["a": "v2"]])
        let result = try await localize.refresh()
        XCTAssertEqual(result, .updated(version: "v2"))
        XCTAssertEqual(localize.string("a"), "v2")
    }

    func testTheSwitchToANewReleaseIsAllOrNothing() async throws {
        let namespaces = ["translation", "checkout"]
        let localize = try await loaded(
            [
                "en/translation": ["title": "title v1"],
                "en/checkout": ["pay": "pay v1"],
                "et/translation": ["title": "pealkiri v1"],
            ],
            fallback: "et",
            namespaces: namespaces
        )
        stub.setPointer("v2")
        stub.publish("v2", [
            "en/translation": ["title": "title v2"],
            "et/translation": ["title": "pealkiri v2"],
        ])
        // Three of v2's four files arrive; one does not.
        stub.respond("/demo/v2/en/checkout.json", status: 502)

        do {
            try await localize.refresh()
            XCTFail("the refresh should fail")
        } catch {}

        // Nothing of v2 is used, although most of it was downloaded.
        XCTAssertEqual(localize.version, "v1")
        XCTAssertEqual(localize.string("title"), "title v1")
        XCTAssertEqual(localize.string("pay", namespace: "checkout"), "pay v1")
        XCTAssertEqual(savedFiles, ["current.json", "v1.json"])
        let relaunched = Localize(configuration: configuration(fallback: "et", namespaces: namespaces))
        XCTAssertEqual(relaunched.version, "v1")
        XCTAssertEqual(relaunched.string("title"), "title v1")
    }

    // MARK: Cache

    func testOfflineStartFromTheSavedRelease() async throws {
        let first = try await loaded(
            [
                "en-FI/translation": ["greeting": "Moi"],
                "en/translation": ["greeting": "Hello", "items_one": "{{count}} item", "items_other": "{{count}} items"],
            ],
            locale: "en-FI"
        )
        XCTAssertEqual(first.string("greeting"), "Moi")

        // The next launch has no network at all.
        stub.goOffline()
        let offline = Localize(configuration: configuration(locale: "en-FI"))

        // Strings are there straight after init, before any refresh.
        XCTAssertEqual(offline.version, "v1")
        XCTAssertEqual(offline.string("greeting"), "Moi")
        XCTAssertEqual(offline.string("items", count: 2), "2 items")
        do {
            try await offline.refresh()
            XCTFail("offline refresh should fail")
        } catch let error as LocalizeError {
            XCTAssertTrue(error.isRetryable)
        }
        XCTAssertEqual(offline.string("greeting"), "Moi")
    }

    func testACorruptCacheIsDiscardedWithoutCrashing() async throws {
        let folder = cacheDirectory.appendingPathComponent("demo")
        let release = folder.appendingPathComponent("v1.json")
        let current = folder.appendingPathComponent("current.json")
        let damage: [(String, () throws -> Void)] = [
            ("truncated release", {
                let data = try Data(contentsOf: release)
                try data.prefix(data.count / 2).write(to: release)
            }),
            ("release is not JSON", { try Data("not json at all".utf8).write(to: release) }),
            ("release is binary", { try Data([0xFF, 0x00, 0xFE, 0x80]).write(to: release) }),
            ("release is empty", { try Data().write(to: release) }),
            ("release is an array", { try Data("[]".utf8).write(to: release) }),
            ("release has the wrong shape", {
                try Data(#"{"format":1,"projectSlug":"demo","source":"https://cdn.test","version":"v1","files":[{"locale":"en","namespace":"translation","contents":"text"}]}"#.utf8)
                    .write(to: release)
            }),
            ("release has an unknown format", {
                try Data(#"{"format":99,"projectSlug":"demo","source":"https://cdn.test","version":"v1","files":[]}"#.utf8)
                    .write(to: release)
            }),
            ("release names another version", {
                try Data(#"{"format":1,"projectSlug":"demo","source":"https://cdn.test","version":"v7","files":[]}"#.utf8)
                    .write(to: release)
            }),
            ("release is of another project", {
                try Data(#"{"format":1,"projectSlug":"other","source":"https://cdn.test","version":"v1","files":[]}"#.utf8)
                    .write(to: release)
            }),
            ("release is missing", { try FileManager.default.removeItem(at: release) }),
            ("pointer is not JSON", { try Data("garbage".utf8).write(to: current) }),
            ("pointer names no version", { try Data(#"{"version":"../../etc"}"#.utf8).write(to: current) }),
            ("pointer names a version that is not saved", { try Data(#"{"version":"v8"}"#.utf8).write(to: current) }),
            ("pointer is missing", { try FileManager.default.removeItem(at: current) }),
        ]
        for (name, corrupt) in damage {
            try? FileManager.default.removeItem(at: cacheDirectory)
            stub = StubTransport()
            let first = try await loaded(["en/translation": ["a": "A"]])
            XCTAssertEqual(first.string("a"), "A")
            XCTAssertEqual(savedFiles, ["current.json", "v1.json"], name)

            try corrupt()
            let relaunched = Localize(configuration: configuration())

            XCTAssertNil(relaunched.version, name)
            XCTAssertEqual(relaunched.string("a"), "a", name)
            XCTAssertEqual(savedFiles, [], name)
            // And it recovers with the next download.
            let result = try await relaunched.refresh()
            XCTAssertEqual(result, .updated(version: "v1"), name)
            XCTAssertEqual(relaunched.string("a"), "A", name)
            XCTAssertEqual(Localize(configuration: configuration()).string("a"), "A", name)
        }
    }

    /// Before the first unlock after a restart the saved files exist but
    /// cannot be read. They are left alone, not taken for damaged.
    func testASavedReleaseThatCannotBeReadYetIsKept() async throws {
        _ = try await loaded(["en/translation": ["a": "A"]])
        let folder = cacheDirectory.appendingPathComponent("demo")
        let release = folder.appendingPathComponent("v1.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: release.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: release.path) }

        let locked = Localize(configuration: configuration())
        XCTAssertNil(locked.version)
        XCTAssertEqual(locked.string("a"), "a")
        XCTAssertEqual(savedFiles, ["current.json", "v1.json"])

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: release.path)
        XCTAssertEqual(Localize(configuration: configuration()).string("a"), "A")
    }

    func testStreamsEndWhenTheInstanceGoesAway() async throws {
        var localize: Localize? = Localize(configuration: configuration())
        let updates = try XCTUnwrap(localize?.updates)
        localize = nil
        let started = Date()
        let value = await nextValue(of: updates, timeout: 5)
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the stream ended by timing out")
    }

    func testAReleaseSavedFromAnotherCDNIsNotUsed() async throws {
        _ = try await loaded(["en/translation": ["a": "A"]])
        var other = configuration()
        other.cdnBaseURL = URL(string: "https://staging.test")!
        XCTAssertNil(Localize(configuration: other).version)
    }

    func testOldVersionsAreCleanedUp() async throws {
        let localize = try await loaded(["en/translation": ["a": "v1"]])
        XCTAssertEqual(savedFiles, ["current.json", "v1.json"])
        // Something left behind by an interrupted save.
        let folder = cacheDirectory.appendingPathComponent("demo")
        try Data("{}".utf8).write(to: folder.appendingPathComponent("v0.json"))

        stub.setPointer("v2")
        stub.publish("v2", ["en/translation": ["a": "v2"]])
        try await localize.refresh()

        XCTAssertEqual(savedFiles, ["current.json", "v2.json"])
        XCTAssertEqual(Localize(configuration: configuration()).version, "v2")
    }

    func testARollbackToAnOlderVersionIsFollowed() async throws {
        let localize = try await loaded(["en/translation": ["a": "v1"]])
        stub.setPointer("v2")
        stub.publish("v2", ["en/translation": ["a": "v2"]])
        try await localize.refresh()
        XCTAssertEqual(localize.string("a"), "v2")

        stub.setPointer("v1")
        let result = try await localize.refresh()

        XCTAssertEqual(result, .updated(version: "v1"))
        XCTAssertEqual(localize.string("a"), "v1")
        XCTAssertEqual(savedFiles, ["current.json", "v1.json"])
        XCTAssertEqual(Localize(configuration: configuration()).version, "v1")
    }

    func testProjectsAreSavedApart() async throws {
        _ = try await loaded(["en/translation": ["a": "demo"]])
        let other = StubTransport(slug: "other/../project")
        other.setPointer("v1")
        other.respond("/other%2F..%2Fproject/latest.json", body: #"{ "version": "v4" }"#)
        other.respond("/other%2F..%2Fproject/v4/en/translation.json", body: #"{ "a": "other" }"#)
        var otherConfiguration = configuration()
        otherConfiguration.projectSlug = other.slug
        otherConfiguration.transport = other
        let localize = Localize(configuration: otherConfiguration)
        try await localize.refresh()

        XCTAssertEqual(localize.string("a"), "other")
        XCTAssertEqual(Localize(configuration: configuration()).string("a"), "demo")
        // The odd slug stayed inside the cache folder.
        let folders = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).sorted()
        XCTAssertEqual(folders, ["demo", "other%2F%2E%2E%2Fproject"])
    }

    func testAnUpToDateRefreshOnlyReadsThePointer() async throws {
        let localize = try await loaded(["en/translation": ["a": "A"]])
        let before = stub.requests.count
        let result = try await localize.refresh()
        XCTAssertEqual(result, .upToDate(version: "v1"))
        XCTAssertEqual(Array(stub.requests.dropFirst(before)), ["/demo/latest.json"])
    }

    func testAChangedLanguageDownloadsOnlyTheFilesItLacks() async throws {
        _ = try await loaded(["en/translation": ["a": "A", "b": "B"], "de/translation": ["a": "A auf Deutsch"]])
        let before = stub.requests.count

        // The device language is now German; English is the fallback. The
        // saved release has no German file, so it is not in use yet: the
        // app's bundled strings (none in this test) are in German, the saved
        // English text is not.
        let german = Localize(configuration: configuration(locale: "de", fallback: "en"))
        XCTAssertNil(german.version)
        XCTAssertEqual(german.string("a"), "a")
        let result = try await german.refresh()

        XCTAssertEqual(result, .updated(version: "v1"))
        XCTAssertEqual(Array(stub.requests.dropFirst(before)), ["/demo/latest.json", "/demo/v1/de/translation.json"])
        XCTAssertEqual(german.string("a"), "A auf Deutsch")
        XCTAssertEqual(german.string("b"), "B")
    }

    func testASavedReleaseWithoutTheNewLanguageStaysUnusedWhenTheDownloadFails() async throws {
        _ = try await loaded(["en/translation": ["a": "A"]])
        stub.goOffline()
        let german = Localize(configuration: configuration(locale: "de", fallback: "en"))
        do {
            try await german.refresh()
            XCTFail("expected the refresh to fail offline")
        } catch {}
        XCTAssertNil(german.version)
        XCTAssertEqual(german.string("a", fallback: "A (gebündelt)"), "A (gebündelt)")
        // The English release is still there for an English launch.
        let english = Localize(configuration: configuration(locale: "en"))
        XCTAssertEqual(english.string("a"), "A")
    }

    func testAPinnedVersionThatIsNotPublishedYetIsNotSavedAsEmpty() async throws {
        let localize = Localize(configuration: configuration(fallback: nil, version: "v3"))
        let url = URL(string: "\(StubTransport.base)/demo/v3/en/translation.json")!
        await assertThrows(.http(status: 404, url: url)) { try await localize.refresh() }
        XCTAssertNil(localize.version)
        XCTAssertEqual(savedFiles, [])

        // Once it is published the same instance, and a later launch, get it.
        stub.publish("v3", ["en/translation": ["a": "third"]])
        let result = try await localize.refresh()
        XCTAssertEqual(result, .updated(version: "v3"))
        XCTAssertEqual(localize.string("a"), "third")
        let relaunched = Localize(configuration: configuration(version: "v3"))
        XCTAssertEqual(relaunched.string("a"), "third")
    }

    /// A sparse variant with no file at all is still normal for a pinned
    /// version, as long as the version has some file.
    func testAPinnedVersionMayLackAVariantFile() async throws {
        stub.publish("v3", ["en/translation": ["a": "third"]])
        let localize = Localize(configuration: configuration(locale: "en-FI", version: "v3"))
        let result = try await localize.refresh()
        XCTAssertEqual(result, .updated(version: "v3"))
        XCTAssertEqual(localize.string("a"), "third")
    }

    func testASavedReleaseOfAnotherVersionIsNotUsedUnderAPin() async throws {
        stub.setPointer("v2")
        stub.publish("v2", ["en/translation": ["a": "second"]])
        let following = Localize(configuration: configuration())
        try await following.refresh()
        XCTAssertEqual(savedFiles, ["current.json", "v2.json"])

        // The app now ships pinned to v1 and starts offline.
        stub.goOffline()
        let pinned = Localize(configuration: configuration(version: "v1"))
        XCTAssertNil(pinned.version)
        XCTAssertEqual(pinned.string("a"), "a")
        for policy in [LocalizeUpdatePolicy.immediately, .nextLaunch] {
            let other = Localize(configuration: configuration(version: "v1", policy: policy))
            XCTAssertNil(other.version, "\(policy)")
        }
        // A launch pinned to the saved version uses it.
        XCTAssertEqual(Localize(configuration: configuration(version: "v2")).string("a"), "second")
    }

    // MARK: Next launch

    /// With the next-launch policy a newer release waits, but files missing
    /// from the release the launch started with are added to it at once.
    func testNextLaunchPolicyCompletesTheSavedReleaseForANewLanguage() async throws {
        _ = try await loaded(["en/translation": ["a": "A"], "de/translation": ["a": "A auf Deutsch"]])
        let german = Localize(configuration: configuration(locale: "de", fallback: "en", policy: .nextLaunch))
        XCTAssertNil(german.version)
        let updates = german.updates

        let result = try await german.refresh()

        XCTAssertEqual(result, .updated(version: "v1"))
        XCTAssertEqual(german.string("a"), "A auf Deutsch")
        let announced = await nextValue(of: updates)
        XCTAssertEqual(announced, "v1")
        let again = try await german.refresh()
        XCTAssertEqual(again, .upToDate(version: "v1"))
    }

    func testNextLaunchPolicyKeepsANewerReleaseForTheNextLaunchAfterALanguageChange() async throws {
        _ = try await loaded(["en/translation": ["a": "A"]])
        stub.setPointer("v2")
        stub.publish("v2", ["en/translation": ["a": "A2"], "de/translation": ["a": "A2 auf Deutsch"]])
        let german = Localize(configuration: configuration(locale: "de", fallback: "en", policy: .nextLaunch))

        let result = try await german.refresh()

        XCTAssertEqual(result, .pendingNextLaunch(version: "v2"))
        XCTAssertNil(german.version)
        XCTAssertEqual(german.string("a"), "a")
        let next = Localize(configuration: configuration(locale: "de", fallback: "en", policy: .nextLaunch))
        XCTAssertEqual(next.string("a"), "A2 auf Deutsch")
    }

    func testNextLaunchPolicyAppliesADownloadOnlyAtTheNextLaunch() async throws {
        stub.setPointer("v1")
        stub.publish("v1", ["en/translation": ["a": "v1"]])
        let first = Localize(configuration: configuration(policy: .nextLaunch))
        let observed = expectation(forNotification: Localize.didUpdateNotification, object: nil)
        observed.isInverted = true

        let firstResult = try await first.refresh()

        // Downloaded and saved, but not in use in this run.
        XCTAssertEqual(firstResult, .pendingNextLaunch(version: "v1"))
        XCTAssertNil(first.version)
        XCTAssertEqual(first.string("a"), "a")
        XCTAssertEqual(savedFiles, ["current.json", "v1.json"])
        // Asking again downloads nothing more.
        let repeated = try await first.refresh()
        XCTAssertEqual(repeated, .pendingNextLaunch(version: "v1"))
        XCTAssertEqual(stub.requestCount("/demo/v1/en/translation.json"), 1)

        // Second launch: v1 is in use from the start.
        let second = Localize(configuration: configuration(policy: .nextLaunch))
        XCTAssertEqual(second.version, "v1")
        XCTAssertEqual(second.string("a"), "v1")
        let upToDate = try await second.refresh()
        XCTAssertEqual(upToDate, .upToDate(version: "v1"))

        // v2 is published while the second launch runs.
        stub.setPointer("v2")
        stub.publish("v2", ["en/translation": ["a": "v2"]])
        let secondResult = try await second.refresh()
        XCTAssertEqual(secondResult, .pendingNextLaunch(version: "v2"))
        XCTAssertEqual(second.version, "v1")
        XCTAssertEqual(second.string("a"), "v1")
        XCTAssertEqual(savedFiles, ["current.json", "v2.json"])

        // Third launch: v2.
        let third = Localize(configuration: configuration(policy: .nextLaunch))
        XCTAssertEqual(third.version, "v2")
        XCTAssertEqual(third.string("a"), "v2")

        await fulfillment(of: [observed], timeout: 0.2)
    }

    func testNextLaunchPolicyFailsWhenTheReleaseCannotBeSaved() async throws {
        stub.setPointer("v1")
        stub.publish("v1", ["en/translation": ["a": "v1"]])
        // A file where the cache folder should be.
        try Data().write(to: cacheDirectory)
        let localize = Localize(configuration: configuration(policy: .nextLaunch))
        do {
            try await localize.refresh()
            XCTFail("expected the save to fail")
        } catch let error as LocalizeError {
            guard case .cacheWriteFailed = error else { return XCTFail("\(error)") }
        }
        // With the immediate policy the release is still used for this run.
        let immediate = Localize(configuration: configuration())
        let result = try await immediate.refresh()
        XCTAssertEqual(result, .updated(version: "v1"))
        XCTAssertEqual(immediate.string("a"), "v1")
    }

    // MARK: Updates

    func testAnUpdateIsAnnouncedOnTheStreamAndAsANotification() async throws {
        stub.setPointer("v1")
        stub.publish("v1", ["en/translation": ["a": "v1"]])
        let localize = Localize(configuration: configuration())
        let updates = localize.updates
        let second = localize.updates
        let notified = expectation(forNotification: Localize.didUpdateNotification, object: localize) { notification in
            Thread.isMainThread && notification.userInfo?[Localize.versionUserInfoKey] as? String == "v1"
        }

        try await localize.refresh()

        await fulfillment(of: [notified], timeout: 2)
        let first = await nextValue(of: updates)
        XCTAssertEqual(first, "v1")
        let alsoFirst = await nextValue(of: second)
        XCTAssertEqual(alsoFirst, "v1")

        // A refresh that changes nothing announces nothing.
        let quiet = expectation(forNotification: Localize.didUpdateNotification, object: localize)
        quiet.isInverted = true
        try await localize.refresh()
        await fulfillment(of: [quiet], timeout: 0.2)

        // The next release is announced.
        stub.setPointer("v2")
        stub.publish("v2", ["en/translation": ["a": "v2"]])
        try await localize.refresh()
        let next = await nextValue(of: updates)
        XCTAssertEqual(next, "v2")
    }

    func testAFailedRefreshAnnouncesNothing() async throws {
        let localize = try await loaded(["en/translation": ["a": "v1"]])
        let quiet = expectation(forNotification: Localize.didUpdateNotification, object: localize)
        quiet.isInverted = true
        stub.setPointer("v2")
        stub.respond("/demo/v2/en/translation.json", status: 500)
        do {
            try await localize.refresh()
            XCTFail("the refresh should fail")
        } catch {}
        await fulfillment(of: [quiet], timeout: 0.2)
    }

    // MARK: Concurrency

    func testConcurrentLookupsDuringARefresh() async throws {
        let v1: [String: Any] = [
            "title": "title v1",
            "greeting": "Hello {{name}} from v1",
            "items_one": "{{count}} item v1",
            "items_other": "{{count}} items v1",
        ]
        let v2: [String: Any] = [
            "title": "title v2",
            "greeting": "Hello {{name}} from v2",
            "items_one": "{{count}} item v2",
            "items_other": "{{count}} items v2",
        ]
        let localize = try await loaded(["en/translation": v1])
        stub.setPointer("v2")
        stub.publish("v2", ["en/translation": v2])
        // Hold the download of v2 until the lookups are under way.
        let gate = Gate()
        stub.afterEachRequest { path in
            if path.contains("/v2/") { await gate.wait() }
        }

        let refresh = Task { try await localize.refresh() }
        let lookups = Task.detached { () -> Set<String> in
            await withTaskGroup(of: Set<String>.self) { group in
                for worker in 0..<8 {
                    group.addTask {
                        var seen: Set<String> = []
                        for round in 0..<3000 {
                            seen.insert(localize.string("title"))
                            seen.insert(localize.string("greeting", ["name": "Ann"]))
                            seen.insert(localize.string("items", count: 1 + (round + worker) % 2))
                            seen.insert(localize.string("missing"))
                            if round == 500 && worker == 0 { await gate.open() }
                            if round % 100 == 0 { await Task.yield() }
                        }
                        return seen
                    }
                }
                return await group.reduce(into: Set<String>()) { $0.formUnion($1) }
            }
        }

        let seen = await lookups.value
        let result = try await refresh.value

        XCTAssertEqual(result, .updated(version: "v2"))
        let allowed: Set<String> = [
            "title v1", "Hello Ann from v1", "1 item v1", "2 items v1",
            "title v2", "Hello Ann from v2", "1 item v2", "2 items v2",
            "missing",
        ]
        XCTAssertTrue(seen.isSubset(of: allowed), "\(seen.subtracting(allowed))")
        XCTAssertTrue(seen.contains("title v1"))
        XCTAssertEqual(localize.string("title"), "title v2")
        XCTAssertEqual(localize.string("items", count: 2), "2 items v2")
    }

    func testConcurrentRefreshCallsShareOneDownload() async throws {
        stub.setPointer("v1")
        stub.publish("v1", ["en/translation": ["a": "A"]])
        let gate = Gate()
        stub.afterEachRequest { _ in await gate.wait() }
        let localize = Localize(configuration: configuration())

        let calls = (0..<6).map { _ in Task { try await localize.refresh() } }
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()
        var results: [LocalizeRefreshResult] = []
        for call in calls {
            results.append(try await call.value)
        }

        XCTAssertEqual(results, Array(repeating: .updated(version: "v1"), count: 6))
        XCTAssertEqual(stub.requests, ["/demo/latest.json", "/demo/v1/en/translation.json"])
        // A refresh after that one is a new one.
        let later = try await localize.refresh()
        XCTAssertEqual(later, .upToDate(version: "v1"))
        XCTAssertEqual(stub.requestCount("/demo/latest.json"), 2)
    }

    // MARK: Shared instance

    /// `configure` called again while the earlier instance is still
    /// downloading: the earlier one must not save over the later one.
    func testAReplacedInstanceSavesNothing() async throws {
        addTeardownBlock { Localize.resetShared() }
        stub.setPointer("v1")
        stub.publish("v1", ["en/translation": ["a": "A"], "et/translation": ["a": "A eesti keeles"]])
        let gate = Gate()
        stub.afterEachRequest { path in
            if path == "/demo/v1/en/translation.json" { await gate.wait() }
        }
        let english = Localize.configure(configuration(locale: "en"), refresh: false)
        let stalled = Task { try await english.refresh() }
        // Wait until the English download is under way.
        while stub.requestCount("/demo/v1/en/translation.json") == 0 { await Task.yield() }

        // The app switches to Estonian.
        let estonian = Localize.configure(configuration(locale: "et"), refresh: false)
        let result = try await estonian.refresh()
        XCTAssertEqual(result, .updated(version: "v1"))

        await gate.open()
        do {
            _ = try await stalled.value
            XCTFail("expected the replaced instance to stop")
        } catch let error as LocalizeError {
            XCTAssertEqual(error, .replaced)
        }
        XCTAssertNil(english.version)
        // What is saved is still the Estonian release.
        stub.goOffline()
        let relaunched = Localize(configuration: configuration(locale: "et"))
        XCTAssertEqual(relaunched.string("a"), "A eesti keeles")
    }

    func testTheSharedInstance() async throws {
        addTeardownBlock { Localize.resetShared() }
        // Before configure: no project.
        let unconfigured = Localize.shared
        XCTAssertEqual(unconfigured.string("nav.home"), "nav.home")
        XCTAssertEqual(unconfigured.string("nav.home", fallback: "Home"), "Home")
        await assertThrows(.notConfigured) { try await unconfigured.refresh() }

        stub.setPointer("v1")
        stub.publish("v1", ["en/translation": ["nav": ["home": "Home"]]])
        let configured = Localize.configure(configuration(), refresh: false)
        XCTAssertTrue(Localize.shared === configured)
        XCTAssertEqual(stub.requests, [])

        // By default configure downloads the latest release in the background.
        // The download is held until the test listens for its result.
        let gate = Gate()
        stub.afterEachRequest { _ in await gate.wait() }
        let background = Localize.configure(configuration())
        XCTAssertTrue(Localize.shared === background)
        let updates = background.updates
        let notified = expectation(forNotification: Localize.didUpdateNotification, object: background)
        await gate.open()
        let version = await nextValue(of: updates)
        XCTAssertEqual(version, "v1")
        await fulfillment(of: [notified], timeout: 2)
        XCTAssertEqual(Localize.shared.string("nav.home"), "Home")
    }
}
