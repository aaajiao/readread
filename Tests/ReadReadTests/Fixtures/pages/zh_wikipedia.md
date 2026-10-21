---
title: "语音合成 - 维基百科，自由的百科全书"
author: "Wikipedia"
site: "Wikipedia"
published: 2003-02-14T08:34:20Z
source: "https://zh.wikipedia.org/wiki/语音合成"
domain: "zh.wikipedia.org"
language: "zh"
word_count: 1255
---

**語音合成** 是將人類語音用人工的方式所產生。若是將電腦系統用在語音合成上，則稱為語音合成器，而語音合成器可以用軟/硬體所實現。文字轉語音（Text-To-Speech，TTS）系統則是將一般語言的文字轉換為語音，其他的系統可以描繪語言符號的表示方式，就像音標轉換至語音一樣[^1] 。

而合成後的語音則是利用在資料庫內的許多已錄好的語音連接起來。系統則因為儲存的語音單元大小不同而有所差異，若是要儲存phone以及diphone的話，系統必須提供大量的儲存空間，但是在語意上或許會不清楚。而用在特定的使用領域上，儲存整字或整句的方式可以達到高品質的語音輸出。另外，包含了聲道模型以及其他的人類聲音特徵參數的合成器則可以創造出完整的合成聲音輸出[^2] 。

一個語音合成器的品質通常是決定於人聲的相似度以及語意是否能被了解。一個清晰的文字轉語音程式應該提供人類在視覺受到傷害或是得到失讀症時，能夠聽到並且在個人電腦上完成工作。從80年代早期開始，許多的電腦作業系統已經包含了語音合成器了。

## 文字處理的概觀

## 歷史

