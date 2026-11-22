import Foundation
import XCTest
@testable import LocalizeWork

/// Answers the SDK's requests from memory. Anything not set up is a 404, as
/// on the real CDN.
final class StubTransport: LocalizeTransport, @unchecked Sendable {
    static let base = "https://cdn.test"

    private let lock = NSLock()
    private var responses: [String: LocalizeHTTPResponse] = [:]
    private var failures: [String: Error] = [:]
    private var recorded: [String] = []
    private var hook: (@Sendable (String) async -> Void)?

    let slug: String

    init(slug: String = "demo") {
        self.slug = slug
    }

    /// The paths requested so far, in order, such as `/demo/latest.json`.
    var requests: [String] {
        lock.withLock { recorded }
    }

    func requestCount(_ path: String) -> Int {
        requests.filter { $0 == path }.count
    }

    var pointerPath: String { "/\(slug)/latest.json" }

    func setPointer(_ version: String) {
        respond(pointerPath, body: "{ \"version\": \"\(version)\" }")
    }

    /// Publishes files of a version. Keys are `locale/namespace`.
    func publish(_ version: String, _ files: [String: Any]) {
        for (name, contents) in files {
            let body = (try? JSONSerialization.data(withJSONObject: contents)) ?? Data()
            lock.withLock {
                failures["/\(slug)/\(version)/\(name).json"] = nil
                responses["/\(slug)/\(version)/\(name).json"] = LocalizeHTTPResponse(statusCode: 200, body: body)
            }
        }
    }

    func respond(_ path: String, status: Int = 200, body: String = "") {
        lock.withLock {
            failures[path] = nil
            responses[path] = LocalizeHTTPResponse(statusCode: status, body: Data(body.utf8))
        }
    }

    /// Makes a path fail without a response, as when offline.
    func fail(_ path: String, _ error: Error = URLError(.notConnectedToInternet)) {
        lock.withLock { failures[path] = error }
    }

    /// Makes every request fail without a response.
    func goOffline() {
        lock.withLock { offline = true }
    }

    private var offline = false

    /// Runs after a request's answer is settled and before it is returned.
    func afterEachRequest(_ hook: (@Sendable (String) async -> Void)?) {
        lock.withLock { self.hook = hook }
    }

    func get(_ url: URL, timeout: TimeInterval) async throws -> LocalizeHTTPResponse {
        let path = String(url.absoluteString.dropFirst(Self.base.count))
        let (result, hook) = lock.withLock { () -> (Result<LocalizeHTTPResponse, Error>, (@Sendable (String) async -> Void)?) in
            recorded.append(path)
            if offline { return (.failure(URLError(.notConnectedToInternet)), self.hook) }
            if let failure = failures[path] { return (.failure(failure), self.hook) }
            return (.success(responses[path] ?? LocalizeHTTPResponse(statusCode: 404)), self.hook)
        }
        await hook?(path)
        return try result.get()
    }
}

/// Holds callers back until it is opened.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// A test case with a stub CDN and a cache folder of its own.
class LocalizeTestCase: XCTestCase {
    var stub = StubTransport()
    var cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() {
        super.setUp()
        stub = StubTransport()
        cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalizeWorkTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    func configuration(
        locale: String = "en",
        fallback: String? = nil,
        namespaces: [String] = ["translation"],
        defaultNamespace: String? = nil,
        version: String? = nil,
        policy: LocalizeUpdatePolicy = .immediately,
        bundle: Bundle = .main
    ) -> LocalizeConfiguration {
        LocalizeConfiguration(
            projectSlug: stub.slug,
            locale: locale,
            fallbackLocale: fallback,
            namespaces: namespaces,
            defaultNamespace: defaultNamespace,
            version: version,
            updatePolicy: policy,
            cdnBaseURL: URL(string: StubTransport.base)!,
            requestTimeout: 5,
            bundle: bundle,
            transport: stub,
            cacheDirectory: cacheDirectory
        )
    }

    /// An instance that has downloaded `files` as version `v1`.
    func loaded(
        _ files: [String: Any],
        locale: String = "en",
        fallback: String? = nil,
        namespaces: [String] = ["translation"],
        bundle: Bundle = .main
    ) async throws -> Localize {
        stub.setPointer("v1")
        stub.publish("v1", files)
        let localize = Localize(
            configuration: configuration(locale: locale, fallback: fallback, namespaces: namespaces, bundle: bundle)
        )
        try await localize.refresh()
        return localize
    }

    /// The names of the files saved for the stub's project.
    var savedFiles: [String] {
        let folder = cacheDirectory.appendingPathComponent(stub.slug)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func assertThrows(
        _ expected: LocalizeError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected), but nothing was thrown", file: file, line: line)
        } catch let error as LocalizeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

/// The next value of a stream, or nil when none arrives in time.
func nextValue<Value: Sendable>(of stream: AsyncStream<Value>, timeout: TimeInterval = 2) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// A published file from its JSON text.
func publishedFile(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Node] {
    guard let contents = ReleaseJSON.file(from: Data(json.utf8)) else {
        XCTFail("not a JSON object: \(json)", file: file, line: line)
        return [:]
    }
    return contents
}
