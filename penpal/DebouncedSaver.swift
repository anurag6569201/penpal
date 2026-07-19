//
//  DebouncedSaver.swift
//  penpal
//
//  Coalesces rapid store mutations into one background disk write.
//  Previously every saved training sample JSON-encoded its entire store on
//  the main thread (font + fragments + VAE + RL = four full writes per
//  sample), which is what made calibration stutter.
//
//  Usage: capture a value-type snapshot of the payload on the caller's
//  thread, then hand the encode+write closure to `schedule`. Snapshots are
//  copy-on-write so the capture is cheap; the expensive encode runs on a
//  shared utility queue after a short quiet period.
//

import Foundation

// nonisolated: writes run on a background queue by design — this must not
// inherit the project's default MainActor isolation.
nonisolated final class DebouncedSaver {

    /// One serial queue for all stores — writes never contend with the UI.
    private static let queue = DispatchQueue(label: "penpal.disk-writer", qos: .utility)

    private var pending: DispatchWorkItem?
    private let delay: TimeInterval

    init(delay: TimeInterval = 0.8) {
        self.delay = delay
    }

    /// Replaces any not-yet-run write with this one.
    /// The closure must only capture value-type snapshots (thread safety).
    func schedule(_ work: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: work)
        pending = item
        Self.queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Drops a not-yet-run write. Use before an out-of-band replace (import)
    /// so a stale snapshot cannot overwrite the new file a moment later.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Encode-and-write helper for the common Codable-snapshot case.
    static func write<T: Codable>(_ snapshot: T, to url: URL, label: String) {
        do {
            let encoded = try JSONEncoder().encode(snapshot)
            try encoded.write(to: url, options: .atomic)
        } catch {
            print("\(label) save failed: \(error)")
        }
    }
}
