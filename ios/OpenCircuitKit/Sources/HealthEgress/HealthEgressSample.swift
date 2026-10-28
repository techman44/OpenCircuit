import Foundation

/// One Apple Health sample rendered for the collector.
///
/// The JSON keys are the collector's contract VERBATIM (snake_case, exactly these fields):
/// `ts, ts_end, type, unit, value, value_str, source_bundle_id, source_name, device_id,
/// os_version, version, uuid`. Timestamps are ISO8601 UTC strings, pre-formatted so the
/// encoding is byte-stable and independent of any JSONEncoder date strategy.
///
/// Provenance (`source_bundle_id`, `source_name`, `device_id`, `os_version`, `version`) comes
/// from `HKObject.sourceRevision` at read time — a sample without it is mush, which is the
/// entire point of the egress feed. `uuid` is the sample's `HKObjectIdentifier`.
public struct EgressSample: Codable, Equatable, Sendable {
    public var ts: String
    /// `"ts_end"`.
    public var tsEnd: String
    /// HealthKit type identifier, e.g. `HKQuantityTypeIdentifierHeartRate`,
    /// `HKCategoryTypeIdentifierSleepAnalysis`, `HKWorkoutTypeIdentifier`.
    public var type: String
    /// The unit the numeric `value` is expressed in (`count/min`, `degC`, `kcal`, `ms`,
    /// `count`, `%`…), or `category` / `min` for non-quantity payloads.
    public var unit: String
    /// Quantity value in `unit`; for categories, the category value's raw value; for workouts,
    /// the duration in minutes.
    public var value: Double
    /// Category payload rendered readable (`asleepCore`, `inBed`, `moderate`…), or the workout's
    /// activity name. Empty for plain quantities.
    public var valueStr: String
    public var sourceBundleId: String
    public var sourceName: String
    /// `HKSourceRevision.productType` (e.g. `Watch6,7` / `iPhone17,2`) when present, else the
    /// recording device's UDID, else the phone the app read it on is NOT assumed — empty.
    public var deviceId: String
    /// The source's OS version, e.g. `26.5` or `10.2.1`.
    public var osVersion: String
    /// The source app's version string that produced the sample.
    public var version: String
    /// The sample's `HKObjectIdentifier` UUID string.
    public var uuid: String

    private enum CodingKeys: String, CodingKey {
        case ts
        case tsEnd = "ts_end"
        case type, unit, value
        case valueStr = "value_str"
        case sourceBundleId = "source_bundle_id"
        case sourceName = "source_name"
        case deviceId = "device_id"
        case osVersion = "os_version"
        case version
        case uuid
    }

    public init(ts: String, tsEnd: String, type: String, unit: String, value: Double,
                valueStr: String, sourceBundleId: String, sourceName: String, deviceId: String,
                osVersion: String, version: String, uuid: String) {
        self.ts = ts
        self.tsEnd = tsEnd
        self.type = type
        self.unit = unit
        self.value = value
        self.valueStr = valueStr
        self.sourceBundleId = sourceBundleId
        self.sourceName = sourceName
        self.deviceId = deviceId
        self.osVersion = osVersion
        self.version = version
        self.uuid = uuid
    }
}

/// Builds the exact batch envelope the collector expects:
/// `{"upload_id", "app_version", "device", "anchor", "samples": [...]}` — plus `raw_samples`,
/// a verbatim copy of each sample dict so the server can store it unchanged even if a future
/// client reshapes `samples`. The sample dicts in both arrays come from ONE encode pass, so
/// they cannot drift apart.
public enum HealthEgressBatchBuilder {
    /// Fixed ISO8601 UTC seconds formatter (no fractional seconds, always `Z`).
    public static func iso8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// - Parameter anchor: the anchor string the READ was performed from ("" on the first sync).
    ///   The anchor is the query's NEW anchor only once the POST returns 2xx — that rule lives
    ///   in `HealthEgressUploader`, never here.
    public static func build(uploadId: String,
                             appVersion: String,
                             device: String,
                             anchor: String,
                             samples: [EgressSample]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sampleObjects = try samples.map { sample -> [String: Any] in
            let data = try encoder.encode(sample)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HealthEgressError.badSampleEncoding
            }
            return dict
        }
        let envelope: [String: Any] = [
            "upload_id": uploadId,
            "app_version": appVersion,
            "device": device,
            "anchor": anchor,
            "samples": sampleObjects,
            // Verbatim copy of each sample dict (same objects, serialized once more by the
            // top-level encoder below).
            "raw_samples": sampleObjects,
        ]
        guard JSONSerialization.isValidJSONObject(envelope) else { throw HealthEgressError.badSampleEncoding }
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }
}

public enum HealthEgressError: Error, Equatable {
    /// A sample failed to encode, or the token/endpoint is missing entirely.
    case badSampleEncoding
    case notConfigured
    case http(Int)
    case transport(String)
}
