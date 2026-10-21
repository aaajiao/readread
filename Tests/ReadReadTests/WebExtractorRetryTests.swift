import XCTest

@testable import ReadRead

final class WebExtractorRetryTests: XCTestCase {

    // MARK: - Classification

    /// R3-07: 429 (the monthly quota) is never retried, 502 (defuddle.md could not fetch the page) once.
    func testRetryableStatusCodes() {
        XCTAssertFalse(WebExtractor.isRetryable(statusCode: 429))
        XCTAssertTrue(WebExtractor.isRetryable(statusCode: 500))
        XCTAssertTrue(WebExtractor.isRetryable(statusCode: 503))
        XCTAssertTrue(WebExtractor.isRetryable(statusCode: 503, attempt: 2))
        XCTAssertTrue(WebExtractor.isRetryable(statusCode: 502, attempt: 1))
        XCTAssertFalse(WebExtractor.isRetryable(statusCode: 502, attempt: 2))
        XCTAssertFalse(WebExtractor.isRetryable(statusCode: 200))
        XCTAssertFalse(WebExtractor.isRetryable(statusCode: 400))
        XCTAssertFalse(WebExtractor.isRetryable(statusCode: 404))
    }

    func testRequestsTimeOutAfterThirtySeconds() {
        XCTAssertEqual(WebExtractor.requestTimeout, 30)
        XCTAssertEqual(WebExtractor.session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(WebExtractor.session.configuration.timeoutIntervalForResource, 30)
        XCTAssertNil(WebExtractor.session.configuration.urlCache)
    }

    func testRetryableErrors() {
        XCTAssertTrue(WebExtractor.isRetryable(error: URLError(.timedOut)))
        XCTAssertTrue(WebExtractor.isRetryable(error: URLError(.networkConnectionLost)))
        XCTAssertTrue(WebExtractor.isRetryable(error: URLError(.cannotConnectToHost)))
        XCTAssertFalse(WebExtractor.isRetryable(error: URLError(.badURL)))
        XCTAssertFalse(WebExtractor.isRetryable(error: URLError(.unsupportedURL)))
        XCTAssertFalse(WebExtractor.isRetryable(error: WebExtractorError.service("Timed out fetching page after 10s")))
        XCTAssertFalse(WebExtractor.isRetryable(error: WebExtractorError.invalidURL))
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

    /// The quota: one request, its message kept, and the error says what happened.
    func testTheQuotaIsNeverRetried() async throws {
        let counter = CallCounter()
        do {
            _ = try await WebExtractor.fetchWithRetry(from: testURL, sleep: { _ in }, fetch: { u in
                await counter.increment()
                return (Data(#"{"error":"Monthly limit of 1000 requests reached"}"#.utf8), response(u, 429))
            })
            XCTFail("expected the quota error")
        } catch {
            XCTAssertEqual(error as? WebExtractorError, .quotaExceeded("Monthly limit of 1000 requests reached"))
            XCTAssertTrue((error as? WebExtractorError)?.errorDescription?.contains("1,000 pages a month") ?? false)
        }
        let calls = await counter.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(WebExtractor.failure(status: 429, body: Data()), .quotaExceeded(nil))
    }

    func testA502IsRetriedOnce() async throws {
        let counter = CallCounter()
        let sleeps = DurationLog()
        do {
            _ = try await WebExtractor.fetchWithRetry(from: testURL, sleep: { await sleeps.add($0) }, fetch: { u in
                await counter.increment()
                return (Data(#"{"error":"Failed to fetch https://example.com: 403"}"#.utf8), response(u, 502))
            })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? WebExtractorError, .serviceStatus(502, "Failed to fetch https://example.com: 403"))
        }
        let calls = await counter.value
        XCTAssertEqual(calls, 2, "one retry for a 502, not two")
        let slept = await sleeps.values
        XCTAssertEqual(slept, [.milliseconds(500)])
    }

    /// The service's own words survive a failed status (R3-07); an HTML error page does not.
    func testTheErrorTextIsKept() {
        XCTAssertEqual(WebExtractor.failure(status: 404, body: Data(#"{"error":"Page not found"}"#.utf8)),
                       .serviceStatus(404, "Page not found"))
        XCTAssertEqual(WebExtractor.failure(status: 403, body: Data("Blocked by the site's robots.txt\n".utf8)),
                       .serviceStatus(403, "Blocked by the site's robots.txt"))
        XCTAssertEqual(WebExtractor.failure(status: 500, body: Data("<html><body><h1>500</h1></body></html>".utf8)),
                       .fetchFailed(500))
        XCTAssertEqual(WebExtractor.failure(status: 503, body: Data()), .fetchFailed(503))
        XCTAssertEqual(WebExtractorError.serviceStatus(404, "Page not found").errorDescription,
                       "defuddle.md could not extract the page (HTTP 404): Page not found")
    }

    /// Cancelling during a backoff ends the loop at once.
    func testCancellationStopsTheRetries() async throws {
        let counter = CallCounter()
        let task = Task {
            try await WebExtractor.fetchWithRetry(from: testURL, sleep: { _ in try await Task.sleep(for: .seconds(600)) },
                                                  fetch: { _ in
                                                      await counter.increment()
                                                      throw URLError(.timedOut)
                                                  })
        }
        while await counter.value == 0 { await Task.yield() }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let calls = await counter.value
        XCTAssertEqual(calls, 1)
    }
}

/// Durations an injected sleep was asked for.
private actor DurationLog {
    private(set) var values: [Duration] = []
    func add(_ duration: Duration) { values.append(duration) }
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
