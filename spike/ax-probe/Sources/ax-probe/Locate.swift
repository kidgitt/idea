import ApplicationServices

/// 找到文字包含 needle 的元素，打印它的祖先链，以及往上 context 层那个祖先的子树。
/// 只输出最后 maxMatches 个匹配（最新的消息在最后）。
func runLocate(_ needle: String, maxMatches: Int, context: Int) throws {
    let (_, app) = try openClaude()
    _ = try? findWebArea(in: app)

    var matches: [[AXUIElement]] = []
    var path: [AXUIElement] = []

    func search(_ element: AXUIElement) {
        guard path.count < 200 else { return }
        path.append(element)
        defer { path.removeLast() }
        if let text = element.ownText, text.contains(needle) {
            matches.append(path)
        }
        for child in element.children { search(child) }
    }
    for window in app.windows { search(window) }

    report("共找到 \(matches.count) 处包含 \"\(needle)\"，下面输出最后 \(min(maxMatches, matches.count)) 处")
    for (index, chain) in matches.suffix(maxMatches).enumerated() {
        print("===== 匹配 \(index + 1)：祖先链 =====")
        for (depth, ancestor) in chain.enumerated() {
            print(describe(ancestor, depth: depth))
        }

        let rootDepth = max(chain.count - 1 - context, 0)
        print("===== 匹配 \(index + 1)：往上 \(chain.count - 1 - rootDepth) 层的子树 =====")
        var count = 0
        walk(chain[rootDepth]) { element, depth in
            guard count < 150 else { return false }
            count += 1
            print(describe(element, depth: depth))
            return true
        }
        if count >= 150 { print("…（子树超过 150 个节点，已截断）") }
    }
}
