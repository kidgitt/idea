import ApplicationServices
import Foundation

struct WatchOptions {
    /// 轮询间隔（秒）
    var interval: TimeInterval = 0.25
    /// 没等到工具栏时，文字多久不变就认为回复结束（秒）
    var idle: TimeInterval = 3
}

private func emit(_ text: String) {
    print(text, terminator: "")
    fflush(stdout)
}

private func sameElement(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return CFEqual(a, b)
    default: return false
    }
}

private func commonPrefixCount(_ a: String, _ b: String) -> Int {
    zip(a, b).prefix(while: { $0 == $1 }).count
}

/// 轮询 Claude 窗口，把最后一条回复新增的文字实时打印出来，并统计扫描耗时。
func runWatch(_ options: WatchOptions) throws {
    let (_, app) = try openClaude()
    var webArea = try findWebArea(in: app)
    var messageList: AXUIElement?
    report("开始监听，每 \(Int(options.interval * 1000))ms 读取一次。去 Claude 里提个问题试试，按 Ctrl+C 结束。")

    var lastAnchor: AXUIElement?
    var lastText: String?
    var lastCount = 0
    var initialized = false
    var streamStart: Date?
    var lastChange: Date?
    var scanTimes: [Double] = []

    func pause(since tickStart: Date) {
        let remaining = options.interval - Date().timeIntervalSince(tickStart)
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }

    while true {
        let tickStart = Date()

        // 窗口关闭或页面重建后旧元素会失效，需要重新找
        if webArea.role == nil {
            guard let found = try? findWebArea(in: app, timeout: 1) else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            webArea = found
            messageList = nil
            report("[重新定位到聊天页面]")
        }
        if messageList?.role == nil {
            messageList = findMessageList(in: webArea)
            if messageList != nil { report("[定位到消息列表]") }
        }
        guard let list = messageList else {
            pause(since: tickStart)
            continue
        }

        let articles = messageArticles(in: list)
        let row = articles.last.flatMap(replyRow(of:))
        let reply = row.map(readReply)
        let now = Date()
        scanTimes.append(now.timeIntervalSince(tickStart) * 1000)

        // 第一条消息的元素变了，说明切换了会话（或新建了会话）：静默重新同步，不把旧回复当成新回复打印。
        // 如果最后一条回复还在生成（没有工具栏），比如新会话里的第一条回复，就按新回复处理。
        let anchor = articles.first
        if !initialized || !sameElement(anchor, lastAnchor) {
            let streaming = initialized && reply.map { !$0.hasToolbar } == true
            lastAnchor = anchor
            lastCount = articles.count - (streaming ? 1 : 0)
            lastText = streaming ? nil : reply?.text
            streamStart = nil
            lastChange = nil
            let title: String = webArea.attribute(kAXTitleAttribute) ?? "?"
            if initialized {
                report("[会话变化：\(title)，共 \(articles.count) 条消息]")
            } else {
                let lastMessage = reply.map { "是回复，\($0.text.count) 字" } ?? "是你的消息"
                report("[初始] 会话：\(title)，共 \(articles.count) 条消息，最后一条\(lastMessage)")
                report(String(format: "[初始] 首次扫描耗时 %.0fms", scanTimes.last ?? 0))
                initialized = true
            }
        }

        if let reply {
            if articles.count > lastCount {
                emit("\n\n===== 新回复 =====\n" + reply.text)
                streamStart = now
                lastChange = now
            } else if articles.count < lastCount {
                report("[消息条数减少 \(lastCount) → \(articles.count)，重新同步]")
            } else if let previous = lastText, reply.text != previous {
                if reply.text.hasPrefix(previous) {
                    emit(String(reply.text.dropFirst(previous.count)))
                } else {
                    let common = commonPrefixCount(previous, reply.text)
                    emit("\n[前文变化，回退 \(previous.count - common) 字]\n" + String(reply.text.dropFirst(common)))
                }
                if streamStart == nil { streamStart = now }
                lastChange = now
            } else if lastText == nil {
                emit("\n\n===== 新回复 =====\n" + reply.text)
                streamStart = now
                lastChange = now
            }

            if let start = streamStart, let changed = lastChange,
               reply.hasToolbar || now.timeIntervalSince(changed) >= options.idle {
                let duration = max(changed.timeIntervalSince(start), 0.001)
                emit("\n")
                report(String(format: "[完成·%@] 共 %ld 字，生成用时 %.1f 秒（约 %.0f 字/秒）；本轮扫描平均 %.0fms，最慢 %.0fms",
                              reply.hasToolbar ? "工具栏出现" : "文字停止变化",
                              reply.text.count, duration, Double(reply.text.count) / duration,
                              scanTimes.reduce(0, +) / Double(scanTimes.count), scanTimes.max() ?? 0))
                streamStart = nil
                lastChange = nil
            }

            lastText = reply.text
            lastCount = articles.count
        }
        // 最后一条是用户消息时（刚发出、Claude 还没开始回复）保持原状态，等回复出现

        // 只统计回复生成期间的扫描耗时
        if streamStart == nil { scanTimes.removeAll() }
        pause(since: tickStart)
    }
}
