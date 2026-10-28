import XCTest
@testable import HealthEgress

/// Pins the collector's batch contract: the exact envelope keys, the exact per-sample keys
/// (snake_case, verbatim), ISO8601 UTC timestamps, and the `raw_samples` verbatim copy.
final class HealthEgressBatchBuilderTests: XCTestCase {
    private func sample(uuid: String, type: String = "HKQuantityTypeIdentifierHeartRate",
                        value: Double = 61, valueStr: String = "") -> EgressSample {
        EgressSample(ts: "2026-10-29T00:00:00Z", tsEnd: "2026-10-29T00:00:00Z",
                     type: type, unit: "count/min", value: value, valueStr: valueStr,
                     sourceBundleId: "com.deansdomain.ringpool", sourceName: "Ringpool",
                     deviceId: "Watch6,7", osVersion: "26.5", version: "1.0", uuid: uuid)
    }

    func testEnvelopeMatchesContractExactly() throws {
        let data = try HealthEgressBatchBuilder.build(
            uploadId: "UPLOAD-1", appVersion: "1.0", device: "iPhone17,2",
            anchor: "ANCHOR-9", samples: [sample(uuid: "UUID-1")])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["upload_id", "app_version", "device", "anchor", "samples", "raw_samples"])
        XCTAssertEqual(obj["upload_id"] as? String, "UPLOAD-1")
        XCTAssertEqual(obj["app_version"] as? String, "1.0")
        XCTAssertEqual(obj["device"] as? String, "iPhone17,2")
        XCTAssertEqual(obj["anchor"] as? String, "ANCHOR-9")
        let samples = try XCTUnwrap(obj["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(Set(samples[0].keys), [
            "ts", "ts_end", "type", "unit", "value", "value_str",
            "source_bundle_id", "source_name", "device_id", "os_version", "version", "uuid",
        ])
        XCTAssertEqual(samples[0]["source_bundle_id"] as? String, "com.deansdomain.ringpool")
        XCTAssertEqual(samples[0]["device_id"] as? String, "Watch6,7")
        XCTAssertEqual(samples[0]["uuid"] as? String, "UUID-1")
        XCTAssertEqual(samples[0]["value"] as? Double, 61)
    }

    func testRawSamplesAreAVerbatimCopyOfTheSampleDicts() throws {
        let data = try HealthEgressBatchBuilder.build(
            uploadId: "U", appVersion: "1", device: "d", anchor: "",
            samples: [sample(uuid: "A"), sample(uuid: "B", type: "HKCategoryTypeIdentifierSleepAnalysis", value: 3, valueStr: "asleepDeep")])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let samples = try XCTUnwrap(obj["samples"] as? [[String: Any]])
        let raw = try XCTUnwrap(obj["raw_samples"] as? [[String: Any]])
        XCTAssertEqual(raw.count, samples.count)
        XCTAssertEqual(raw.map { $0["uuid"] as? String }, samples.map { $0["uuid"] as? String })
        XCTAssertEqual(raw.map { ($0["value"] as? Double ?? -1) }, samples.map { $0["value"] as? Double })
        // The anchor field carries the PREVIOUS anchor ("" on the first sync) — advancing it
        // is the uploader's post-2xx job, never the builder's.
        XCTAssertEqual(obj["anchor"] as? String, "")
    }

    func testTimestampsAreISO8601UTC() {
        // 2026-01-02T03:04:05Z
        let date = Date(timeIntervalSince1970: 1767323045)
        XCTAssertEqual(HealthEgressBatchBuilder.iso8601UTC(date), "2026-01-02T03:04:05Z")
    }
}
