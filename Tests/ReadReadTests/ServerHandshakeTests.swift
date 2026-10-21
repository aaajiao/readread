import XCTest

@testable import ReadRead

final class ServerHandshakeTests: XCTestCase {

    // MARK: - READY

    func testParsesReadyLine() {
        let message = ServerHandshake.parse(line: #"READY {"port":51234,"pid":4321,"api":2,"loaded":["zh","en"]}"#)
        XCTAssertEqual(message, .ready(ReadyInfo(port: 51234, pid: 4321, api: 2, loaded: ["zh", "en"])))
    }

    func testReadyWithoutLoadedListDefaultsToEmpty() {
        let message = ServerHandshake.parse(line: #"READY {"port":1,"pid":2,"api":2}"#)
        XCTAssertEqual(message, .ready(ReadyInfo(port: 1, pid: 2, api: 2, loaded: [])))
    }

    func testReadyToleratesSurroundingWhitespaceAndCR() {
        let message = ServerHandshake.parse(line: "  READY {\"port\":9,\"pid\":1,\"api\":2,\"loaded\":[]}\r")
        XCTAssertEqual(message, .ready(ReadyInfo(port: 9, pid: 1, api: 2, loaded: [])))
    }

    func testMalformedReadyIsInvalidNotJunk() {
        guard case .invalidReady(let why) = ServerHandshake.parse(line: "READY {port: 1}") else {
            return XCTFail("expected invalidReady")
        }
        XCTAssertTrue(why.contains("malformed"))
    }

    func testReadyWithWrongAPIIsInvalid() {
        guard case .invalidReady(let why) = ServerHandshake.parse(line: #"READY {"port":1,"pid":2,"api":1}"#) else {
            return XCTFail("expected invalidReady")
        }
        XCTAssertTrue(why.contains("API 1"))
    }

    func testReadyWithOutOfRangePortIsInvalid() {
        guard case .invalidReady = ServerHandshake.parse(line: #"READY {"port":70000,"pid":2,"api":2}"#) else {
            return XCTFail("expected invalidReady")
        }
    }

    func testReadyNamesTheEngineAndTheQwenModel() {
        XCTAssertEqual(
            ServerHandshake.parse(line: #"READY {"port":1,"pid":2,"api":2,"loaded":["zh"],"engine":"kokoro"}"#),
            .ready(ReadyInfo(port: 1, pid: 2, api: 2, loaded: ["zh"], engine: "kokoro")))
        XCTAssertEqual(
            ServerHandshake.parse(line: #"READY {"port":1,"pid":2,"api":2,"loaded":["zh","en"],"engine":"qwen","model":"1.7b"}"#),
            .ready(ReadyInfo(port: 1, pid: 2, api: 2, loaded: ["zh", "en"], engine: "qwen", model: "1.7b")))
        guard case .invalidReady = ServerHandshake.parse(line: #"READY {"port":1,"pid":2,"api":2,"engine":7}"#) else {
            return XCTFail("a non-string engine is a malformed READY line")
        }
    }

    func testEachFlavorChecksTheReadyEngine() {
        let installation = HQInstallation(home: "/hq", installedAt: nil, modelBytes: 0)
        func info(_ engine: String?, _ model: String?) -> ReadyInfo {
            ReadyInfo(port: 1, pid: 2, api: 2, loaded: [], engine: engine, model: model)
        }
        XCTAssertNil(ServerFlavor.kokoro.readyMismatch(info(nil, nil)))
        XCTAssertNil(ServerFlavor.kokoro.readyMismatch(info("kokoro", nil)))
        XCTAssertEqual(ServerFlavor.kokoro.readyMismatch(info("qwen", "1.7b")),
                       "READY reports engine qwen, model 1.7b; ReadRead started engine kokoro")
        XCTAssertNil(ServerFlavor.qwen(installation).readyMismatch(info("qwen", "1.7b")))
        XCTAssertEqual(ServerFlavor.qwen(installation).readyMismatch(info(nil, nil)),
                       "READY reports engine none, model none; ReadRead started engine qwen, model 1.7b")
        XCTAssertEqual(ServerFlavor.qwen(installation).readyMismatch(info("kokoro", nil)),
                       "READY reports engine kokoro, model none; ReadRead started engine qwen, model 1.7b")
        XCTAssertEqual(ServerFlavor.kokoro.engine, .kokoro)
        XCTAssertEqual(ServerFlavor.qwen(installation).engine, .qwen)
    }

    // MARK: - FATAL

    func testParsesFatalMessage() {
        let message = ServerHandshake.parse(line: #"FATAL {"message":"model file missing: kokoro-v1.0.fp16.onnx"}"#)
        XCTAssertEqual(message, .fatal("model file missing: kokoro-v1.0.fp16.onnx"))
    }

    func testFatalWithNonJSONPayloadKeepsTheRawText() {
        XCTAssertEqual(ServerHandshake.parse(line: "FATAL no token"), .fatal("no token"))
        XCTAssertEqual(ServerHandshake.parse(line: "FATAL"), .fatal("unknown startup error"))
    }

    func testFatalKeepsNonASCII() {
        let message = ServerHandshake.parse(line: #"FATAL {"message":"缺少模型 é"}"#)
        XCTAssertEqual(message, .fatal("缺少模型 é"))
    }

    // MARK: - Junk

    func testOtherLinesAreJunk() {
        XCTAssertEqual(ServerHandshake.parse(line: "Loading model..."), .junk("Loading model..."))
        XCTAssertEqual(ServerHandshake.parse(line: "READYNESS 1"), .junk("READYNESS 1"))
        XCTAssertEqual(ServerHandshake.parse(line: "{\"port\":1}"), .junk("{\"port\":1}"))
        XCTAssertEqual(ServerHandshake.parse(line: ""), .junk(""))
    }

    // MARK: - LineBuffer

    func testLineBufferJoinsPartialLinesAcrossReads() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("REA".utf8)), [])
        XCTAssertEqual(buffer.append(Data("DY {\"port\":1".utf8)), [])
        XCTAssertEqual(buffer.append(Data("}\nnext".utf8)), ["READY {\"port\":1}"])
        XCTAssertEqual(buffer.finish(), "next")
        XCTAssertNil(buffer.finish())
    }

    func testLineBufferSplitsSeveralLinesInOneRead() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("a\r\nb\n\nc\n".utf8)), ["a", "b", "", "c"])
        XCTAssertNil(buffer.finish())
    }

    func testLineBufferKeepsMultibyteCharacterSplitAcrossReads() {
        let bytes = Array("FATAL 缺少".utf8)
        var buffer = LineBuffer()
        // Split inside the 3-byte encoding of 缺.
        XCTAssertEqual(buffer.append(Data(bytes[..<7])), [])
        XCTAssertEqual(buffer.append(Data(bytes[7...]) + Data("\n".utf8)), ["FATAL 缺少"])
    }

    func testLineBufferCutsRunawayLines() {
        var buffer = LineBuffer()
        let lines = buffer.append(Data(repeating: UInt8(ascii: "x"), count: LineBuffer.maxLineBytes + 1))
        XCTAssertEqual(lines.count, 1)
        XCTAssertNil(buffer.finish())
    }
}
