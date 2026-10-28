import Foundation

/// Result of one anchored HealthKit read: the samples found since the previous anchor, and
/// the NEW anchor string to store once (and only once) the batch is accepted.
public struct HealthEgressReadResult: Sendable {
    public let samples: [EgressSample]
    public let newAnchor: String
    public init(samples: [EgressSample], newAnchor: String) {
        self.samples = samples
        self.newAnchor = newAnchor
    }
}

/// The read side, behind a protocol so the coordinator is testable without a live
/// `HKHealthStore` (see the note in OpenCircuitKitTests on why HK is unmockable).
public protocol HealthEgressReading: Sendable {
    /// Read everything newer than `previousAnchor` (nil = first run).
    func readSamples(previousAnchor: String?) async throws -> HealthEgressReadResult
}

/// One egress sync: read → build batch → POST → commit the anchor ONLY on a 2xx.
///
/// Everything on this path is best-effort and never blocks the UI: callers fire it inside a
/// `Task` from the sync-completion handler or a BGTask, exactly like the existing
/// `flushToHealth` calls. A failed POST records the error for the Settings status line and
/// leaves the anchor alone, so the same samples ride along with the next run.
public struct HealthEgressCoordinator: @unchecked Sendable { // UserDefaults is thread-safe
    public let reader: any HealthEgressReading
    public let uploader: HealthEgressUploader
    public let tokenStore: any HealthEgressTokenPersisting
    public let defaults: UserDefaults

    public init(reader: any HealthEgressReading,
                uploader: HealthEgressUploader = HealthEgressUploader(),
                tokenStore: any HealthEgressTokenPersisting = HealthEgressKeychainTokenStore(),
                defaults: UserDefaults = .standard) {
        self.reader = reader
        self.uploader = uploader
        self.tokenStore = tokenStore
        self.defaults = defaults
    }

    public enum Outcome: Sendable, Equatable {
        case disabled          // no token yet (deep link never consumed) — silent no-op
        case empty             // nothing new since the anchor
        case sent(Int)         // samples accepted, anchor advanced
    }

    @discardableResult
    public func sync() async -> Outcome {
        await syncNow()
    }

    @discardableResult
    public func syncNow() async -> Outcome {
        guard let config = HealthEgressConfig.current(defaults: defaults, tokenStore: tokenStore) else {
            return .disabled
        }
        let store = HealthEgressAnchorStore(defaults: defaults)
        let previousAnchor = store.currentAnchor.isEmpty ? nil : store.currentAnchor
        let read: HealthEgressReadResult
        do {
            read = try await reader.readSamples(previousAnchor: previousAnchor)
        } catch {
            store.recordFailure("health read: \(error.localizedDescription)")
            return .empty
        }
        guard !read.samples.isEmpty else { return .empty }
        let batch: Data
        do {
            batch = try HealthEgressBatchBuilder.build(
                uploadId: UUID().uuidString,
                appVersion: config.appVersion,
                device: config.device,
                anchor: previousAnchor ?? "",
                samples: read.samples)
        } catch {
            store.recordFailure("batch build: \(error.localizedDescription)")
            return .empty
        }
        do {
            let ack = try await uploader.upload(batchData: batch, config: config)
            // THE rule: the anchor is stored only after a 2xx. The server's returned anchor
            // wins when present; otherwise the anchor this read produced.
            store.commit(anchor: ack.anchor ?? read.newAnchor, sampleCount: read.samples.count)
            return .sent(read.samples.count)
        } catch {
            store.recordFailure(error.localizedDescription)
            return .empty
        }
    }
}
