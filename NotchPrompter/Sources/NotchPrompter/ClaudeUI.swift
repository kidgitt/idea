import ApplicationServices
import Foundation

// Claude 桌面客户端聊天页面的辅助功能树结构（用 spike/ax-probe 实测）：
//
// AXWebArea "长沙介绍 - Claude"
//   … AXGroup [AXApplicationGroup] "对话消息"        消息列表
//       … AXGroup [AXDocumentArticle] "第 N 条消息"  每条消息一个
//           用户消息：AXHeading .sr-only "您说：…" + 气泡
//           Claude 回复：
//           AXGroup .group/message-row
//             AXHeading .sr-only "Claude 已回复：…"   读屏摘要，跳过
//             AXGroup .focus-visible:…               思考过程标题，跳过
//             AXGroup [AXApplicationStatus] .sr-only 状态播报，跳过
//             AXGroup                                正文
//             AXToolbar "消息操作"                   复制/重试等按钮，回复结束后出现

/// 消息列表：从第一条消息往上找 AXApplicationGroup
func findMessageList(in webArea: AXUIElement) -> AXUIElement? {
    var firstArticle: AXUIElement?
    walk(webArea) { element, _ in
        guard firstArticle == nil else { return false }
        if element.subrole == "AXDocumentArticle" {
            firstArticle = element
            return false
        }
        return true
    }
    var current = firstArticle
    while let element = current {
        if element.subrole == "AXApplicationGroup" { return element }
        current = element.attribute(kAXParentAttribute)
    }
    return nil
}

/// 列表中的所有消息（不进入消息内部）
func messageArticles(in list: AXUIElement) -> [AXUIElement] {
    var articles: [AXUIElement] = []
    walk(list) { element, _ in
        if element.subrole == "AXDocumentArticle" {
            articles.append(element)
            return false
        }
        return true
    }
    return articles
}

/// Claude 回复的主体；用户消息没有这一层，返回 nil
func replyRow(of article: AXUIElement) -> AXUIElement? {
    article.children.first { $0.domClassList.contains("group/message-row") }
}

struct Reply {
    /// 正文，块与块之间用换行分隔
    var text: String
    /// 已出现"消息操作"工具栏，即回复结束
    var hasToolbar: Bool
}

/// 读取回复正文，跳过读屏摘要、思考过程标题、状态播报和按钮
func readReply(_ row: AXUIElement) -> Reply {
    var lines: [String] = []
    var hasToolbar = false
    for child in row.children {
        if child.role == "AXToolbar" {
            hasToolbar = true
            continue
        }
        let classes = child.domClassList
        if classes.contains("sr-only") || classes.contains(where: { $0.hasPrefix("focus-visible:") }) { continue }
        lines += readableLines(child)
    }
    return Reply(text: lines.joined(separator: "\n"), hasToolbar: hasToolbar)
}

/// 卡片、图片等富内容加载时的占位文字，不属于正文
private let placeholderLines: Set<String> = ["加载中", "图片不可用", "Loading", "Image unavailable"]

private func isPlaceholder(_ line: String) -> Bool {
    placeholderLines.contains(line.trimmingCharacters(in: CharacterSet(charactersIn: ".…")))
}

/// 按块拆行：连续的文字和链接拼成一行，遇到其他容器（段落、列表项、标题等）就换行
private func readableLines(_ root: AXUIElement) -> [String] {
    var lines: [String] = []
    var current = ""

    func flush() {
        let line = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty && !isPlaceholder(line) { lines.append(line) }
        current = ""
    }

    func visit(_ element: AXUIElement) {
        if element.domClassList.contains("sr-only") { return }
        switch element.role ?? "" {
        case "AXStaticText":
            if let text: String = element.attribute(kAXValueAttribute) { current += text }
        case "AXButton", "AXCheckBox", "AXToolbar", "AXImage":
            return
        case "AXLink":
            for child in element.children { visit(child) }
        default:
            flush()
            for child in element.children { visit(child) }
            flush()
        }
    }

    visit(root)
    flush()
    return lines
}

/// current 中不在 previous 里的行（按出现次数计）。
/// 卡片等富内容常在正文之后才渲染、插到前面，这时只取新出现的行，避免重复播放整段。
func addedLines(_ previous: String, _ current: String) -> [String] {
    var seen: [Substring: Int] = [:]
    for line in previous.split(separator: "\n") { seen[line, default: 0] += 1 }
    return current.split(separator: "\n").compactMap { line in
        if let count = seen[line], count > 0 {
            seen[line] = count - 1
            return nil
        }
        return String(line)
    }
}
