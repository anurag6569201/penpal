import Foundation

nonisolated struct InteractiveDomainRequest: Codable, Hashable, Identifiable {
    var host: String
    var reason: String
    var id: String { host }
}

nonisolated struct InteractiveCapabilityRequest: Codable, Hashable, Identifiable {
    var id: String
    var reason: String
}

nonisolated struct InteractiveDependency: Codable, Hashable, Identifiable {
    var url: String
    var kind: String
    var integrity: String?
    var id: String { "\(kind):\(url)" }
}

nonisolated struct InteractiveManifest: Codable, Hashable {
    var version: Int
    var domains: [InteractiveDomainRequest]
    var capabilities: [InteractiveCapabilityRequest]
    var dependencies: [InteractiveDependency]

    static let empty = InteractiveManifest(
        version: 1,
        domains: [],
        capabilities: [],
        dependencies: []
    )
}

nonisolated struct InteractiveRuntimeMetadata: Codable, Hashable {
    var title: String
    var manifest: InteractiveManifest
    var allowedDomains: [String]
    var allowedCapabilities: [String]
    var storageQuotaBytes: Int
    var autoRepairEnabled: Bool?
    var repairAttempts: Int?
    var lastRepairSummary: String?

    init(
        title: String = "Interactive Block",
        manifest: InteractiveManifest = .empty,
        allowedDomains: [String] = [],
        allowedCapabilities: [String] = [],
        storageQuotaBytes: Int = 5 * 1024 * 1024,
        autoRepairEnabled: Bool = true,
        repairAttempts: Int = 0,
        lastRepairSummary: String? = nil
    ) {
        self.title = title
        self.manifest = manifest
        self.allowedDomains = allowedDomains
        self.allowedCapabilities = allowedCapabilities
        self.storageQuotaBytes = storageQuotaBytes
        self.autoRepairEnabled = autoRepairEnabled
        self.repairAttempts = repairAttempts
        self.lastRepairSummary = lastRepairSummary
    }

    var isAutoRepairEnabled: Bool { autoRepairEnabled ?? true }
    var completedRepairAttempts: Int { repairAttempts ?? 0 }
}

nonisolated struct InteractiveRuntimeDiagnostic: Codable, Hashable {
    var kind: String
    var message: String
    var source: String?
    var line: Int?
    var column: Int?
}

nonisolated enum InteractivePermissionTarget: Hashable {
    case domain(host: String, reason: String)
    case capability(id: String, reason: String)

    var key: String {
        switch self {
        case .domain(let host, _): "domain:\(host)"
        case .capability(let id, _): "capability:\(id)"
        }
    }

    var title: String {
        switch self {
        case .domain(let host, _): "Connect to \(host)"
        case .capability(let id, _):
            switch id {
            case "camera": "Use the Camera"
            case "microphone": "Use the Microphone"
            case "location": "Use Your Location"
            case "clipboard.read": "Read the Clipboard"
            case "clipboard.write": "Write to the Clipboard"
            case "files.read": "Choose a File"
            case "files.write": "Export a File"
            case "downloads": "Download a File"
            case "storage.large": "Use More Storage"
            default: "Use \(id)"
            }
        }
    }

    var reason: String {
        switch self {
        case .domain(_, let reason), .capability(_, let reason): reason
        }
    }
}

nonisolated enum InteractivePermissionDecision: Hashable {
    case allowOnce
    case alwaysAllow
    case deny
}

nonisolated struct InteractivePermissionPrompt: Identifiable, Hashable {
    var id = UUID()
    var blockID: UUID
    var blockTitle: String
    var target: InteractivePermissionTarget
}

nonisolated enum InteractiveRuntimePolicy {
    static let supportedCapabilities: Set<String> = [
        "camera", "microphone", "location",
        "clipboard.read", "clipboard.write",
        "files.read", "files.write", "downloads", "storage.large",
    ]

    static func normalizePublicHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              host.contains("."),
              host != "localhost",
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !isPrivateAddress(host) else { return nil }
        return host
    }

    static func normalizedDomains(
        persistent: [String],
        session: Set<String> = []
    ) -> [String] {
        let values = persistent + Array(session)
        return Array(Set(values.compactMap(normalizePublicHost))).sorted()
    }

    static func contentSecurityPolicy(
        persistentDomains: [String],
        sessionDomains: Set<String> = []
    ) -> String {
        let domains = normalizedDomains(
            persistent: persistentDomains,
            session: sessionDomains
        )
        let https = domains.map { "https://\($0)" }.joined(separator: " ")
        let wss = domains.map { "wss://\($0)" }.joined(separator: " ")
        let remote = [https, wss].filter { !$0.isEmpty }.joined(separator: " ")
        let withRemote: (String) -> String = { base in
            remote.isEmpty ? base : "\(base) \(remote)"
        }
        let remoteOrNone = remote.isEmpty ? "'none'" : remote
        return [
            "default-src 'none'",
            "script-src \(withRemote("'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' blob:"))",
            "style-src \(withRemote("'unsafe-inline' blob:"))",
            "connect-src \(withRemote("blob: data:"))",
            "img-src \(withRemote("data: blob:"))",
            "media-src \(withRemote("data: blob:"))",
            "font-src \(withRemote("data: blob:"))",
            "worker-src \(withRemote("blob:"))",
            "frame-src \(remoteOrNone)",
            "form-action \(remoteOrNone)",
            "object-src 'none'",
            "base-uri 'none'",
        ].joined(separator: "; ")
    }

    private static func isPrivateAddress(_ host: String) -> Bool {
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc")
            || host.hasPrefix("fd") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        let a = parts[0], b = parts[1]
        return a == 0 || a == 10 || a == 127 || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
            || a >= 224
    }
}
