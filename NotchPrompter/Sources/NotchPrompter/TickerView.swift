import AppKit
import CoreText
import QuartzCore

struct TickerProgress {
    /// 已播放的比例：文字末尾进入可视区域时为 1
    var fraction: Double
    /// 按当前速度，文字末尾还要多久进入可视区域
    var remaining: TimeInterval
    /// 回复已结束；为 false 时后面还会有新文字
    var isComplete: Bool
    var isPaused: Bool
}

/// 单行横向滚动的文字：从右侧进入，向左移动。
/// 回复还在生成时，滚到已有文字的末尾就停下等待；回复结束后整段滚出左侧，然后回调 onDrained。
final class TickerView: NSView {
    /// 播放速度：每秒滚过的字数
    var charsPerSecond: Double = 7
    var isPaused = false {
        didSet { if isPaused != oldValue { reportProgress() } }
    }
    var onDrained: (() -> Void)?
    /// 每帧位置变化或状态变化时回调，用于显示进度
    var onProgress: ((TickerProgress) -> Void)?

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
    /// 阅读位置：可视区域从左往右 15% 处。点击全文跳转时，把目标文字放在这里
    private let readingPoint: CGFloat = 0.15

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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 宽度可调，渐隐遮罩跟着变；关掉隐式动画，避免遮罩落后于文字
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        CATransaction.commit()
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
        reportProgress()
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
        reportProgress()
    }

    /// 回复已结束，可以把剩下的文字全部滚出去
    func markComplete() {
        isComplete = true
        hasDrained = false
        reportProgress()
    }

    /// 跳过积压的内容：让最新的文字铺满可视区域（文字末尾对齐右边缘），之后照常播放
    func jumpToLatest() {
        guard charCount > 0, offset < lineWidth else { return }
        offset = lineWidth
        needsDisplay = true
        reportProgress()
    }

    /// 当前阅读位置对应的文字下标（UTF-16），展开全文时用来定位
    var currentUTF16Index: Int {
        guard let line else { return 0 }
        let localX = offset - bounds.width * (1 - readingPoint)
        guard localX > 0 else { return 0 }
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: localX, y: 0))
        return index == kCFNotFound ? 0 : index
    }

    /// 从第 index 个字符（UTF-16 下标）处继续播放：把它放到阅读位置，可以往回也可以往前
    func jump(toUTF16Index index: Int) {
        guard let line, charCount > 0 else { return }
        let x = CTLineGetOffsetForStringIndex(line, index, nil)
        let limit = isComplete ? lineWidth + bounds.width : lineWidth
        offset = min(max(x + bounds.width * (1 - readingPoint), 0), limit)
        hasDrained = false
        needsDisplay = true
        reportProgress()
    }

    private func reportProgress() {
        guard let onProgress else { return }
        guard charCount > 0, lineWidth > 0 else {
            onProgress(TickerProgress(fraction: 0, remaining: 0, isComplete: isComplete, isPaused: isPaused))
            return
        }
        let pointsPerSecond = lineWidth / CGFloat(charCount) * CGFloat(charsPerSecond)
        let remaining = pointsPerSecond > 0 ? max(lineWidth - offset, 0) / pointsPerSecond : 0
        onProgress(TickerProgress(fraction: Double(min(offset / lineWidth, 1)), remaining: TimeInterval(remaining),
                                  isComplete: isComplete, isPaused: isPaused))
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
        reportProgress()
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
