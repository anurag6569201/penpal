//
//  HandProfiles.swift
//  penpal
//
//  PEN-20 — several trained hands on one device.
//
//  A shared iPad is the normal case, not the exotic one: a student and a
//  parent, or two siblings. Today the second person to open Penpal trains
//  over the first person's hand, silently degrading it — the bank has no
//  notion of whose writing it holds.
//
//  Five stores are per-hand and must move together, or a profile ends up
//  with one person's letters and another's fragments:
//
//      personal_font.json   ligature_stats.json   style_rl.json
//      ink_fragments.json   stroke_vae.json
//
//  Notes are deliberately NOT per-hand. A shared iPad has shared paper; the
//  hand is *who is writing*, not *whose notebook this is*. Splitting notes
//  as well would make switching profiles feel like switching accounts, which
//  is a much bigger product claim than "write in my handwriting".
//
//  Migration: existing files live at the Documents root. They become the
//  first profile in place — copied, never moved — so a failed migration
//  leaves the original hand untouched and recoverable.
//

import Foundation
// @Published / ObservableObject — Settings observes the profile list.
import Combine

@MainActor
final class HandProfiles: ObservableObject {

    static let shared = HandProfiles()

    struct Profile: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var createdAt: Date

        init(name: String) {
            self.id = UUID()
            self.name = name
            self.createdAt = Date()
        }
    }

    /// Files that belong to a hand. Anything not listed here is shared.
    static let perHandFiles = [
        "personal_font.json",
        "ink_fragments.json",
        "ligature_stats.json",
        "stroke_vae.json",
        "style_rl.json",
    ]

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeID: UUID?

    private let profilesKey = "penpal.hands.profiles"
    private let activeKey = "penpal.hands.active"

    /// `nonisolated` because `fileURL(_:)` is called from the per-hand stores,
    /// which are not MainActor-bound. Reading the Documents directory touches
    /// no shared mutable state, so it is safe off the main actor.
    private nonisolated static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private init() {
        load()
        if profiles.isEmpty { adoptExistingHandAsFirstProfile() }
    }

    var active: Profile? {
        profiles.first { $0.id == activeID } ?? profiles.first
    }

    /// Directory holding the active hand's files. All per-hand stores resolve
    /// their paths through here, so adding a store means adding one line
    /// above rather than remembering five call sites.
    static func directory(for id: UUID?) -> URL {
        guard let id else { return documents }
        let url = documents.appendingPathComponent("Hands/\(id.uuidString)",
                                                   isDirectory: true)
        try? FileManager.default.createDirectory(at: url,
                                                 withIntermediateDirectories: true)
        return url
    }

    /// Resolves a per-hand filename for the CURRENT profile.
    ///
    /// Static and looked up fresh each call so the stores stay stateless with
    /// respect to profiles — they simply ask where their file is now.
    nonisolated static func fileURL(_ name: String) -> URL {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "penpal.hands.active"),
              let id = UUID(uuidString: raw) else {
            return documents.appendingPathComponent(name)
        }
        let dir = documents.appendingPathComponent("Hands/\(id.uuidString)",
                                                   isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    // MARK: - Managing hands

    @discardableResult
    func addProfile(named name: String) -> Profile {
        let profile = Profile(name: name.isEmpty ? "Hand \(profiles.count + 1)" : name)
        profiles.append(profile)
        persist()
        return profile
    }

    /// Switches hands and tells every store to reload from the new directory.
    func activate(_ id: UUID) {
        guard id != activeID, profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        UserDefaults.standard.set(id.uuidString, forKey: activeKey)
        persist()
        NotificationCenter.default.post(name: .handProfileDidChange, object: nil)
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        profiles[index].name = name
        persist()
    }

    /// Removes a hand and its training. Refuses to delete the last one —
    /// there must always be a hand to write in.
    func delete(_ id: UUID) {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let removed = profiles.remove(at: index)
        try? FileManager.default.removeItem(at: Self.directory(for: removed.id))
        if activeID == removed.id, let next = profiles.first {
            activeID = next.id
            UserDefaults.standard.set(next.id.uuidString, forKey: activeKey)
            NotificationCenter.default.post(name: .handProfileDidChange, object: nil)
        }
        persist()
    }

    // MARK: - Persistence & migration

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: activeKey) {
            activeID = UUID(uuidString: raw)
        }
    }

    /// First run with profiles: whatever hand is already trained becomes
    /// profile one, with its files COPIED into place. The originals are left
    /// alone, so a failure here costs nothing.
    private func adoptExistingHandAsFirstProfile() {
        let profile = Profile(name: "My hand")
        profiles = [profile]
        activeID = profile.id
        UserDefaults.standard.set(profile.id.uuidString, forKey: activeKey)

        let destination = Self.directory(for: profile.id)
        let fm = FileManager.default
        for name in Self.perHandFiles {
            let source = Self.documents.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = destination.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.copyItem(at: source, to: target)
            } catch {
                print("Hand migration skipped \(name): \(error)")
            }
        }
        persist()
    }
}

extension Notification.Name {
    /// Per-hand stores reload when this fires.
    static let handProfileDidChange = Notification.Name("penpal.handProfileDidChange")
}
