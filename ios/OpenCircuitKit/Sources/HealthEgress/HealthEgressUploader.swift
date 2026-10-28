import Foundation

/// The slice of URLSession the uploader uses. A fake implementing exactly this stands in for
/// URLSession in the unit tests (the tests must not need a live network or a live HKHealthStore).
public protocol HealthEgressURLSession: Sendable {
    func egressData(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HealthEgressURLSession {
    /// Wraps the completion-handler task, not the async `data(for:)`, so the package needs no
    /// new OS minimums (the async overload is macOS 12+; this package declares none).
    public func egressData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = dataTask(with: request) { data, response, error in
                switch (data, response, error) {
                case let (_, _, error?): continuation.resume(throwing: error)
                case let (data?, response?, _): continuation.resume(returning: (data, response))
                default: continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
}

/// The ONE persistence the module keeps outside the token: the sync anchor and the status
/// fields, in `UserDefaults` — the same key-value store the codebase already uses for every
/// other cursor (`calibration.baseURL`, the derived-write watermarks, `ProfileDefaults`).
/// No new store.
public struct HealthEgressAnchorStore: @unchecked Sendable { // UserDefaults is thread-safe
    public static let anchorKey = "ringpool.egress.anchor"
    public static let lastSyncKey = "ringpool.egress.lastSync"
    public static let samplesSentKey = "ringpool.egress.samplesSent"
    public static let lastErrorKey = "ringpool.egress.lastError"

    /// The anchor sent WITH the next batch ("" before the first successful sync).
    public let currentAnchor: String
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.currentAnchor = defaults.string(forKey: Self.anchorKey) ?? ""
    }

    /// The anchor-only-after-2xx rule, in one place: called ONLY when the POST came back 2xx.
    /// A failed POST stores an error string but never touches the anchor, so the same samples
    /// are re-offered on the next run (HealthKit anchors are additive, so this is safe).
    public func commit(anchor: String, sampleCount: Int) {
        defaults.set(anchor, forKey: Self.anchorKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastSyncKey)
        defaults.set(sampleCount, forKey: Self.samplesSentKey)
        defaults.removeObject(forKey: Self.lastErrorKey)
    }

    public func recordFailure(_ message: String) {
        defaults.set(message, forKey: Self.lastErrorKey)
    }

    /// One-line status for Settings: last sync time, samples sent, last error. Nil until
    /// anything has ever happened, so the row can hide itself on a fresh install.
    public static func statusLine(defaults: UserDefaults = .standard) -> String? {
        let syncTime = defaults.object(forKey: lastSyncKey) as? Double
        let error = defaults.string(forKey: lastErrorKey)
        let samples = defaults.object(forKey: samplesSentKey) as? Int
        guard syncTime != nil || error != nil else { return nil }
        var parts: [String] = []
        if let syncTime {
            let date = Date(timeIntervalSince1970: syncTime)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            parts.append("Last sync \(formatter.string(from: date))")
        } else {
            parts.append("Never synced")
        }
        parts.append("\(samples ?? 0) samples sent")
        if let error, !error.isEmpty { parts.append("last error: \(error)") }
        return parts.joined(separator: " · ")
    }
}

/// POSTs one batch and applies the anchor rule. Kept independent of HealthKit so it is fully
/// unit-testable with a fake session and fake samples.
public struct HealthEgressUploader: Sendable {
    private let session: any HealthEgressURLSession

    public init(session: any HealthEgressURLSession = URLSession.shared) {
        self.session = session
    }

    /// What the collector's 2xx body may carry back: an anchor override the client should
    /// adopt INSTEAD of its read anchor (e.g. to force a re-read window). Optional.
    public struct Ack: Sendable {
        public let anchor: String?
    }

    /// Sends `batchData` to `<baseURL>/v1/healthkit/batch` as `POST` with the bearer token.
    /// (Collector route `health-ingest.py` `POST /v1/healthkit/batch` — pinned by the
    /// anchor-rule tests, because a wrong path here 401/404s identically on a typo'd path.)
    /// - Throws `HealthEgressError.http(code)` on non-2xx — after which the caller stores
    ///   NOTHING for the anchor.
    public func upload(batchData: Data, config: HealthEgressConfig) async throws -> Ack {
        guard !config.token.isEmpty, !config.baseURL.isEmpty else { throw HealthEgressError.notConfigured }
        guard var components = URLComponents(string: config.baseURL) else { throw HealthEgressError.notConfigured }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/v1/healthkit/batch"
        guard let url = components.url else { throw HealthEgressError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = batchData
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await session.egressData(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            // Non-2xx: throw BEFORE the caller stores anything, so the anchor never moves.
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            throw snippet.isEmpty ? HealthEgressError.http(status)
                                  : HealthEgressError.transport("HTTP \(status): \(snippet)")
        }
        // Optional server-returned anchor ({"anchor": "..."}). Absent → the caller keeps the
        // anchor its own read produced; either way this only happens on 2xx.
        var ackAnchor: String?
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let anchor = body["anchor"] as? String {
            ackAnchor = anchor
        }
        return Ack(anchor: ackAnchor)
    }
}