==早在17世紀就有法國人研發機械式的說話裝置。== 直到19世紀， [貝爾實驗室](https://zh.wikipedia.org/wiki/%E8%B2%9D%E7%88%BE%E5%AF%A6%E9%A9%97%E5%AE%A4 "貝爾實驗室") 對於電子語音合成技術的研究，才開啟近代語音合成技術的發展。貝爾實驗室在1939年製作出第一個電子語音合成器VODER[^3] ，是一種利用共振峰原理所製作的合成器 。 1960年，瑞典語言學家G. Fant則提出利用線性預測編碼技術（LPC）來作為語音合成分析技術，並推動了日後的發展。後來1980年代Moulines E和Charpentier F提出新的語音合成演算法PSOLA，此技術可以合成比較自然的語音。

## 合成器技術

### 串接合成

#### 單位選擇合成

這通常是使用字詞預錄的方式，將各字詞的發音預先錄製好，經處理後存放在資料庫中。使用時再將預發音的字句斷成字詞，再把發音的資料自資料庫中取出，交由 [DSP](https://zh.wikipedia.org/wiki/%E6%95%B8%E4%BD%8D%E8%A8%8A%E8%99%9F%E8%99%95%E7%90%86%E5%99%A8 "數位訊號處理器") 去處理發音的合成。

#### Diphone合成

#### Domain-specific合成

### 共振峰合成

### 發音合成

### HMM基礎合成

### 正弦波合成

### 深度學習合成

深度學習語音合成使用深度神經網絡（DNN）從文本（文本到語音）或頻譜（聲碼器）產生人工語音。深度神經網絡使用大量錄製的語音進行訓練，如果是文本到語音系統，則使用和語音相對的文本。

基於DNN的語音合成器正在接近人聲的自然度。該方法的缺點的例子是當數據不充分時強健性較低，缺乏可控性，自動回歸模型的性能低。一些局限性（如缺乏可控性）可以通過未來的研究得到解決。

## 相关比赛

- [Blizzard Challenge](https://zh.wikipedia.org/w/index.php?title=Blizzard_Challenge&action=edit&redlink=1 "Blizzard Challenge（页面不存在）")[^4][^5]
- [voice conversion](https://zh.wikipedia.org/w/index.php?title=Voice_conversion&action=edit&redlink=1 "Voice conversion（页面不存在）")[^6]

## 含有語音合成器的軟體

- [NVDA](https://zh.wikipedia.org/wiki/NVDA "NVDA") （开源多国语言 [螢幕報讀軟體](https://zh.wikipedia.org/wiki/%E8%9E%A2%E5%B9%95%E5%A0%B1%E8%AE%80%E8%BB%9F%E9%AB%94 "螢幕報讀軟體") ）
- 台灣 [工研院](https://zh.wikipedia.org/wiki/%E5%B7%A5%E7%A0%94%E9%99%A2 "工研院") 資通所語音團隊開發出的mTTS
- JAWS（商業付費 [螢幕報讀軟體](https://zh.wikipedia.org/wiki/%E8%9E%A2%E5%B9%95%E5%A0%B1%E8%AE%80%E8%BB%9F%E9%AB%94 "螢幕報讀軟體") ）
- 內建於蘋果電腦相關產品的 [VoiceOver Utility](https://zh.wikipedia.org/wiki/VoiceOver_Utility "VoiceOver Utility")
- [Android](https://zh.wikipedia.org/wiki/Android "Android") 1.6版加入支援語音合成的功能。[^7]
- 微軟在1995年開始，開發了一套 [Microsoft Speech API](https://zh.wikipedia.org/w/index.php?title=Microsoft_Speech_API&action=edit&redlink=1 "Microsoft Speech API（页面不存在）") ，微軟的一些作業系統或軟體有提供支援語音功能。
- [VOCALOID](https://zh.wikipedia.org/wiki/VOCALOID "VOCALOID") 及 [VOICEROID](https://zh.wikipedia.org/wiki/VOICEROID "VOICEROID") ，前者偏重歌唱而后者偏重 TTS。

## 語音合成標記語言

## 参见

- [人机界面](https://zh.wikipedia.org/wiki/%E4%BA%BA%E6%9C%BA%E7%95%8C%E9%9D%A2 "人机界面")
- [語音识别](https://zh.wikipedia.org/wiki/%E8%AF%AD%E9%9F%B3%E8%AF%86%E5%88%AB "语音识别")
- [手写识别](https://zh.wikipedia.org/wiki/%E6%89%8B%E5%86%99%E8%AF%86%E5%88%AB "手写识别")
- [VOCALOID](https://zh.wikipedia.org/wiki/VOCALOID "VOCALOID")
- [智能儀錶](https://zh.wikipedia.org/w/index.php?title=%E6%99%BA%E8%83%BD%E4%BB%AA%E8%A1%A8&action=edit&redlink=1 "智能仪表（页面不存在）")
- [智能玩具](https://zh.wikipedia.org/w/index.php?title=%E6%99%BA%E8%83%BD%E7%8E%A9%E5%85%B7&action=edit&redlink=1 "智能玩具（页面不存在）")
- [电子地图](https://zh.wikipedia.org/wiki/%E7%94%B5%E5%AD%90%E5%9C%B0%E5%9B%BE "电子地图")
- [电子导游](https://zh.wikipedia.org/w/index.php?title=%E7%94%B5%E5%AD%90%E5%AF%BC%E6%B8%B8&action=edit&redlink=1 "电子导游（页面不存在）")
- [电子词典](https://zh.wikipedia.org/wiki/%E7%94%B5%E5%AD%90%E8%AF%8D%E5%85%B8 "电子词典")

## 参考資料

## 外部連結

[^1]: Allen, Jonathan; Hunnicutt, M. Sharon; Klatt, Dennis. [From Text to Speech: The MITalk system](https://archive.org/details/fromtexttospeech00alle). Cambridge University Press. 1987. [ISBN 978-0-521-30641-6](https://zh.wikipedia.org/wiki/Special:BookSources/978-0-521-30641-6 "Special:BookSources/978-0-521-30641-6").

[^2]: Rubin, P.; Baer, T.; Mermelstein, P. An articulatory synthesizer for perceptual research. Journal of the Acoustical Society of America. 1981, **70** (2): 321–328. [Bibcode:1981ASAJ...70..321R](https://ui.adsabs.harvard.edu/abs/1981ASAJ...70..321R). [doi:10.1121/1.386780](https://doi.org/10.1121%2F1.386780).

[^3]: 柳春、于洪志（2008年）：《現代教育技術》，第26期第64頁，北京：清華大學電教中心。

[^4]: [存档副本](https://www.synsig.org/index.php/Blizzard_Challenge_2020). \[2020-05-28\]. （原始内容 [存档](https://web.archive.org/web/20220702035031/https://www.synsig.org/index.php/Blizzard_Challenge_2020) 于2022-07-02）.

[^5]: [存档副本](http://www.festvox.org/blizzard/). \[2020-05-28\]. （原始内容 [存档](https://web.archive.org/web/20200423055016/http://www.festvox.org/blizzard/) 于2020-04-23）.

[^6]: [存档副本](http://www.vc-challenge.org/). \[2020-05-28\]. （原始内容 [存档](https://web.archive.org/web/20200219161756/http://www.vc-challenge.org/) 于2020-02-19）.

[^7]: Jean-Michel Trivi. [An introduction to Text-To-Speech in Android](http://android-developers.blogspot.com/2009/09/introduction-to-text-to-speech-in.html). Android-developers.blogspot.com. 2009-09-23 \[2010-02-17\]. （原始内容 [存档](https://web.archive.org/web/20110708024054/http://android-developers.blogspot.com/2009/09/introduction-to-text-to-speech-in.html) 于2011-07-08）.