import AppKit
import CoreGraphics

private let claudeBundleIDs = ["com.anthropic.claudefordesktop"]

func findRunningClaude() -> NSRunningApplication? {
    let apps = NSWorkspace.shared.runningApplications
    return apps.first { claudeBundleIDs.contains($0.bundleIdentifier ?? "") }
        ?? apps.first { $0.localizedName == "Claude" }
}

/// 当前桌面（Space）上是否能看到 Claude 的窗口。
/// 窗口在别的桌面、被最小化或 Claude 没有运行时返回 false，
/// 所以不能直接用来决定是否显示，见 ClaudeSpaceTracker。
/// 只读取窗口的所属进程、层级和位置，不需要屏幕录制权限。
func claudeHasWindowOnCurrentSpace() -> Bool {
    guard let claude = findRunningClaude() else { return false }
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        // 读不到窗口列表时不隐藏，免得提词器莫名消失
        return true
    }
    return windows.contains { window in
        guard (window[kCGWindowOwnerPID as String] as? pid_t) == claude.processIdentifier,
              (window[kCGWindowLayer as String] as? Int) == 0,
              (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
        else { return false }
        // 排除 Electron 偶尔留在屏幕上的极小辅助窗口
        return bounds.width > 100 && bounds.height > 100
    }
}
