# ax-probe：可行性验证

这个程序只验证一件事：**能否通过 macOS 辅助功能 API，实时读到 Claude 桌面客户端正在生成的回复文字。**

结论会决定刘海提词器读取文字的主方案：这条路走通就自动读取，走不通就退回到剪贴板方案。

## 原理

1. Claude 桌面版基于 Electron（Chromium），默认不构建辅助功能树。程序会对它设置 `AXManualAccessibility = true`，让网页内容暴露出来。
2. 在 Claude 窗口里找到聊天页面（`AXWebArea`），然后找出 class 中包含 `font-claude` 的元素，作为 Claude 的回复，取最后一条。
3. 每 250ms 读一次最后一条回复的文字，和上次读到的比较，把新增部分打印到终端。
4. 文字 1.5 秒不再变化就算回复结束，输出字数、生成速度和每次扫描的耗时。

## 环境要求

- macOS 13 或更高版本
- Xcode 或 Command Line Tools（只需要 `swift` 命令，可以先运行 `xcode-select --install`）
- 已安装并登录 Claude 桌面客户端

## 运行步骤

```bash
cd spike/ax-probe
swift build -c release
```

**第一步：授权**

先打开 Claude 客户端，然后运行：

```bash
.build/release/ax-probe watch
```

第一次运行会提示没有辅助功能权限。到 **系统设置 → 隐私与安全性 → 辅助功能**，勾选你正在用的终端（Terminal、iTerm 等），然后**完全退出并重新打开终端**再运行。

**第二步：实时监听**

```bash
.build/release/ax-probe watch
```

运行后去 Claude 客户端问一个回答比较长的问题，比如"用 500 字介绍一下长城"。观察终端里的文字是否跟着 Claude 一起逐步出现。

**第三步（如果第二步没有输出，或输出不对）：导出辅助功能树**

```bash
.build/release/ax-probe dump > tree.txt
```

更省事的做法是用 `locate` 直接定位某段文字所在的元素：

```bash
.build/release/ax-probe locate "Claude 已回复" > locate.txt
```

也可以在 `tree.txt` 中搜索回复里的一段文字，看它上面几层元素的 class（以 `.` 开头的部分）。找到能代表"Claude 的一条回复"的 class 后，用 `--class` 指定：

```bash
.build/release/ax-probe watch --class 你找到的class片段
```

## 需要反馈的信息

请把以下内容发给我：

1. `watch` 启动时输出的几行信息，包括 `[精确模式]` 或 `[兜底模式]`、首次扫描耗时。
2. 提问后，终端里的文字是否**跟着 Claude 一起逐步出现**，还是等回答完才一次性出现。
3. 回复结束时那行 `[完成] …` 统计（字数、生成速度、扫描耗时）。
4. 输出中有没有乱码、漏字、重复，或出现 `[前文变化，回退 …]`。
5. 如果没有成功：`dump` 输出的 `tree.txt` 中包含回复文字的那一段（前后几十行即可，可以先删掉隐私内容）。

## 参数

| 命令 | 参数 | 默认值 | 说明 |
|---|---|---|---|
| `watch` | `--class` | `font-claude` | 回复元素 class 中包含的片段 |
| `watch` | `--interval` | `250` | 轮询间隔，单位毫秒 |
| `watch` | `--idle` | `1500` | 文字多久不变就算回复结束，单位毫秒 |
| `locate "文字"` | `--max` | `2` | 只输出最后几处匹配 |
| `locate "文字"` | `--context` | `4` | 从匹配的元素往上几层，打印那一层的子树 |
| `dump` | `--depth` | `200` | 最大遍历深度 |
| `dump` | `--max-nodes` | `20000` | 最多输出的节点数 |

状态信息输出到 stderr，回复文字和树结构输出到 stdout，可以分别重定向。
