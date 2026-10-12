import AppKit
import CoreGraphics

private let claudeBundleIDs = ["com.anthropic.claudefordesktop"]

func findRunningClaude() -> NSRunningApplication? {
    let apps = NSWorkspace.shared.runningApplications
    return apps.first { claudeBundleIDs.contains($0.bundleIdentifier ?? "") }
        ?? apps.first { $0.localizedName == "Claude" }
}

/// Claude 基于 Chromium。窗口最小化或被其他窗口完全挡住时，Chromium 默认会暂停刷新页面，
/// 回复不再更新，提词器也就读不到新内容。带上这些启动参数可以关掉这种暂停。
private let noBackgroundPauseArguments = [
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
    "--disable-background-timer-throttling",
]

struct ClaudeRelaunchError: LocalizedError {
    var errorDescription: String?
}

/// 退出 Claude，再带上 noBackgroundPauseArguments 重新打开。Claude 没在运行时直接打开。
func relaunchClaudeWithoutBackgroundPause(completion: @escaping (Error?) -> Void) {
    let running = findRunningClaude()
    let installed = claudeBundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    guard let url = running?.bundleURL ?? installed else {
        completion(ClaudeRelaunchError(errorDescription: "没有找到 Claude 应用。"))
        return
    }

    func launch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = noBackgroundPauseArguments
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    guard let running else {
        launch()
        return
    }
    running.terminate()
    // 等 Claude 完全退出再打开，否则只会把旧进程切到前台，参数不会生效
    let deadline = Date().addingTimeInterval(10)
    func waitForExit() {
        if running.isTerminated {
            launch()
        } else if Date() > deadline {
            completion(ClaudeRelaunchError(errorDescription: "Claude 没有在 10 秒内退出，请手动退出后再试。"))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitForExit() }
        }
    }
    waitForExit()
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
