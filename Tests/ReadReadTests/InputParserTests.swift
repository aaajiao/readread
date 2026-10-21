import XCTest

@testable import ReadRead

/// What the URL field makes of its input (R3-06, R4-06).
final class InputParserTests: XCTestCase {
    private func parse(_ input: String, existing: Set<String> = []) -> ReadingInput? {
        InputParser.parse(input, fileExists: { existing.contains($0) })
    }

    private func url(_ string: String) -> ReadingInput { .url(URL(string: string)!) }

    func testEmptyInputIsNothing() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("  \n\t "))
    }

    func testWebAddresses() {
        XCTAssertEqual(parse("https://example.com/a?b=1#c"), url("https://example.com/a?b=1#c"))
        XCTAssertEqual(parse("  http://example.com  "), url("http://example.com"))
        XCTAssertEqual(parse("example.com/path"), url("https://example.com/path"), "a bare host gets https")
        XCTAssertEqual(parse("zh.wikipedia.org/wiki/语音合成"), .url(URL(string: "https://zh.wikipedia.org/wiki/语音合成")!))
        XCTAssertEqual(parse("localhost:8080/wiki"), url("http://localhost:8080/wiki"), "a local address gets http")
        XCTAssertEqual(parse("192.168.1.10/wiki"), url("http://192.168.1.10/wiki"))
        XCTAssertEqual(parse("<https://example.com/x>"), url("https://example.com/x"))
        XCTAssertEqual(parse("\"https://example.com/x\""), url("https://example.com/x"))
        XCTAssertEqual(parse("github.io"), url("https://github.io"))
        XCTAssertEqual(parse("x.ai"), url("https://x.ai"))
        XCTAssertEqual(parse("b23.tv/AbCd"), url("https://b23.tv/AbCd"))
        XCTAssertEqual(parse("example.md/docs"), url("https://example.md/docs"), "a country code with a path")
        XCTAssertEqual(parse("box.mycorp:3000"), url("https://box.mycorp:3000"), "any name with a port")
        XCTAssertEqual(parse("box.example:3000"), url("http://box.example:3000"), "a name reserved for local use gets http")
        XCTAssertEqual(parse("例子.中国"), .url(URL(string: "https://例子.中国")!))
        XCTAssertEqual(parse("https://zh.wikipedia.org/wiki/C语言"), .url(URL(string: "https://zh.wikipedia.org/wiki/C语言")!),
                       "a URL on its own is taken as it is")
    }

    func testThingsThatAreNotWebAddresses() {
        XCTAssertEqual(parse("hello"), .text("hello"))
        // R3-06: a dot does not make a host; these never go to defuddle.md.
        for text in ["今天天气很好.明天也好", "你好.世界", "张三.李四", "README.md", "notes.txt", "run.sh", "Mr.Li", "Hello.World",
                     "ASP.NET", "v1.2", "3.14"] {
            XCTAssertEqual(parse(text), .text(text), text)
        }
        XCTAssertEqual(parse("e.g."), .text("e.g."))
        XCTAssertEqual(parse("mailto:me@example.com"), .text("mailto:me@example.com"))
        XCTAssertEqual(parse("ftp://example.com/file"), .text("ftp://example.com/file"))
        XCTAssertEqual(parse("https://"), .text("https://"))
    }

    func testShareTextWithALink() {
        XCTAssertEqual(parse("【rsync 用法教程】 https://www.ruanyifeng.com/blog/2020/08/rsync.html 复制链接打开"),
                       url("https://www.ruanyifeng.com/blog/2020/08/rsync.html"))
        XCTAssertEqual(parse("Check this out: https://example.com/post"), url("https://example.com/post"))
        // Without a space, or with text glued to the end of the link.
        let rsync = url("https://www.ruanyifeng.com/blog/2020/08/rsync.html")
        XCTAssertEqual(parse("原文链接：https://www.ruanyifeng.com/blog/2020/08/rsync.html"), rsync)
        XCTAssertEqual(parse("【rsync 用法教程】 https://www.ruanyifeng.com/blog/2020/08/rsync.html复制链接打开"), rsync)
        XCTAssertEqual(parse("看这篇 https://mp.weixin.qq.com/s/AbCdEf123很好"), url("https://mp.weixin.qq.com/s/AbCdEf123"))
        XCTAssertEqual(parse("【标题】https://www.bilibili.com/video/BV1xx411c7mD"), url("https://www.bilibili.com/video/BV1xx411c7mD"))
        XCTAssertEqual(parse("小红书 http://xhslink.com/a/AbC，复制本条信息，打开【小红书】App查看精彩内容！"), url("http://xhslink.com/a/AbC"))
        XCTAssertEqual(InputParser.trimShareGlue("https://zh.wikipedia.org/wiki/语音合成"), "https://zh.wikipedia.org/wiki/语音合成")
        let prose = String(repeating: "这是一段很长的文字，里面顺便提到了一个网址。", count: 8) + " https://example.com/post"
        XCTAssertEqual(parse(prose), .text(prose), "a link inside long text is part of the text")
    }

    func testFilePaths() {
        XCTAssertEqual(parse("/Users/me/notes.md", existing: ["/Users/me/notes.md"]),
                       .file(URL(fileURLWithPath: "/Users/me/notes.md")))
        XCTAssertEqual(parse(#"/Users/me/My\ File.txt"#, existing: ["/Users/me/My File.txt"]),
                       .file(URL(fileURLWithPath: "/Users/me/My File.txt")), "Terminal escapes")
        XCTAssertEqual(parse("'/Users/me/My File.txt'", existing: ["/Users/me/My File.txt"]),
                       .file(URL(fileURLWithPath: "/Users/me/My File.txt")))
        let home = NSHomeDirectory()
        XCTAssertEqual(parse("~/notes.txt", existing: [home + "/notes.txt"]), .file(URL(fileURLWithPath: home + "/notes.txt")))
        XCTAssertEqual(parse("file:///tmp/a%20b.md"), .file(URL(string: "file:///tmp/a%20b.md")!))
        XCTAssertEqual(parse("/no/such/file.md"), .text("/no/such/file.md"), "a path that does not exist is text")
    }

    func testPlainText() {
        XCTAssertEqual(parse("今天天气很好。"), .text("今天天气很好。"))
        XCTAssertEqual(parse("  First line.\r\nSecond line.  "), .text("First line.\r\nSecond line."))
        XCTAssertEqual(parse("/Users/me/notes.md\nand more", existing: ["/Users/me/notes.md"]),
                       .text("/Users/me/notes.md\nand more"), "several lines are text")
    }

    func testLocalNetworkHosts() {
        for local in ["http://localhost/a", "http://127.0.0.1:8000", "http://10.0.0.5", "http://172.16.4.1", "http://172.31.0.1",
                      "http://192.168.1.10/wiki", "http://169.254.1.1", "http://100.64.0.1", "http://printer.local",
                      "http://nas.lan/x", "http://wiki.internal", "http://router.home.arpa", "http://intranet/page",
                      "http://[::1]:8080/", "http://[fd00::1]/", "http://app.localhost"] {
            XCTAssertTrue(InputParser.isLocalNetwork(URL(string: local)!), local)
        }
        for remote in ["https://example.com", "https://8.8.8.8", "http://172.32.0.1", "https://zh.wikipedia.org/wiki/x",
                       "https://[2001:db8::1]/"] {
            XCTAssertFalse(InputParser.isLocalNetwork(URL(string: remote)!), remote)
        }
    }

    /// Other spellings of local addresses (a browser reads 127.1 as 127.0.0.1) and the names
    /// reserved for local use; public ones stay public.
    func testEverySpellingOfALocalAddress() {
        for local in ["http://127.1:8080/x", "http://0x7f.1/", "http://0177.0.0.1/", "http://2130706433/", "http://0x7f000001/",
                      "http://192.168.001.010/", "http://[::ffff:192.168.1.10]/", "http://[::ffff:c0a8:010a]/", "http://[::]/",
                      "http://[fe90::1]/", "http://[febf::1]/", "http://[fec0::1]/", "http://[fe80::1%25en0]/", "http://fritz.box/",
                      "http://box.fritz.box/", "http://foo.test/", "http://server.localdomain/", "http://site.example/",
                      "http://name.invalid/", "http://nas.local./", "http://mydevice./", "http://user:pw@192.168.1.10/"] {
            XCTAssertTrue(InputParser.isLocalNetwork(URL(string: local)!), local)
        }
        for remote in ["http://8.8.8.8/", "http://8.8.8.8.nip.io/", "http://[::ffff:8.8.8.8]/", "http://[2606:4700::1111]/",
                       "http://[fe00::1]/", "http://example.com/", "http://test.com/", "http://box.com/", "http://1e100.net/",
                       "http://deadbeef.com/", "http://abc.de/"] {
            XCTAssertFalse(InputParser.isLocalNetwork(URL(string: remote)!), remote)
        }
        XCTAssertEqual(InputParser.ipv4Address("127.1"), 0x7F00_0001)
        XCTAssertNil(InputParser.ipv4Address("example.com"))
        XCTAssertNil(InputParser.ipv4Address("cafe.be"))
    }
}
