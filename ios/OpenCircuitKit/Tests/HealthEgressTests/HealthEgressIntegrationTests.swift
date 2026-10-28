import XCTest
@testable import HealthEgress

/// Live proof against the REAL collector: the production path end to end —
/// `HealthEgressConfig.current` → `HealthEgressBatchBuilder` → `HealthEgressUploader` over a
/// real `URLSession` and real TLS — posting one 3-sample batch (HR, sleep stage, workout) and
/// requiring a 2xx + the anchor commit. The rows land in ClickHouse
/// (`health.healthkit_samples`, device `iPhone17,2`, type `HKQuantityTypeIdentifierHeartRate`
/// with the marker in `source_name`), which is the out-of-band verification the run log cites.
///
/// Skipped unless ALL of `HEALTH_EGRESS_INTEGRATION=1`, `HEALTH_EGRESS_BASE_URL` and
/// `HEALTH_EGRESS_TOKEN` are set, so `swift test` stays offline-friendly:
///   HEALTH_EGRESS_INTEGRATION=1 \
///   HEALTH_EGRESS_BASE_URL=https://health-ingest.deansdomain.com \
///   HEALTH_EGRESS_TOKEN=… swift test --filter HealthEgressIntegrationTests
final class HealthEgressIntegrationTests: XCTestCase {
    /// Stands in for the HealthKit read (HKHealthStore needs a real device/Health app); the
    /// upload half below is NOT faked — that is the point of this test.
    private final class CannedReader: HealthEgressReading, @unchecked Sendable {
        let result: HealthEgressReadResult
        init(_ result: HealthEgressReadResult) { self.result = result }
        func readSamples(previousAnchor: String?) async throws -> HealthEgressReadResult { result }
    }

    func testRealBatchAcceptedByLiveCollector() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HEALTH_EGRESS_INTEGRATION"] == "1" else {
            throw XCTSkip("live collector test — set HEALTH_EGRESS_INTEGRATION=1, "
                          + "HEALTH_EGRESS_BASE_URL and HEALTH_EGRESS_TOKEN to run")
        }
        let base = try XCTUnwrap(env["HEALTH_EGRESS_BASE_URL"], "HEALTH_EGRESS_BASE_URL missing")
        let token = try XCTUnwrap(env["HEALTH_EGRESS_TOKEN"], "HEALTH_EGRESS_TOKEN missing")

        let suite = "HealthEgressIntegrationTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(base, forKey: HealthEgressConfig.baseURLOverrideKey)
        let tokenStore = HealthEgressDefaultsTokenStore(defaults: defaults)
        tokenStore.save(token: token)

        // Marker makes this exact batch findable in the collector log and in ClickHouse.
        let marker = "it-\(UUID().uuidString.prefix(13)).opencircuit"
        let now = Date(timeIntervalSince1970: 1_761_700_000) // fixed: 2025-10-29T00:13:20Z
        func iso(_ offset: TimeInterval) -> String {
            HealthEgressBatchBuilder.iso8601UTC(now.addingTimeInterval(offset))
        }
        func sample(_ uuid: String, _ type: String, _ unit: String, _ value: Double,
                    _ valueStr: String) -> EgressSample {
            EgressSample(ts: iso(0), tsEnd: iso(60), type: type, unit: unit, value: value,
                         valueStr: valueStr, sourceBundleId: "com.deansdomain.ringpool",
                         sourceName: "Ringpool \(marker)", deviceId: "iPhone17,2",
                         osVersion: "26.5", version: "0-integration", uuid: uuid)
        }
        let samples = [
            sample(UUID().uuidString, "HKQuantityTypeIdentifierHeartRate", "count/min", 62, ""),
            sample(UUID().uuidString, "HKCategoryTypeIdentifierSleepAnalysis", "category", 4, "asleepCore"),
            sample(UUID().uuidString, "HKWorkoutTypeIdentifier", "min", 41.5, "type52"),
        ]
        let reader = CannedReader(HealthEgressReadResult(samples: samples,
                                                         newAnchor: "anchor-\(marker)"))
        let coordinator = HealthEgressCoordinator(reader: reader,
                                                  tokenStore: tokenStore,
                                                  defaults: defaults)

        let outcome = await coordinator.syncNow()
        guard case let .sent(count) = outcome else {
            let storedError = defaults.string(forKey: HealthEgressAnchorStore.lastErrorKey) ?? "none"
            return XCTFail("live collector rejected the batch (outcome \(outcome), error: \(storedError))")
        }
        XCTAssertEqual(count, 3)
        // The anchor advanced ONLY because the live POST returned 2xx (the same rule the
        // fake-session tests pin — here against the real server).
        XCTAssertEqual(defaults.string(forKey: HealthEgressAnchorStore.anchorKey), "anchor-\(marker)")
        XCTAssertNil(defaults.string(forKey: HealthEgressAnchorStore.lastErrorKey))
        XCTAssertEqual(defaults.object(forKey: HealthEgressAnchorStore.samplesSentKey) as? Int, 3)

        defaults.removePersistentDomain(forName: suite)
    }
}
