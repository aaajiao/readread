import XCTest

@testable import ReadRead

/// The audio cache behind instant Next/Previous (R1-03, R4-04).
@MainActor
final class SynthesisCacheTests: XCTestCase {
    private func key(_ unit: Int, voice: String = "zf_001", speed: Double = 1.0, engine: String = "kokoro") -> SynthesisKey {
        SynthesisKey(unit: unit, voiceID: voice, speed: speed, engineID: engine)
    }

    private func result(_ duration: Double) -> SynthesisResult { FakeSynthesizer.result(duration: duration) }

    func testTheLeastRecentlyUsedEntryGoesFirst() {
        let cache = SynthesisCache(capacity: 3)
        for unit in 0..<3 { cache.insert(result(Double(unit)), for: key(unit)) }
        XCTAssertNotNil(cache.result(for: key(0)), "unit 0 is used again")
        cache.insert(result(3), for: key(3))
        XCTAssertEqual(cache.count, 3)
        XCTAssertFalse(cache.contains(key(1)), "unit 1 was the least recently used")
        XCTAssertTrue(cache.contains(key(0)))
        XCTAssertTrue(cache.contains(key(3)))
        XCTAssertEqual(SynthesisCache(capacity: 0).capacity, 1)
    }

    func testReinsertingReplaces() {
        let cache = SynthesisCache(capacity: 2)
        cache.insert(result(1), for: key(0))
        cache.insert(result(2), for: key(0))
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.result(for: key(0))?.duration, 2)
    }

    func testNearestSpeedForTheSameUnitVoiceAndEngine() {
        let cache = SynthesisCache()
        cache.insert(result(1), for: key(0, speed: 1.0))
        cache.insert(result(2), for: key(0, speed: 1.5))
        cache.insert(result(3), for: key(0, voice: "zm_009", speed: 1.2))
        cache.insert(result(4), for: key(0, speed: 1.2, engine: "apple"))
        XCTAssertEqual(cache.nearest(unit: 0, voiceID: "zf_001", engineID: "kokoro", speed: 1.3)?.key.speed, 1.5)
        XCTAssertEqual(cache.nearest(unit: 0, voiceID: "zf_001", engineID: "kokoro", speed: 1.1)?.key.speed, 1.0)
        XCTAssertNil(cache.nearest(unit: 1, voiceID: "zf_001", engineID: "kokoro", speed: 1.0))
        XCTAssertNil(cache.nearest(unit: 0, voiceID: "af_heart", engineID: "kokoro", speed: 1.0))
    }

    func testRemoving() {
        let cache = SynthesisCache()
        cache.insert(result(1), for: key(0))
        cache.insert(result(1), for: key(1, voice: "zm_009"))
        cache.insert(result(1), for: key(2))
        cache.removeAll { $0.voiceID == "zf_001" }
        XCTAssertEqual(cache.keys, [key(1, voice: "zm_009")])
        cache.remove(key(1, voice: "zm_009"))
        XCTAssertEqual(cache.count, 0)
        cache.insert(result(1), for: key(3))
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }
}
