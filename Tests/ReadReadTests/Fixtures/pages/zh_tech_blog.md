---
title: "用 Swift 写一个菜单栏朗读器：从文字到声音 | 示例博客"
site: "示例博客"
source: "https://blog.example.com/2024/10/menubar-reader"
domain: "blog.example.com"
language: "zh"
word_count: 1180
---

# 用 Swift 写一个菜单栏朗读器：从文字到声音

二○二四年十月，我开始写一个小工具：把网页文章交给本地的语音模型，在 macOS 的菜单栏里朗读出来。这篇文章记录了整个过程，也包括踩过的坑。[^1]

> [!NOTE]
> 本文的代码都在 [GitHub](https://github.com/example/reader) 上，欢迎提 issue。

## 一、为什么要自己写

市面上的朗读软件大多有两个问题：一是中英文混排时容易读错，比如把“iPhone 16 Pro”读成一串字母；二是遇到长句子就卡住，要等很久才出声。我想要的是**打开就能听**，而且*不上传任何内容*。

详见https://example.com/why-local。下面分三部分来讲。

### 1.1 目标

- [x] 支持中文和英文
- [x] 句子级别的高亮
- [ ] 支持日文（暂不考虑）
- 首句延迟低于 1 秒

## 二、文本处理

网页先经过 defuddle 转成 Markdown，再去掉脚注、图片和链接地址，例如下面这张图：

![流程图](https://blog.example.com/images/pipeline.png "处理流程")

| 步骤 | 输入 | 输出 |
| --- | :---: | ---: |
| 抽取 | HTML | Markdown |
| 清理 | Markdown | 纯文本 |
| 分句 | 纯文本 | 句子 |

清理之后的文本按句子切分。中文以“。！？”结尾；英文要小心缩写，比如 Dr. Smith 和 e.g. 这种写法，数字 3.14、1,000 和 12:30 也不能拆开。

分句的代码在 `SpeechChunker` 里，核心逻辑大概是这样：

```swift
let pieces = SpeechChunker.pieces(of: text)
for piece in pieces where piece.text.count > 120 {
    print("太长了：\(piece.text)")
}
```

如果一个句子特别长而且完全没有标点符号比如这一句就是故意写成这样的它会一直延续下去直到超过一百二十个字为止这时候分句器只能在空白或者硬切的位置把它分开否则合成一次要等很久用户的体验会很差所以必须把它切开才行而且切开以后每一段都要尽量一样长不能在最后留下一个只有两三个字的小尾巴听起来才不会奇怪。

## 三、语音合成

模型用的是 Kokoro[^kokoro]，中文和英文各一个。合成速度大约是实时的十倍&nbsp;——在 M1 上测得 RTF 约为 0.1。

> 有人问：“为什么不用系统自带的语音？”
> > 因为系统语音的中文不够自然，而且不能控制停顿。

调用接口时要带上令牌：

~~~bash
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/synthesize
~~~

按 <kbd>⌘</kbd> + <kbd>R</kbd> 可以重新朗读当前段落。🎉

### 3.1 数字的读法

“一九○○年”和“二〇二四年”里的圈要读成“零”，而“○○公司”这种占位符保持原样。价格写成 ¥199 或者 50% 都能正确朗读，1️⃣ 这样的数字表情也会读出数字。

另外，R&amp;D 部门的同事提醒我：Markdown 里的 \*星号\* 和 \_下划线\_ 要还原成普通字符。[1][2]

## 四、小结

整个项目断断续续写了三个月，代码不到五千行。如果你也想试试，可以从[官方文档][docs]开始。

[docs]: https://example.com/docs "文档"

## 参考资料

1. Kokoro 模型说明：https://huggingface.co/hexgrad/Kokoro-82M
2. [defuddle](https://github.com/kepano/defuddle)

[^1]: 这是我的第一个 Swift 项目，
    之前一直写 Python。

[^kokoro]: 一个只有八千两百万参数的开源模型。
