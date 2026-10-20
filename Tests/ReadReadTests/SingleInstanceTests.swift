import XCTest

@testable import ReadRead

final class SingleInstanceTests: XCTestCase {
    private let id = "com.aaajiao.readread"

    func testAnotherInstanceWithTheSameBundleIDIsFound() {
        let running = [
            SingleInstance.RunningApp(pid: 10, bundleID: "com.other.app"),
            SingleInstance.RunningApp(pid: 20, bundleID: id),
            SingleInstance.RunningApp(pid: 30, bundleID: id),
        ]
        XCTAssertEqual(SingleInstance.otherInstance(bundleID: id, ownPID: 30, isSelfTest: false, running: running), 20)
    }

    func testOnlyOurselvesMeansKeepRunning() {
        let running = [SingleInstance.RunningApp(pid: 30, bundleID: id)]
        XCTAssertNil(SingleInstance.otherInstance(bundleID: id, ownPID: 30, isSelfTest: false, running: running))
    }

    func testSkippedWithoutABundleIDOrInSelfTest() {
        let running = [SingleInstance.RunningApp(pid: 20, bundleID: id)]
        XCTAssertNil(SingleInstance.otherInstance(bundleID: nil, ownPID: 30, isSelfTest: false, running: running))
        XCTAssertNil(SingleInstance.otherInstance(bundleID: "", ownPID: 30, isSelfTest: false, running: running))
        XCTAssertNil(SingleInstance.otherInstance(bundleID: id, ownPID: 30, isSelfTest: true, running: running))
    }
}
