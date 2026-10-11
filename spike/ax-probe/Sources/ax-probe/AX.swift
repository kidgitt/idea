import AppKit
import ApplicationServices

/// Claude 桌面客户端可能的 bundle id（找不到时再按名字 "Claude" 兜底）
let claudeBundleIDs = ["com.anthropic.claudefordesktop"]

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

    /// Chromium 会把网页元素的 class / id 通过这两个非公开属性暴露出来
    var domClassList: [String] { attribute("AXDOMClassList") ?? [] }
    var domIdentifier: String? { attribute("AXDOMIdentifier") }

    /// 元素自身携带的文字（value / title / description 中第一个非空的）
    var ownText: String? {
        for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s: String = attribute(name), !s.isEmpty { return s }
        }
        return nil
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case notTrusted
    case claudeNotRunning
    case noWebArea

    var description: String {
        switch self {
        case .notTrusted:
            return "没有辅助功能权限：请到 系统设置 → 隐私与安全性 → 辅助功能，勾选你正在用的终端（Terminal / iTerm 等），然后重新运行。"
        case .claudeNotRunning:
            return "没有找到正在运行的 Claude 客户端，请先打开 Claude。"
        case .noWebArea:
            return "在 Claude 窗口里没有找到网页内容（AXWebArea）。请确认 Claude 窗口已打开且没有最小化，或用 dump 命令看看树结构。"
        }
    }
}

func ensureTrusted() throws {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(options) else { throw ProbeError.notTrusted }
}

func findClaudeApp() throws -> NSRunningApplication {
    let apps = NSWorkspace.shared.runningApplications
    if let app = apps.first(where: { claudeBundleIDs.contains($0.bundleIdentifier ?? "") }) {
        return app
    }
    if let app = apps.first(where: { $0.localizedName == "Claude" }) {
        return app
    }
    throw ProbeError.claudeNotRunning
}

/// 打开 Claude 的辅助功能树，并返回 app 元素。
/// Electron 应用默认不构建辅助功能树，需要设置 AXManualAccessibility 才会暴露网页内容。
func openClaude() throws -> (NSRunningApplication, AXUIElement) {
    try ensureTrusted()
    let app = try findClaudeApp()
    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 2.0)

    let result = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    report("Claude: pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "?")")
    report("设置 AXManualAccessibility: \(result == .success ? "成功" : "返回 \(result.rawValue)")")
    return (app, element)
}

/// 深度优先遍历。visit 返回 false 时不再进入该元素的子节点。
func walk(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 200, visit: (AXUIElement, Int) -> Bool) {
    guard depth <= maxDepth, visit(element, depth) else { return }
    for child in element.children {
        walk(child, depth: depth + 1, maxDepth: maxDepth, visit: visit)
    }
}

/// 找到 Claude 窗口里文字最多的 AXWebArea（即聊天页面）。
/// 刚打开辅助功能树时 Chromium 需要一点时间构建，所以最多重试 timeout 秒。
func findWebArea(in app: AXUIElement, timeout: TimeInterval = 5) throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(timeout)
    var best: (element: AXUIElement, size: Int)?
    repeat {
        best = nil
        for window in app.windows {
            walk(window) { element, _ in
                guard element.role == "AXWebArea" else { return true }
                let size = collectText(element).count
                if size > (best?.size ?? -1) { best = (element, size) }
                return false
            }
        }
        if let best, best.size > 0 { return best.element }
        Thread.sleep(forTimeInterval: 0.3)
    } while Date() < deadline
    // 超时后即使页面还没有文字（比如新建的空会话），也返回找到的页面
    guard let best else { throw ProbeError.noWebArea }
    return best.element
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

/// 状态信息写到 stderr，方便把 stdout 重定向到文件
func report(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}
