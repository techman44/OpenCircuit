import Foundation
import HealthEgress

/// App-side glue for the Apple Health EGRESS module (collector: `https://health-ingest.deansdomain.com`).
///
/// One entry point per trigger, none of which block the UI: every call fires the whole
/// read→build→POST→commit-anchor flow inside a detached `Task` and returns. The flow itself is
/// best-effort — a failure only lands in the Settings status line and (crucially) does NOT
/// advance the stored anchor, so nothing is ever lost, just re-offered on the next run.
@MainActor
enum HealthEgressBridge {
    static let tokenStore = HealthEgressKeychainTokenStore()
    private static var syncing = false

    /// Consumes `ringpool://set?token=…` (from `.onOpenURL`): stores the bearer token in the
    /// Keychain and kicks one upload, so a freshly provisioned user's backlog starts moving.
    /// Returns false for every other link, so the existing `opencircuit://` hosts are untouched.
    @discardableResult
    static func consumeToken(from url: URL) -> Bool {
        guard let token = HealthEgressDeepLink.token(from: url) else { return false }
        tokenStore.save(token: token)
        syncAfterRingSync()
        return true
    }

    /// Fire-and-forget egress sync. Call sites: the ring sync-completion handler (foreground),
    /// the BGTask background sync, and token (re)provisioning. Gated on config so a user who
    /// never set a token never pays a HealthKit read.
    static func syncAfterRingSync() {
        guard !syncing, HealthEgressConfig.current(tokenStore: tokenStore) != nil else { return }
        syncing = true
        let reader = HealthKitEgressReader()
        let coordinator = HealthEgressCoordinator(reader: reader, tokenStore: tokenStore)
        Task {
            await coordinator.syncNow()
            MainActor.assumeIsolated { syncing = false }
        }
    }

    /// The one-line Settings status: last sync, samples sent, last error. Nil until egress
    /// has ever run, so the row hides itself on a fresh install.
    static var statusLine: String? {
        HealthEgressAnchorStore.statusLine()
    }
}
