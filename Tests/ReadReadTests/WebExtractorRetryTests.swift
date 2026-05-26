import XCTest

@testable import ReadRead

final class WebExtractorRetryTests: XCTestCase {

    // MARK: - Classification

    func testRetryableStatusCodes() {
        XCTAssertTrue(WebExtractor.isRetryable(statusCode: 429))
        XCTAssertTrue(WebExtractor.isRetryable(statusCode: 500))
        XCTAssertTrue(WebExtractor.isRetryable(statusCode: 503))
        XCTAssertFalse(WebExtractor.isRetryable(statusCode: 200))
        XCTAssertFalse(WebExtractor.isRetryable(statusCode: 400))
        XCTAssertFalse(WebExtractor.isRetryable(statusCode: 404))
    }

    func testRetryableErrors() {
        XCTAssertTrue(WebExtractor.isRetryable(error: URLError(.timedOut)))
        XCTAssertTrue(WebExtractor.isRetryable(error: URLError(.networkConnectionLost)))
        XCTAssertTrue(WebExtractor.isRetryable(error: URLError(.cannotConnectToHost)))
        XCTAssertFalse(WebExtractor.isRetryable(error: URLError(.badURL)))
        XCTAssertFalse(WebExtractor.isRetryable(error: URLError(.unsupportedURL)))
        XCTAssertFalse(WebExtractor.isRetryable(error: WebExtractorError.noContent))
    }

    func testBackoffGrowsExponentially() {
        XCTAssertEqual(WebExtractor.backoff(forAttempt: 1), .milliseconds(500))
        XCTAssertEqual(WebExtractor.backoff(forAttempt: 2), .milliseconds(1000))
        XCTAssertEqual(WebExtractor.backoff(forAttempt: 3), .milliseconds(2000))
    }

    // MARK: - Retry loop

    func testSucceedsOnFirstAttempt() async throws {
        let counter = CallCounter()
        let data = try await WebExtractor.fetchWithRetry(
            from: testURL,
            sleep: { _ in },
            fetch: { u in
                await counter.increment()
                return ok(u)
            }
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "no retry should occur on success")
    }

    func testRetriesTransientErrorThenSucceeds() async throws {
        let counter = CallCounter()
        let data = try await WebExtractor.fetchWithRetry(
            from: testURL,
            sleep: { _ in },
            fetch: { u in
                let n = await counter.increment()
                if n < 3 { throw URLError(.timedOut) }
                return ok(u, "recovered")
            }
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "recovered")
        let calls = await counter.value
        XCTAssertEqual(calls, 3, "should retry twice then succeed on the third attempt")
    }

    func testRetriesRetryableStatusThenSucceeds() async throws {
        let counter = CallCounter()
        let data = try await WebExtractor.fetchWithRetry(
            from: testURL,
            sleep: { _ in },
            fetch: { u in
                let n = await counter.increment()
                if n == 1 { return (Data(), response(u, 503)) }
                return ok(u)
            }
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        let calls = await counter.value
        XCTAssertEqual(calls, 2)
    }

    func testExhaustsRetriesAndThrowsLastError() async throws {
        let counter = CallCounter()
        do {
            _ = try await WebExtractor.fetchWithRetry(
                from: testURL,
                sleep: { _ in },
                fetch: { _ in
                    await counter.increment()
                    throw URLError(.timedOut)
                }
            )
            XCTFail("expected failure after exhausting retries")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        let calls = await counter.value
        XCTAssertEqual(calls, WebExtractor.maxAttempts, "should try exactly maxAttempts times")
    }

    func testNonRetryableErrorFailsImmediately() async throws {
        let counter = CallCounter()
        do {
            _ = try await WebExtractor.fetchWithRetry(
                from: testURL,
                sleep: { _ in },
                fetch: { _ in
                    await counter.increment()
                    throw URLError(.badURL)
                }
            )
            XCTFail("expected immediate failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badURL)
        }
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "non-retryable errors must not retry")
    }

    func testNonRetryableStatusFailsImmediately() async throws {
        let counter = CallCounter()
        do {
            _ = try await WebExtractor.fetchWithRetry(
                from: testURL,
                sleep: { _ in },
                fetch: { u in
                    await counter.increment()
                    return (Data(), response(u, 404))
                }
            )
            XCTFail("expected immediate failure")
        } catch let error as WebExtractorError {
            guard case .fetchFailed(let code) = error else {
                return XCTFail("expected fetchFailed, got \(error)")
            }
            XCTAssertEqual(code, 404)
        }
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "4xx (other than 429) must not retry")
    }
}

// MARK: - Test helpers

private let testURL = URL(string: "https://defuddle.md/example.com")!

private func ok(_ url: URL, _ body: String = "ok") -> (Data, URLResponse) {
    (Data(body.utf8), response(url, 200))
}

private func response(_ url: URL, _ code: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
}

/// Thread-safe call counter for the injectable `fetch` closure.
private actor CallCounter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
