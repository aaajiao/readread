import Foundation

/// Which audio a cache entry holds.
struct SynthesisKey: Hashable, Sendable {
    let unit: Int
    let voiceID: String
    /// The speed it was synthesized at (1.0 for an engine that does not honour speed).
    let speed: Double
    let engineID: String
}

/// Synthesized units, least recently used dropped first (R1-03, R4-04: Next and Previous
/// reuse audio instead of synthesizing it again). About 40 sentences of 24 kHz PCM16 is a
/// few tens of MB.
@MainActor
final class SynthesisCache {
    let capacity: Int
    private var entries: [SynthesisKey: (result: SynthesisResult, lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int = 40) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }
    var keys: [SynthesisKey] { Array(entries.keys) }

    func contains(_ key: SynthesisKey) -> Bool { entries[key] != nil }

    /// The entry for `key`, marked as just used.
    func result(for key: SynthesisKey) -> SynthesisResult? {
        guard let entry = entries[key] else { return nil }
        clock += 1
        entries[key] = (entry.result, clock)
        return entry.result
    }

    /// Any entry for this unit, voice and engine, the one nearest `speed` first: audio at an
    /// older speed plays at once (time-stretched) while the new speed is synthesized.
    func nearest(unit: Int, voiceID: String, engineID: String, speed: Double) -> (key: SynthesisKey, result: SynthesisResult)? {
        let candidates = entries.keys.filter { $0.unit == unit && $0.voiceID == voiceID && $0.engineID == engineID }
        guard let key = candidates.min(by: { abs($0.speed - speed) < abs($1.speed - speed) }),
              let result = result(for: key) else { return nil }
        return (key, result)
    }

    func insert(_ result: SynthesisResult, for key: SynthesisKey) {
        clock += 1
        entries[key] = (result, clock)
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    func remove(_ key: SynthesisKey) {
        entries.removeValue(forKey: key)
    }

    func removeAll(where shouldRemove: (SynthesisKey) -> Bool) {
        for key in entries.keys where shouldRemove(key) { entries.removeValue(forKey: key) }
    }

    func removeAll() {
        entries.removeAll()
    }
}
