import AppKit

/// 贴在屏幕顶部正中、盖住刘海的无边框面板，不抢焦点，在所有桌面和全屏应用上方显示
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 默认会把窗口挪到菜单栏下面，这里允许它覆盖刘海所在的菜单栏区域
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 面板内容：黑色背景（顶部与屏幕边缘齐平，底部圆角），并处理悬停和点击
final class NotchContentView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private let cornerRadius: CGFloat = 14
    private var trackingArea: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius = min(cornerRadius, r.height / 2, r.width / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX, y: r.maxY))
        path.line(to: NSPoint(x: r.minX, y: r.minY + radius))
        path.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
        path.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: r.maxX, y: r.maxY))
        path.close()
        NSColor.black.setFill()
        path.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
