import ApplicationServices

/// 把 Claude 窗口的辅助功能树打印出来，用来人工确认回复文字在哪个节点、带什么 class。
func runDump(maxDepth: Int, maxNodes: Int) throws {
    let (_, app) = try openClaude()
    // 先等网页内容就绪，否则刚打开辅助功能树时可能只能看到空壳
    _ = try? findWebArea(in: app)

    var count = 0
    for window in app.windows {
        walk(window, maxDepth: maxDepth) { element, depth in
            guard count < maxNodes else { return false }
            count += 1
            print(describe(element, depth: depth))
            return true
        }
    }
    report("共输出 \(count) 个节点\(count >= maxNodes ? "（已达上限 --max-nodes \(maxNodes)，后面被截断）" : "")")
}

func describe(_ element: AXUIElement, depth: Int) -> String {
    var line = String(repeating: "  ", count: depth) + (element.role ?? "?")
    if let subrole = element.subrole { line += " [\(subrole)]" }
    if let id = element.domIdentifier, !id.isEmpty { line += " #\(id)" }
    let classes = element.domClassList
    if !classes.isEmpty { line += " ." + classes.joined(separator: ".") }
    if let text = element.ownText {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        line += " \"\(flat.count > 80 ? String(flat.prefix(80)) + "…" : flat)\""
    }
    return line
}
