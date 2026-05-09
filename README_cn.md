# pebble

> *给写代码的人做的 macOS 终端。*

🇨🇳 中文  ·  🇬🇧 [English](README.md)

![pebble 截图 —— 侧边栏三个 workspace,两个 pane 并排跑 Claude Code 和 Codex,`+` 菜单展开了五种内置 agent](screenshot.png)

现在的终端都是在 AI agent 出现之前设计的。**pebble 直接把 agent 会话做成 tab** —— Claude Code / Codex / Gemini CLI 跟 shell 并排放在一起,界面会跟着 agent 的状态走。开源、仅支持 macOS、MIT 许可。底层 GPU 渲染走 [libghostty](https://github.com/ghostty-org/ghostty)。

**[下载最新版](https://github.com/iAmCorey/pebble/releases/latest)**  ·  [架构文档](ARCHITECTURE.md)  ·  [更新日志](CHANGELOG.md)

---

## 它做什么

**vertical tabs,做得像样的那种。** 侧边栏放所有 workspace,可以折叠成三种宽度(`⌘⌃S` 循环切)。每个 pane 都有自己的 tab 栏,cmux 风格的 split。tab 可以拖来拖去,也可以拖到另一个 pane 里(整个会话连着引擎和 scrollback 一起搬过去)。所有状态重启之后都还在。

**一键开 AI agent。** Claude Code · Codex · Gemini CLI · OpenCode · Amp。`+` 菜单里点一个 —— shell 还没把命令行打出来,agent 已经在跑了。侧边栏上的圆点实时告诉你每个 agent 现在在干嘛:跑命令中、等你回复、还是闲着。

**知道你的 shell 干了啥。** OSC 133 / FinalTerm 钩子装在我们自己的 ZDOTDIR 里,**不动你的** `~/.zshrc`。上条命令跑挂的时候,对应 tab 和它所在的 workspace 上会冒一个小红点;鼠标悬停可以看到 `exit N · 12.4s`。`⌘↑` / `⌘↓` 直接在历史输出里跳到上一个 / 下一个命令提示符。

**全键盘操作。** `⌘T` / `⌘N` 新开 tab / workspace · `⌘W` / `⌘⇧W` 关闭 · `⌘1-9` / `⌥⌘1-9` 切换 · `⌘D` / `⌘⇧D` 向右 / 向下分屏 · `⌘[` `⌘]` 切换焦点 · `⌘=` / `⌘-` / `⌘0` 字号 · `⌘K` 清屏。

**该有的 macOS 体验都有。** Onest + JetBrains Mono 字体。顶部 32pt 给红绿灯留位置,旁边放了一块专门用来拖窗的区域(解决了拖标题栏和拖 tab 抢手势的老毛病)。自定义 About 面板、原生菜单带快捷键提示、中日韩 / 越南文等 IME 都支持。状态写在 `~/Library/Application Support/pebble/`,不连云、不发遥测、不要账号。

## 安装

从 [Releases](https://github.com/iAmCorey/pebble/releases) 下载最新的 `.dmg`,打开后把 `Pebble.app` 拖进 `Applications` 文件夹。

**第一次启动会被 Gatekeeper 拦下来**,因为现在是 adhoc 签名 —— 还没买 Apple Developer ID,等项目有真实用户的时候再花那笔钱。你会看到 *"Pebble cannot be opened because Apple cannot check it for malicious software"* 或者 *"is damaged and cannot be opened"* 这两类报错。下面三种方法挑一个就能过:

<details>
<summary><b>方法 A —— 走系统设置 <i>(推荐)</i></b></summary>

1. 先双击一次 `Pebble.app`,macOS 会弹警告,把警告窗口关掉。
2. 打开 **系统设置 → 隐私与安全性**,往下翻到 **安全性** 这一段。
3. 看到 *"Pebble was blocked to protect your Mac"*,点旁边的 **Open Anyway**,输密码。
4. 再双击一次 `Pebble.app`,这次会有 **Open** 按钮,点它。完事。
</details>

<details>
<summary><b>方法 B —— Terminal 一行搞定</b></summary>

```sh
xattr -d com.apple.quarantine /Applications/Pebble.app
```
</details>

<details>
<summary><b>方法 C —— 连 "Open Anyway" 按钮都没出现的话</b></summary>

新版 Sequoia 有时对 adhoc 签名的 app **根本不给** "Open Anyway" 按钮。这种情况下先把旧版的 "Anywhere" 选项打开,再回去走方法 A:

```sh
sudo spctl --global-disable      # macOS 15+;老系统用 --master-disable
# 系统设置 → 隐私与安全性 → "Allow applications from" 选 Anywhere
# 双击 Pebble.app,这下能跑了
sudo spctl --global-enable       # pebble 跑过一次之后立刻把 Gatekeeper 打开
```

注意这条**是系统级开关** —— 关着的时候 macOS 会让任何未签名 app 都能跑。pebble 跑过一次就把它打开,系统会单独记住信任过 pebble,以后不会再拦。
</details>

macOS **只拦第一次启动**。之后从 Spotlight、Dock、Finder 启动都跟普通 app 一样。

## 从源码构建

需要 Xcode 26+ 和 macOS 14+(Sonoma —— 因为用了 `@Observable`,这是它能跑的最低系统)。

```sh
./scripts/setup-libghostty.sh        # 一次性:把预编译的 libghostty xcframework 下到 Vendor/
swift build
swift run                            # 开发模式直接跑
swift test                           # 31 个单测

./scripts/build-app.sh               # 产出 dist/Pebble.app
./scripts/build-dmg.sh --build       # 产出 dist/Pebble-vX.Y.Z.dmg
```

`Vendor/` 和 `dist/` 都在 `.gitignore` 里。libghostty 那个 setup 脚本可以反复跑,SHA 没变就直接跳过。

## License

MIT —— 见 [LICENSE](LICENSE)。打包进来的第三方资源各自保留自己的 license,详见 [NOTICE.md](NOTICE.md)。
