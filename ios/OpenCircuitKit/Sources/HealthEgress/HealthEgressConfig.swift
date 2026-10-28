import Foundation
#if canImport(Security)
import Security
#endif

/// Everything the egress module needs that a user (or the collector operator) can set.
///
/// The base URL is fixed to the collector with ONE escape hatch for testing
/// (`UserDefaults` key `ringpool.egress.baseURL`) — deliberately not a Settings field, per
/// "no new screens". The bearer token lives in the Keychain (same house pattern as
/// `HelioKeyStore`: generic password, after-first-unlock, this-device-only, so a background
/// BGTask run can read it), supplied by the `ringpool://set?token=…` deep link or the
/// fallback field in Profile ▸ Settings.
public struct HealthEgressConfig: Sendable {
    public static let defaultBaseURL = "https://health-ingest.deansdomain.com"
    public static let baseURLOverrideKey = "ringpool.egress.baseURL"

    public var baseURL: String
    public var token: String
    /// `CFBundleShortVersionString` of the app doing the upload.
    public var appVersion: String
    /// Hardware identifier of the phone (e.g. `iPhone17,2`) — the batch-level `device`.
    public var device: String

    public init(baseURL: String, token: String, appVersion: String, device: String) {
        self.baseURL = baseURL
        self.token = token
        self.appVersion = appVersion
        self.device = device
    }

    /// Production config: endpoint from defaults (+ override key), token from the store.
    public static func current(defaults: UserDefaults = .standard,
                               tokenStore: any HealthEgressTokenPersisting = HealthEgressKeychainTokenStore()) -> HealthEgressConfig? {
        guard let token = tokenStore.load(), !token.isEmpty else { return nil }
        let base = defaults.string(forKey: baseURLOverrideKey)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? defaultBaseURL
        return HealthEgressConfig(baseURL: base, token: token,
                                  appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                                  device: Self.deviceModelIdentifier())
    }

    /// The machine identifier (`iPhone17,2`) via `uname`, no UIKit needed.
    public static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Where the bearer token lives. Split from the Keychain so tests (and any future store)
/// inject a fake without touching `Security`.
public protocol HealthEgressTokenPersisting: Sendable {
    func load() -> String?
    func save(token: String)
    func clear()
}

/// Keychain-backed token store (generic password), mirroring `HelioKeyStore`'s accessibility
/// choice: readable after first unlock on this device only, never in a backup.
public struct HealthEgressKeychainTokenStore: HealthEgressTokenPersisting {
    public static let service = "com.deansdomain.ringpool.health-egress.token"
    private static let account = "egress"

    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    public func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    public func save(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// UserDefaults-backed token store — the store the codebase already uses for every other
/// simple preference; also what the unit tests inject.
public struct HealthEgressDefaultsTokenStore: HealthEgressTokenPersisting, @unchecked Sendable { // UserDefaults is thread-safe
    public static let key = "ringpool.egress.token"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> String? {
        let text = defaults.string(forKey: Self.key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
    public func save(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(trimmed, forKey: Self.key) }
    }
    public func clear() { defaults.removeObject(forKey: Self.key) }
}

/// Parser for the app's token deep link: `ringpool://set?token=…`.
/// Pure so it is unit-testable without UIKit; the app calls it from `.onOpenURL`.
public enum HealthEgressDeepLink {
    public static let scheme = "ringpool"

    /// Returns the token when `url` is `ringpool://set?token=…` with a non-empty token,
    /// nil for every other link (so existing `opencircuit://` handlers still see them).
    public static func token(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "set",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "token" })?.value,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return token
    }
}
