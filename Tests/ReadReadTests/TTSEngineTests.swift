import XCTest

@testable import ReadRead

@MainActor
final class TTSEngineTests: XCTestCase {

    // MARK: - TTSError.errorDescription

    func testErrorDescriptionPythonNotFound() {
        let error = TTSError.pythonNotFound
        XCTAssertNotNil(error.errorDescription)
    }

    func testErrorDescriptionModelNotFound() {
        let error = TTSError.modelNotFound
        XCTAssertNotNil(error.errorDescription)
    }

    func testErrorDescriptionScriptNotFound() {
        let error = TTSError.scriptNotFound
        XCTAssertNotNil(error.errorDescription)
    }

    func testErrorDescriptionServerStartFailed() {
        let msg = "boom"
        let error = TTSError.serverStartFailed(msg)
        let desc = error.errorDescription
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc?.contains(msg) == true, "description should contain the message '\(msg)'")
    }

    func testErrorDescriptionServerNotReady() {
        let error = TTSError.serverNotReady
        XCTAssertNotNil(error.errorDescription)
    }

    func testErrorDescriptionSynthesizeFailed() {
        let msg = "oops"
        let error = TTSError.synthesizeFailed(msg)
        let desc = error.errorDescription
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc?.contains(msg) == true, "description should contain the message '\(msg)'")
    }

    // MARK: - isReady on fresh engine

    func testIsReadyFalseOnFreshEngine() {
        let engine = TTSEngine()
        XCTAssertFalse(engine.isReady, "a newly created TTSEngine should not be ready")
    }

    // MARK: - synthesize throws serverNotReady when no server started

    func testSynthesizeThrowsServerNotReadyWhenNoServer() async throws {
        let engine = TTSEngine()
        do {
            _ = try await engine.synthesize(text: "hello", voice: "af_heart", speed: 1.0, lang: "en-us")
            XCTFail("expected TTSError.serverNotReady to be thrown")
        } catch let ttsError as TTSError {
            guard case .serverNotReady = ttsError else {
                XCTFail("expected .serverNotReady, got \(ttsError)")
                return
            }
        } catch {
            XCTFail("expected TTSError, got \(error)")
        }
    }

    // MARK: - resolve(bundle:fallback:extra:)

    func testResolveFallsBackToExpandedFallbackWhenNothingExists() {
        let engine = TTSEngine()
        let fallback = "~/.readread/definitely-missing-xyz"
        let result = engine.resolve(bundle: "nonexistent-bundle-resource-xyz", fallback: fallback)
        let expected = NSString(string: fallback).expandingTildeInPath
        XCTAssertEqual(result, expected)
        XCTAssertFalse(result.contains("~"), "tilde should be expanded in the returned path")
    }

    func testResolveReturnsExtraWhenExtraExists() throws {
        let engine = TTSEngine()

        // Create a real temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("readread-test-resolve-\(UUID().uuidString).tmp")
        try Data().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = engine.resolve(
            bundle: "nonexistent-bundle-resource-xyz",
            fallback: "~/.readread/definitely-missing-xyz",
            extra: tempFile.path
        )
        XCTAssertEqual(result, tempFile.path, "resolve should return the extra path when it exists")
    }

    // MARK: - resolveDir(bundle:fallback:)

    func testResolveDirReturnsTildeExpandedFallbackWhenBundleAbsent() {
        let engine = TTSEngine()
        let fallback = "~/.readread/no-such-dir-xyz"
        let result = engine.resolveDir(bundle: "nonexistent-dir-resource-xyz", fallback: fallback)
        let expected = NSString(string: fallback).expandingTildeInPath
        XCTAssertEqual(result, expected)
        XCTAssertFalse(result.contains("~"), "tilde should be expanded in the returned path")
    }
}
