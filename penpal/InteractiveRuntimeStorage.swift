import Foundation
import WebKit

@MainActor
enum InteractiveRuntimeStorage {
    private static var sessionDomains: [UUID: Set<String>] = [:]
    private static var sessionCapabilities: [UUID: Set<String>] = [:]
    private static var sessionDenials: [UUID: Set<String>] = [:]

    static func dataStore(for blockID: UUID) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: blockID)
    }

    static func allowOnce(_ target: InteractivePermissionTarget, for blockID: UUID) {
        switch target {
        case .domain(let host, _):
            guard let host = InteractiveRuntimePolicy.normalizePublicHost(host) else { return }
            sessionDomains[blockID, default: []].insert(host)
        case .capability(let id, _):
            guard InteractiveRuntimePolicy.supportedCapabilities.contains(id) else { return }
            sessionCapabilities[blockID, default: []].insert(id)
        }
    }

    static func domains(for blockID: UUID) -> Set<String> {
        sessionDomains[blockID] ?? []
    }

    static func capabilities(for blockID: UUID) -> Set<String> {
        sessionCapabilities[blockID] ?? []
    }

    static func deny(_ target: InteractivePermissionTarget, for blockID: UUID) {
        sessionDenials[blockID, default: []].insert(target.key)
    }

    static func revoke(_ target: InteractivePermissionTarget, for blockID: UUID) {
        switch target {
        case .domain(let host, _):
            sessionDomains[blockID]?.remove(host)
        case .capability(let id, _):
            sessionCapabilities[blockID]?.remove(id)
        }
        deny(target, for: blockID)
    }

    static func isDenied(_ target: InteractivePermissionTarget, for blockID: UUID) -> Bool {
        sessionDenials[blockID]?.contains(target.key) == true
    }

    static func clearSession(for blockID: UUID) {
        sessionDomains.removeValue(forKey: blockID)
        sessionCapabilities.removeValue(forKey: blockID)
        sessionDenials.removeValue(forKey: blockID)
    }

    static func clearData(for blockID: UUID) {
        let store = dataStore(for: blockID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) {}
    }

    /// WebKit refuses deletion while a view still owns the store. Scheduling
    /// after the current UI turn lets block views release before cleanup.
    static func remove(blockIDs: [UUID]) {
        guard !blockIDs.isEmpty else { return }
        for id in blockIDs { clearSession(for: id) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            for id in blockIDs {
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: id)
                } catch {
                    // Cleanup is best-effort; WebKit may still be releasing a
                    // terminated content process. A later reset can retry.
                }
            }
        }
    }
}
