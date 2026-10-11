import AppKit
import ApplicationServices

/// 在后台线程轮询 Claude 客户端，把最后一条回复的变化转成事件，在主线程回调。
final class ClaudeReader {
    enum Event {
        /// 菜单里显示的连接状态
        case status(String)
        /// 新的回复开始（可能还在思考，正文为空）
        case started
        /// 新增的正文，块与块之间用换行分隔
        case appended(String)
        /// 回复结束
        case finished
    }

    var onEvent: ((Event) -> Void)?

    private let claudeBundleIDs = ["com.anthropic.claudefordesktop"]
    private let interval: TimeInterval = 0.25
    /// 找不到聊天页面或消息列表时，隔多久再全页搜索一次（全页搜索比较慢）
    private let searchInterval: TimeInterval = 1
    private var lastStatus: String?

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "ClaudeReader"
        thread.start()
    }

    private func send(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    private func setStatus(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        send(.status(status))
    }

    private func run() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        while true {
            guard AXIsProcessTrusted() else {
                setStatus("需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能")
                Thread.sleep(forTimeInterval: searchInterval)
                continue
            }
            guard let app = runningClaude() else {
                setStatus("没有找到 Claude 客户端")
                Thread.sleep(forTimeInterval: searchInterval)
                continue
            }
            watch(app)
        }
    }

    private func runningClaude() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        return apps.first { claudeBundleIDs.contains($0.bundleIdentifier ?? "") }
            ?? apps.first { $0.localizedName == "Claude" }
    }

    /// 持续监听一个 Claude 进程，直到它退出
    private func watch(_ app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1)
        // Electron 默认不构建辅助功能树，设置这个属性后才会暴露网页内容
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var webArea: AXUIElement?
        var messageList: AXUIElement?
        var nextSearch = Date.distantPast
        var tracker = ReplyTracker()

        while !app.isTerminated {
            let tickStart = Date()

            if messageList?.role == nil, tickStart >= nextSearch {
                if webArea?.role == nil { webArea = findWebArea(in: appElement) }
                messageList = webArea.flatMap(findMessageList(in:))
                if messageList == nil { nextSearch = tickStart.addingTimeInterval(searchInterval) }
            }

            if let list = messageList, list.role != nil {
                setStatus("正在监听 Claude")
                let articles = messageArticles(in: list)
                let reply = articles.last.flatMap(replyRow(of:)).map(readReply)
                for event in tracker.update(articles: articles, reply: reply, now: Date()) {
                    send(event)
                }
            } else {
                setStatus(webArea == nil ? "Claude 已打开，等待聊天窗口" : "已连接 Claude，打开一个聊天即可")
            }

            let remaining = interval - Date().timeIntervalSince(tickStart)
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
    }
}

/// 比较前后两次读到的内容，判断新回复开始、正文增加和回复结束
struct ReplyTracker {
    /// 没等到工具栏时，文字多久不变就认为回复结束
    var idle: TimeInterval = 3

    private var initialized = false
    private var anchor: AXUIElement?
    private var lastText: String?
    private var lastCount = 0
    private var streaming = false
    private var lastChange: Date?

    mutating func update(articles: [AXUIElement], reply: Reply?, now: Date) -> [ClaudeReader.Event] {
        // 第一条消息的元素变了，说明切换或新建了会话：静默重新同步，不把旧回复当成新回复播放。
        // 如果最后一条回复还在生成（没有工具栏），比如新会话里的第一条回复，就按新回复处理。
        if !initialized || !sameElement(articles.first, anchor) {
            let inProgress = initialized && reply.map { !$0.hasToolbar } == true
            anchor = articles.first
            lastCount = articles.count - (inProgress ? 1 : 0)
            lastText = inProgress ? nil : reply?.text
            streaming = false
            lastChange = nil
            initialized = true
        }

        // 最后一条是用户消息时（刚发出、Claude 还没开始回复）保持原状态，等回复出现
        guard let reply else { return [] }

        var events: [ClaudeReader.Event] = []
        if articles.count > lastCount || lastText == nil {
            events.append(.started)
            if !reply.text.isEmpty {
                events.append(.appended(reply.text))
                lastChange = now
            }
            streaming = true
        } else if articles.count == lastCount, let previous = lastText, reply.text != previous {
            let added: String
            if reply.text.hasPrefix(previous) {
                added = String(reply.text.dropFirst(previous.count))
            } else {
                let lines = addedLines(previous, reply.text)
                added = lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
            }
            if !added.isEmpty { events.append(.appended(added)) }
            if !reply.text.isEmpty { lastChange = now }
            streaming = true
        }

        // 思考阶段正文为空，lastChange 还没有值，不会误判为结束
        if streaming, let changed = lastChange, reply.hasToolbar || now.timeIntervalSince(changed) >= idle {
            events.append(.finished)
            streaming = false
            lastChange = nil
        }

        lastText = reply.text
        lastCount = articles.count
        return events
    }
}
