import AppKit

/// 记住 Claude 所在的桌面（Space），判断当前是不是在这个桌面上。
///
/// macOS 没有公开接口查询某个窗口在哪个桌面。这里放一个看不见的 1×1 标记窗口：
/// 每当在当前桌面看到 Claude 的窗口，就把标记移到当前桌面；之后用 NSWindow.isOnActiveSpace
/// 判断当前桌面是不是标记所在的桌面。这样 Claude 最小化或隐藏后，
/// 只要用户还在原来的桌面，仍然算作 Claude 所在的桌面。
final class ClaudeSpaceTracker {
    private let marker: NSWindow
    private var hasHome = false
    private var consecutiveSightings = 0

    init() {
        marker = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                          styleMask: .borderless, backing: .buffered, defer: false)
        marker.isOpaque = false
        marker.backgroundColor = .clear
        marker.hasShadow = false
        marker.ignoresMouseEvents = true
        marker.isReleasedWhenClosed = false
        // 允许进入全屏应用的桌面，Claude 全屏时也能记住
        marker.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    }

    /// 当前桌面是否是 Claude 所在的桌面；还没见过 Claude 窗口时返回 true，不做限制
    var isOnClaudeSpace: Bool {
        !hasHome || marker.isOnActiveSpace
    }

    /// 定时调用。连续两次在当前桌面看到 Claude 窗口，才把标记移过来：
    /// 刚切换桌面时窗口列表可能还是旧桌面的，只看一次容易把标记移错
    func update() {
        consecutiveSightings = claudeHasWindowOnCurrentSpace() ? consecutiveSightings + 1 : 0
        guard consecutiveSightings >= 2, !hasHome || !marker.isOnActiveSpace else { return }
        // 先收起再显示，窗口会被放到当前桌面
        marker.orderOut(nil)
        marker.orderFrontRegardless()
        hasHome = true
    }

    /// 切换桌面时调用，丢掉切换前的观察结果
    func activeSpaceDidChange() {
        consecutiveSightings = 0
    }
}
