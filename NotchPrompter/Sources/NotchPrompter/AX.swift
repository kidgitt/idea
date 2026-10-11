import AppKit
import ApplicationServices

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var role: String? { attribute(kAXRoleAttribute) }
    var subrole: String? { attribute(kAXSubroleAttribute) }
    var children: [AXUIElement] { attribute(kAXChildrenAttribute) ?? [] }
    var windows: [AXUIElement] { attribute(kAXWindowsAttribute) ?? [] }

    /// Chromium 通过这个非公开属性暴露网页元素的 class
    var domClassList: [String] { attribute("AXDOMClassList") ?? [] }
}

func sameElement(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return CFEqual(a, b)
    default: return false
    }
}

/// 深度优先遍历。visit 返回 false 时不再进入该元素的子节点。
func walk(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 200, visit: (AXUIElement, Int) -> Bool) {
    guard depth <= maxDepth, visit(element, depth) else { return }
    for child in element.children {
        walk(child, depth: depth + 1, maxDepth: maxDepth, visit: visit)
    }
}

/// 按文档顺序拼接元素下所有 AXStaticText 的文字
func collectText(_ root: AXUIElement) -> String {
    var parts: [String] = []
    walk(root) { element, _ in
        if element.role == "AXStaticText", let text: String = element.attribute(kAXValueAttribute) {
            parts.append(text)
        }
        return true
    }
    return parts.joined()
}

/// Claude 窗口里文字最多的 AXWebArea（即聊天页面）
func findWebArea(in app: AXUIElement) -> AXUIElement? {
    var best: (element: AXUIElement, size: Int)?
    for window in app.windows {
        walk(window) { element, _ in
            guard element.role == "AXWebArea" else { return true }
            let size = collectText(element).count
            if size > (best?.size ?? -1) { best = (element, size) }
            return false
        }
    }
    return best?.element
}
