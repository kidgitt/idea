import ApplicationServices
import Foundation

struct WatchOptions {
    /// 回复消息元素的 class 中包含的片段，用来区分 Claude 的回复和用户的消息
    var classHint = "font-claude"
    /// 轮询间隔（秒）
    var interval: TimeInterval = 0.25
    /// 文字多久不变就认为本次回复结束（秒）
    var idle: TimeInterval = 1.5
}

private struct Snapshot {
    /// 找到的回复条数；兜底模式下为 0
    var messageCount: Int
    /// 最后一条回复的文字；兜底模式下为整个页面的文字
    var text: String
    var fallback: Bool
}

private func takeSnapshot(_ webArea: AXUIElement, classHint: String) -> Snapshot {
    var messages: [AXUIElement] = []
    walk(webArea) { element, _ in
        if element.domClassList.contains(where: { $0.contains(classHint) }) {
            messages.append(element)
            return false
        }
        return true
    }
    if let last = messages.last {
        return Snapshot(messageCount: messages.count, text: collectText(last), fallback: false)
    }
    return Snapshot(messageCount: 0, text: collectText(webArea), fallback: true)
}

private func emit(_ text: String) {
    print(text, terminator: "")
    fflush(stdout)
}

private func commonPrefixCount(_ a: String, _ b: String) -> Int {
    zip(a, b).prefix(while: { $0 == $1 }).count
}

/// 轮询 Claude 窗口，把最后一条回复新增的文字实时打印出来，并统计扫描耗时。
func runWatch(_ options: WatchOptions) throws {
    let (_, app) = try openClaude()
    var webArea = try findWebArea(in: app)
    report("开始监听，每 \(Int(options.interval * 1000))ms 读取一次。去 Claude 里提个问题试试，按 Ctrl+C 结束。")

    var lastText: String?
    var lastCount = 0
    var fallback: Bool?
    var streamStart: Date?
    var lastChange: Date?
    var scanTimes: [Double] = []

    while true {
        let tickStart = Date()

        // 窗口关闭或页面重建后旧元素会失效，需要重新找
        if webArea.role == nil {
            guard let found = try? findWebArea(in: app, timeout: 1) else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            webArea = found
            report("[重新定位到聊天页面]")
        }

        let snap = takeSnapshot(webArea, classHint: options.classHint)
        let now = Date()
        scanTimes.append(now.timeIntervalSince(tickStart) * 1000)

        if fallback != snap.fallback {
            fallback = snap.fallback
            report(snap.fallback
                ? "[兜底模式] 没找到 class 含 \"\(options.classHint)\" 的元素，改为监听整个页面的文字。请用 dump 找到回复元素的 class，再用 --class 指定。"
                : "[精确模式] 通过 class \"\(options.classHint)\" 找到 \(snap.messageCount) 条回复。")
        }

        if let previous = lastText {
            if snap.messageCount < lastCount {
                report("[回复条数减少 \(lastCount) → \(snap.messageCount)，可能切换了会话，重新开始]")
                streamStart = nil
                lastChange = nil
            } else if snap.messageCount > lastCount {
                emit("\n\n===== 新回复 =====\n" + snap.text)
                streamStart = now
                lastChange = now
            } else if snap.text != previous {
                if snap.text.hasPrefix(previous) {
                    emit(String(snap.text.dropFirst(previous.count)))
                } else {
                    let common = commonPrefixCount(previous, snap.text)
                    emit("\n[前文变化，回退 \(previous.count - common) 字]\n" + String(snap.text.dropFirst(common)))
                }
                if streamStart == nil { streamStart = now }
                lastChange = now
            } else if let start = streamStart, let changed = lastChange, now.timeIntervalSince(changed) >= options.idle {
                let duration = max(changed.timeIntervalSince(start), 0.001)
                emit("\n")
                report(String(format: "[完成] 共 %ld 字，生成用时 %.1f 秒（约 %.0f 字/秒）；本轮扫描平均 %.0fms，最慢 %.0fms",
                           snap.text.count, duration, Double(snap.text.count) / duration,
                           scanTimes.reduce(0, +) / Double(scanTimes.count), scanTimes.max() ?? 0))
                streamStart = nil
                lastChange = nil
            }
        } else {
            let preview = snap.text.suffix(60).replacingOccurrences(of: "\n", with: "⏎")
            report("[初始] 最后一条已有 \(snap.text.count) 字，结尾：…\(preview)")
            report(String(format: "[初始] 首次扫描耗时 %.0fms", scanTimes.last ?? 0))
        }

        lastText = snap.text
        lastCount = snap.messageCount
        // 只统计回复生成期间的扫描耗时
        if streamStart == nil { scanTimes.removeAll() }

        let remaining = options.interval - Date().timeIntervalSince(tickStart)
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }
}
