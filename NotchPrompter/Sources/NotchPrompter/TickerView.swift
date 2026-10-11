import AppKit
import CoreText
import QuartzCore

/// 单行横向滚动的文字：从右侧进入，向左移动。
/// 回复还在生成时，滚到已有文字的末尾就停下等待；回复结束后整段滚出左侧，然后回调 onDrained。
final class TickerView: NSView {
    /// 播放速度：每秒滚过的字数
    var charsPerSecond: Double = 7
    var isPaused = false
    var onDrained: (() -> Void)?

    private let font = NSFont.systemFont(ofSize: 15, weight: .medium)
    private var text = ""
    private var charCount = 0
    private var line: CTLine?
    private var lineWidth: CGFloat = 0
    /// 文字已向左移动的距离；文字起点的 x = bounds.width - offset
    private var offset: CGFloat = 0
    private var isComplete = false
    private var hasDrained = false
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private let fadeMask = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 左右两端渐隐
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.06, 0.94, 1]
        layer?.mask = fadeMask
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        fadeMask.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        link = displayLink(target: self, selector: #selector(step(_:)))
        link?.add(to: .main, forMode: .common)
    }

    func reset() {
        text = ""
        charCount = 0
        line = nil
        lineWidth = 0
        offset = 0
        isComplete = false
        hasDrained = false
        needsDisplay = true
    }

    func append(_ newText: String) {
        guard !newText.isEmpty else { return }
        text += newText
        charCount = text.count
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor,
        ]
        let newLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        line = newLine
        lineWidth = CGFloat(CTLineGetTypographicBounds(newLine, nil, nil, nil))
        hasDrained = false
        needsDisplay = true
    }

    /// 回复已结束，可以把剩下的文字全部滚出去
    func markComplete() {
        isComplete = true
        hasDrained = false
    }

    @objc private func step(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let last = lastTimestamp, !isPaused, charCount > 0 else { return }

        let limit = isComplete ? lineWidth + bounds.width : lineWidth
        guard offset < limit else {
            if isComplete && !hasDrained {
                hasDrained = true
                onDrained?()
            }
            return
        }
        // 按字数换算速度，中英文混排时每秒滚过的字数也大致一致
        let pointsPerChar = lineWidth / CGFloat(charCount)
        let elapsed = min(link.timestamp - last, 0.1)
        offset = min(offset + CGFloat(charsPerSecond * elapsed) * pointsPerChar, limit)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let line, let context = NSGraphicsContext.current?.cgContext else { return }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: bounds.width - offset, y: (bounds.height - ascent - descent) / 2 + descent)
        CTLineDraw(line, context)
    }
}
