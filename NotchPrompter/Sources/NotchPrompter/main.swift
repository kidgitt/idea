import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 只显示菜单栏图标，不出现在 Dock 和 Cmd+Tab 里
app.setActivationPolicy(.accessory)
app.run()
