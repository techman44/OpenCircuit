#if canImport(HealthKit)
import Foundation
import HealthKit

/// The HealthKit READ side of the egress feed. Requests READ for every quantity and category
/// type named in `docs/HEALTHKIT_MAPPING.md` (plus Recovery HRV where the OS has the type),
/// `sleepAnalysis` and workouts, reads them with `HKAnchoredObjectQuery`, and renders each
/// sample with its full `sourceRevision` provenance.
///
/// API notes (checked against the shipped HealthKit headers, not assumed): samples identify
/// themselves via `HKObject.UUID`; the recording device is `HKObject.device?.udidDeviceIdentifier`
/// or `sourceRevision.productType`; the HRV unit is `.secondUnit(with: .milli)` — the same units
/// the app's own `HealthKitWriter` writes, so the batch renders exactly what is stored.
@available(macOS 13.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
public final class HealthKitEgressReader: HealthEgressReading, @unchecked Sendable {
    /// The READ set: every type the mapping doc names for metrics the ring/strap produces,
    /// the doc's user-entered categories, sleep stages and workouts. Deliberately READ-ONLY —
    /// this module never writes to Health (the existing HealthKitWriter owns writes).
    public static func readTypes() -> Set<HKSampleType> {
        var types = Set<HKSampleType>()
        for id in quantityIdentifiers {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKCategoryType(.menstrualFlow))
        types.insert(HKCategoryType(.headache))
        types.insert(HKWorkoutType.workoutType())
        // Recovery HRV (decision 59): resolved by raw identifier, never by the iOS-27-only
        // Swift symbol, and dropped where the OS has no type — exactly like HealthKitWriter.
        if let recoveryHRV = HKObjectType.quantityType(
            forIdentifier: HKQuantityTypeIdentifier(rawValue: "HeartRateVariabilityRMSSD")) {
            types.insert(recoveryHRV)
        }
        return types
    }

    static let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
        .oxygenSaturation, .bodyTemperature, .respiratoryRate,
        .stepCount, .activeEnergyBurned, .basalEnergyBurned, .heartRateRecoveryOneMinute,
    ]

    /// Units the batch's `value` is rendered in — the writer's own units, so what goes up is
    /// what this app (or any writer) saved.
    static func unit(for id: HKQuantityTypeIdentifier) -> HKUnit {
        switch id {
        case .heartRate, .restingHeartRate, .respiratoryRate, .heartRateRecoveryOneMinute:
            return .count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN: return .secondUnit(with: .milli)
        case .oxygenSaturation: return .percent()
        case .bodyTemperature: return .degreeCelsius()
        case .stepCount: return .count()
        case .activeEnergyBurned, .basalEnergyBurned: return .kilocalorie()
        default: return .count()
        }
    }

    static func unitSymbol(_ unit: HKUnit) -> String {
        unit == .count().unitDivided(by: .minute()) ? "count/min" : unit.description
    }

    /// The first run reads at most this far back (later runs are anchored, where the predicate
    /// is ignored by HealthKit anyway). Bounded so egress can never dump a decade of HR.
    public static let firstRunLookbackDays = 30
    static let perTypeLimit = 500
    static let authRequestedKey = "ringpool.egress.authRequested"

    private let store: HKHealthStore
    private let defaults: UserDefaults

    public init(store: HKHealthStore = HKHealthStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    public func readSamples(previousAnchor: String?) async throws -> HealthEgressReadResult {
        guard HKHealthStore.isHealthDataAvailable() else {
            return HealthEgressReadResult(samples: [], newAnchor: previousAnchor ?? "")
        }
        // The ONE authorization prompt for the read set (first egress run only, so a background
        // sync can't re-surface the sheet after a partial grant).
        if defaults.object(forKey: Self.authRequestedKey) == nil {
            try? await store.requestAuthorization(toShare: [], read: Set<HKObjectType>(Self.readTypes()))
            defaults.set(true, forKey: Self.authRequestedKey)
        }
        var anchors = Self.decodeAnchors(previousAnchor)
        var samples: [EgressSample] = []
        for type in Self.readTypes().sorted(by: { $0.identifier < $1.identifier }) {
            guard let (typeSamples, newAnchor) = try? await query(type: type, previous: anchors[type.identifier]) else { continue }
            samples.append(contentsOf: typeSamples)
            if let newAnchor { anchors[type.identifier] = newAnchor }
        }
        return HealthEgressReadResult(samples: samples, newAnchor: Self.encodeAnchors(anchors))
    }

    // MARK: - Per-type anchored query

    private func query(type: HKSampleType, previous base64Anchor: String?)
        async throws -> ([EgressSample], String?) {
        let anchor = base64Anchor.flatMap(Self.decodeAnchor)
        // Anchored deltas ignore the predicate; bound the FIRST fetch only.
        let predicate: NSPredicate? = anchor == nil
            ? HKQuery.predicateForSamples(withStart: Date(timeIntervalSinceNow: -86400 * Double(Self.firstRunLookbackDays)),
                                          end: nil, options: [])
            : nil
        // Results can be delivered more than once before `stop` lands — the once-box keeps
        // the continuation from being resumed twice (which would crash). Deletes are ignored
        // (append-only feed).
        let once = OnceBox()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([EgressSample], String?), Error>) in
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate,
                                              anchor: anchor, limit: Self.perTypeLimit) { [weak self]
                runningQuery, samples, _, newAnchor, error in
                guard let self, once.enter() else { return }
                self.store.stop(runningQuery)
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let rendered = (samples ?? []).compactMap { self.render($0, type: type) }
                continuation.resume(returning: (rendered, newAnchor.map(Self.encodeAnchor)))
            }
            store.execute(query)
        }
    }

    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = false
        func enter() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if seen { return false }
            seen = true
            return true
        }
    }

    // MARK: - Sample → provenance-rich dict

    private func render(_ sample: HKSample, type: HKSampleType) -> EgressSample? {
        let revision = sample.sourceRevision
        // productType (`Watch6,7`) when the source names a device model, else the device's
        // UDI device identifier (the FDA GUDID field on `HKDevice`). Provenance is the point of
        // the feed — never guessed, never defaulted.
        let deviceId = revision.productType ?? sample.device?.udiDeviceIdentifier ?? ""
        let os = revision.operatingSystemVersion
        let osString = os.minorVersion == 0 && os.patchVersion == 0
            ? "\(os.majorVersion)" : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        var value = 0.0
        var valueStr = ""
        var unitString = "category"
        if let quantity = sample as? HKQuantitySample, type is HKQuantityType {
            let unit = Self.unit(for: HKQuantityTypeIdentifier(rawValue: type.identifier))
            value = quantity.quantity.doubleValue(for: unit)
            unitString = Self.unitSymbol(unit)
        } else if let category = sample as? HKCategorySample {
            value = Double(category.value)
            valueStr = Self.categoryLabel(type: type, value: category.value)
        } else if let workout = sample as? HKWorkout {
            value = workout.duration / 60
            // `HKWorkout` carries no name string in this SDK — the activity type's numeric
            // identifier is the honest label.
            valueStr = "type\(workout.workoutActivityType.rawValue)"
            unitString = "min"
        } else {
            return nil
        }
        return EgressSample(
            ts: HealthEgressBatchBuilder.iso8601UTC(sample.startDate),
            tsEnd: HealthEgressBatchBuilder.iso8601UTC(sample.endDate),
            type: type.identifier,
            unit: unitString,
            value: value,
            valueStr: valueStr,
            sourceBundleId: revision.source.bundleIdentifier,
            sourceName: revision.source.name,
            deviceId: deviceId,
            osVersion: osString,
            version: revision.version ?? "",
            uuid: sample.uuid.uuidString)
    }

    static func categoryLabel(type: HKSampleType, value: Int) -> String {
        switch type.identifier {
        case HKCategoryTypeIdentifier.sleepAnalysis.rawValue:
            if let v = HKCategoryValueSleepAnalysis(rawValue: value) {
                switch v {
                case .inBed: return "inBed"
                case .asleepUnspecified: return "asleepUnspecified"
                case .asleepCore: return "asleepCore"
                case .asleepDeep: return "asleepDeep"
                case .asleepREM: return "asleepREM"
                case .awake: return "awake"
                @unknown default: return "value\(value)"
                }
            }
        case HKCategoryTypeIdentifier.headache.rawValue:
            if let v = HKCategoryValueSeverity(rawValue: value) {
                switch v {
                case .unspecified: return "unspecified"
                case .notPresent: return "notPresent"
                case .mild: return "mild"
                case .moderate: return "moderate"
                case .severe: return "severe"
                @unknown default: return "value\(value)"
                }
            }
        case HKCategoryTypeIdentifier.menstrualFlow.rawValue:
            // Raw int map: the Swift enum's case names are not stable across SDKs (`.spotting`
            // does not exist in this one). The doc's table: 0 unspecified, 1 light, 2 medium,
            // 3 heavy, 4 spotting, 5 none.
            switch value {
            case 0: return "unspecified"
            case 1: return "light"
            case 2: return "medium"
            case 3: return "heavy"
            case 4: return "spotting"
            case 5: return "none"
            default: return "value\(value)"
            }
        default: break
        }
        return "value\(value)"
    }

    // MARK: - Anchor serialization (HKQueryAnchor is NSSecureCoding; the aggregate is a
    //          base64(JSON [typeIdentifier: base64Anchor]) string so the batch carries ONE anchor)

    static func encodeAnchor(_ anchor: HKQueryAnchor) -> String {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        return data?.base64EncodedString() ?? ""
    }

    static func decodeAnchor(_ base64: String) -> HKQueryAnchor? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    static func encodeAnchors(_ map: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]) else { return "" }
        return data.base64EncodedString()
    }

    static func decodeAnchors(_ aggregate: String?) -> [String: String] {
        guard let aggregate, let data = Data(base64Encoded: aggregate),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return map
    }
}
#endif
