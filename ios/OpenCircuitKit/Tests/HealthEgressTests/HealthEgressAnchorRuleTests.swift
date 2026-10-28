import XCTest
@testable import HealthEgress

/// Fake URLSession: records the requests it was asked to send and replays a canned response
/// (or throws). The whole anchor rule is testable without any network.
private final class FakeURLSession: HealthEgressURLSession, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
        init(status: Int, body: Data = Data()) { self.status = status; self.body = body }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var thrown: Error?
    private(set) var requests: [URLRequest] = []

    init(replies: [Reply], thrown: Error? = nil) {
        self.replies = replies
        self.thrown = thrown
    }

    func egressData(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        requests.append(request)
        let reply = replies.isEmpty ? Reply(status: 200) : replies.removeFirst()
        let error = thrown
        lock.unlock()
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        return (reply.body, response)
    }
}

/// Fake reader standing in for the HealthKit store (HKHealthStore is unmockable — see the
/// note in OpenCircuitKitTests; only the batch/anchor halves are tested here).
private final class FakeReader: HealthEgressReading, @unchecked Sendable {
    let samples: [EgressSample]
    let newAnchor: String
    private(set) var askedForPrevious: [String?] = []
    private let lock = NSLock()

    init(samples: [EgressSample], newAnchor: String) {
        self.samples = samples
        self.newAnchor = newAnchor
    }

    func readSamples(previousAnchor: String?) async throws -> HealthEgressReadResult {
        lock.lock(); askedForPrevious.append(previousAnchor); lock.unlock()
        return HealthEgressReadResult(samples: samples, newAnchor: newAnchor)
    }
}

final class HealthEgressAnchorRuleTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "HealthEgressAnchorRuleTests"

    private func fakeSample(_ uuid: String) -> EgressSample {
        EgressSample(ts: "2026-10-29T00:00:00Z", tsEnd: "2026-10-29T00:00:00Z",
                     type: "HKQuantityTypeIdentifierHeartRate", unit: "count/min",
                     value: 60, valueStr: "", sourceBundleId: "com.deansdomain.ringpool",
                     sourceName: "Ringpool", deviceId: "iPhone17,2", osVersion: "26.5",
                     version: "1.0", uuid: uuid)
    }

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        HealthEgressDefaultsTokenStore(defaults: defaults).save(token: "tok")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func coordinator(reader: FakeReader, session: FakeURLSession) -> HealthEgressCoordinator {
        HealthEgressCoordinator(reader: reader,
                                uploader: HealthEgressUploader(session: session),
                                tokenStore: HealthEgressDefaultsTokenStore(defaults: defaults),
                                defaults: defaults)
    }

    private func storedAnchor() -> String? { defaults.string(forKey: HealthEgressAnchorStore.anchorKey) }
    private func lastError() -> String? { defaults.string(forKey: HealthEgressAnchorStore.lastErrorKey) }

    /// THE rule, part 1: a non-2xx must NOT move the anchor — the same samples ride the next run.
    func testFailedPostDoesNotAdvanceTheAnchor() async {
        defaults.set("OLD", forKey: HealthEgressAnchorStore.anchorKey)
        let reader = FakeReader(samples: [fakeSample("A")], newAnchor: "NEW")
        let session = FakeURLSession(replies: [FakeURLSession.Reply(status: 500, body: Data("boom".utf8))])
        let outcome = await coordinator(reader: reader, session: session).syncNow()
        XCTAssertEqual(outcome, .empty)
        XCTAssertEqual(storedAnchor(), "OLD", "anchor must not advance on 500")
        XCTAssertNotNil(lastError())
        XCTAssertEqual(reader.askedForPrevious, ["OLD"], "the batch carries the stored anchor")
        let body = try! XCTUnwrap(session.requests.first?.httpBody)
        let obj = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(obj["anchor"] as? String, "OLD")
        XCTAssertTrue(obj["upload_id"] is String)
        XCTAssertEqual(session.requests.first?.url?.path, "/v1/healthkit/batch",
                       "the collector serves POST /v1/healthkit/batch — pin the route")
        XCTAssertEqual(session.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testTransportErrorDoesNotAdvanceTheAnchor() async {
        let reader = FakeReader(samples: [fakeSample("A")], newAnchor: "NEW")
        let session = FakeURLSession(replies: [], thrown: URLError(.timedOut))
        await coordinator(reader: reader, session: session).syncNow()
        XCTAssertNil(storedAnchor())
        XCTAssertNotNil(lastError())
    }

    /// THE rule, part 2: a 2xx stores the anchor the READ produced (plus status, minus error).
    func testAcceptedPostStoresTheReadAnchor() async {
        defaults.set("OLD", forKey: HealthEgressAnchorStore.anchorKey)
        defaults.set("stale error", forKey: HealthEgressAnchorStore.lastErrorKey)
        let reader = FakeReader(samples: [fakeSample("A"), fakeSample("B")], newAnchor: "NEW")
        let session = FakeURLSession(replies: [FakeURLSession.Reply(status: 202)])
        let outcome = await coordinator(reader: reader, session: session).syncNow()
        XCTAssertEqual(outcome, .sent(2))
        XCTAssertEqual(storedAnchor(), "NEW")
        XCTAssertNil(lastError(), "success clears the stale error")
        XCTAssertEqual(defaults.object(forKey: HealthEgressAnchorStore.samplesSentKey) as? Int, 2)
        XCTAssertNotNil(defaults.object(forKey: HealthEgressAnchorStore.lastSyncKey))
        XCTAssertNotNil(HealthEgressAnchorStore.statusLine(defaults: defaults))
    }

    /// A server-returned anchor overrides the client's read anchor — but still only after 2xx.
    func testServerReturnedAnchorWinsOn2xx() async {
        let reader = FakeReader(samples: [fakeSample("A")], newAnchor: "NEW")
        let session = FakeURLSession(replies: [FakeURLSession.Reply(status: 200, body: Data(#"{"anchor":"SERVER"}"#.utf8))])
        await coordinator(reader: reader, session: session).syncNow()
        XCTAssertEqual(storedAnchor(), "SERVER")
    }

    func testNoTokenIsSilentAndSendsNothing() async {
        HealthEgressDefaultsTokenStore(defaults: defaults).clear()
        let reader = FakeReader(samples: [fakeSample("A")], newAnchor: "NEW")
        let session = FakeURLSession(replies: [])
        let outcome = await coordinator(reader: reader, session: session).syncNow()
        XCTAssertEqual(outcome, .disabled)
        XCTAssertTrue(session.requests.isEmpty)
    }

    func testEmptyReadSendsNothing() async {
        let reader = FakeReader(samples: [], newAnchor: "NEW")
        let session = FakeURLSession(replies: [])
        let outcome = await coordinator(reader: reader, session: session).syncNow()
        XCTAssertEqual(outcome, .empty)
        XCTAssertTrue(session.requests.isEmpty)
    }
}

final class HealthEgressDeepLinkTests: XCTestCase {
    func testParsesTokenDeepLink() {
        XCTAssertEqual(HealthEgressDeepLink.token(from: URL(string: "ringpool://set?token=abc123")!), "abc123")
    }
    func testRejectsEverythingElse() {
        XCTAssertNil(HealthEgressDeepLink.token(from: URL(string: "ringpool://set?token=")!))
        XCTAssertNil(HealthEgressDeepLink.token(from: URL(string: "ringpool://set")!))
        XCTAssertNil(HealthEgressDeepLink.token(from: URL(string: "ringpool://headache/log")!))
        XCTAssertNil(HealthEgressDeepLink.token(from: URL(string: "opencircuit://set?token=abc")!))
    }
    func testDefaultsTokenStoreRoundTrip() {
        let suite = "HealthEgressDeepLinkTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = HealthEgressDefaultsTokenStore(defaults: defaults)
        XCTAssertNil(store.load())
        store.save(token: "  tok  ")
        XCTAssertEqual(store.load(), "tok")
        store.save(token: "")
        XCTAssertNil(store.load())
        defaults.removePersistentDomain(forName: suite)
    }
}
