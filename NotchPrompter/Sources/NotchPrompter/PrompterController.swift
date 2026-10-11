import AppKit

/// 管理刘海面板的显示、隐藏和展开：
/// - 回复出现文字时从刘海展开，单行滚动播放
/// - 鼠标悬停时暂停；点击展开成多行，可以回看全文；鼠标移开后收起
/// - 播放完毕几秒后自动收起
/// - 切到不是 Claude 所在的桌面时收起并暂停，切回来后继续
/// - 文字下方显示进度条，刘海右侧显示剩余时间；悬停时刘海左侧出现"跳到最新"按钮
final class PrompterController: NSObject {
    var charsPerSecond: Double {
        get { ticker.charsPerSecond }
        set { ticker.charsPerSecond = newValue }
    }

    var isUserPaused = false {
        didSet { updatePause() }
    }

    /// 显示框宽度（pt）。实际宽度不会窄于刘海，也不会超出屏幕
    private(set) var preferredWidth: CGFloat = 480

    /// 当前不在 Claude 所在的桌面时为 true：收起面板、暂停播放，切回来后从暂停处继续
    var isSuspended = false {
        didSet {
            if isSuspended != oldValue { applySuspension() }
        }
    }

    /// "测试滚动"不依赖 Claude，不受所在桌面影响
    private var ignoresSuspension = false
    private var isEffectivelySuspended: Bool { isSuspended && !ignoresSuspension }

    private let panel = NotchPanel()
    private let content = NotchContentView()
    private let ticker = TickerView()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let progressLine = ProgressLineView()
    private let remainingLabel = NSTextField(labelWithString: "")
    private let jumpButton = FirstMouseButton()

    private let tickerHeight: CGFloat = 32
    private let expandedHeight: CGFloat = 220
    private let hideDelay: TimeInterval = 2.5

    /// 保留换行的全文，用于展开后回看
    private var fullText = ""
    private var isExpanded = false
    private var isHovering = false
    private var isDrained = false
    private var hideWork: DispatchWorkItem?
    /// 刘海两侧是否有足够空间放剩余时间和"跳到最新"按钮
    private var hasRoomBesideNotch = false

    override init() {
        super.init()
        panel.contentView = content
        content.addSubview(ticker)
        content.addSubview(scrollView)
        content.addSubview(progressLine)
        content.addSubview(remainingLabel)
        content.addSubview(jumpButton)

        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        remainingLabel.textColor = NSColor.white.withAlphaComponent(0.6)

        jumpButton.title = "跳到最新"
        jumpButton.image = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil)
        jumpButton.imagePosition = .imageLeading
        jumpButton.isBordered = false
        jumpButton.font = .systemFont(ofSize: 11, weight: .medium)
        jumpButton.contentTintColor = .white
        jumpButton.target = self
        jumpButton.action = #selector(jumpButtonClicked)
        jumpButton.isHidden = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .white
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.isHidden = true

        ticker.onProgress = { [weak self] progress in self?.updateProgress(progress) }
        ticker.onDrained = { [weak self] in
            self?.isDrained = true
            self?.scheduleHide()
        }
        content.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            isHovering = hovering
            updateJumpButton()
            if !hovering {
                setExpanded(false)
                if isDrained { scheduleHide() }
            }
            updatePause()
        }
        content.onClick = { [weak self] in self?.setExpanded(true) }
    }

    // MARK: - 回复事件

    func beginReply(isTest: Bool = false) {
        cancelHide()
        fullText = ""
        textView.string = ""
        ticker.reset()
        isDrained = false
        if ignoresSuspension != isTest {
            ignoresSuspension = isTest
            applySuspension()
        }
    }

    func append(_ text: String) {
        fullText += text
        textView.string = fullText
        if isExpanded { textView.scrollToEndOfDocument(nil) }
        // 块与块之间用全角空格隔开，在一行里也能看出分段
        ticker.append(text.replacingOccurrences(of: "\n", with: "\u{3000}"))
        isDrained = false
        show()
    }

    func endReply() {
        ticker.markComplete()
    }

    /// 修改宽度。preview 为 true 且当前没有在播放时，短暂显示面板预览新宽度
    func setPreferredWidth(_ width: CGFloat, preview: Bool) {
        preferredWidth = width
        if panel.isVisible {
            applyLayout()
        } else if preview {
            show(force: true)
        }
        if preview && (isDrained || fullText.isEmpty) { scheduleHide() }
    }

    /// 跳过积压的内容，直接播放最新的文字
    func jumpToLatest() {
        ticker.jumpToLatest()
        if isExpanded { textView.scrollToEndOfDocument(nil) }
    }

    @objc private func jumpButtonClicked() {
        jumpToLatest()
    }

    // MARK: - 进度

    private func updateProgress(_ progress: TickerProgress) {
        progressLine.fraction = progress.fraction
        let text: String
        if fullText.isEmpty {
            text = ""
        } else if progress.isPaused {
            text = "已暂停"
        } else if progress.remaining >= 1 {
            let seconds = Int(progress.remaining.rounded())
            // 回复还在生成时加"+"：后面还会有新文字，实际剩余会更长
            text = String(format: "剩余 %ld:%02ld", seconds / 60, seconds % 60) + (progress.isComplete ? "" : "+")
        } else {
            // 已追上 Claude 的输出，等新文字
            text = progress.isComplete ? "" : "等待中"
        }
        if remainingLabel.stringValue != text { remainingLabel.stringValue = text }
    }

    private func updateJumpButton() {
        jumpButton.isHidden = !(isHovering && hasRoomBesideNotch)
    }

    // MARK: - 显示与隐藏

    private func applySuspension() {
        updatePause()
        if isEffectivelySuspended {
            cancelHide()
            // 面板直接收起时收不到鼠标移出事件，手动清掉悬停状态，免得回来后一直暂停
            isHovering = false
            updateJumpButton()
            setExpanded(false)
            panel.orderOut(nil)
            updatePause()
        } else if !isDrained && !fullText.isEmpty {
            show()
        }
    }

    /// force：预览宽度时即使 Claude 不在当前桌面也显示
    private func show(force: Bool = false) {
        guard force || !isEffectivelySuspended else { return }
        cancelHide()
        if panel.isVisible && panel.alphaValue == 1 { return }
        applyLayout()
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // 动画期间如果又有新文字，show() 会把透明度改回 1，这时不要隐藏
            guard let self, panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
            setExpanded(false)
        })
    }

    private func scheduleHide() {
        cancelHide()
        guard !isHovering, !isExpanded else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        ticker.isHidden = expanded
        progressLine.isHidden = expanded
        scrollView.isHidden = !expanded
        applyLayout()
        if expanded {
            cancelHide()
            textView.scrollToEndOfDocument(nil)
        }
        updatePause()
    }

    private func updatePause() {
        ticker.isPaused = isUserPaused || isHovering || isExpanded || isEffectivelySuspended
    }

    // MARK: - 布局

    /// 优先选带刘海的屏幕；外接显示器没有刘海时，贴在菜单栏下沿
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func applyLayout() {
        guard let screen = targetScreen() else { return }
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : frame.maxY - screen.visibleFrame.maxY

        var notchWidth: CGFloat = 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = frame.width - left.width - right.width
        }
        let maxWidth = frame.width - 40
        let collapsedWidth = min(max(preferredWidth, notchWidth + 40), maxWidth)
        let width = isExpanded ? min(max(collapsedWidth, 520), maxWidth) : collapsedWidth
        let bodyHeight = isExpanded ? expandedHeight : tickerHeight
        let height = topInset + bodyHeight

        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height), display: true)
        content.needsDisplay = true
        // 内容区在刘海下方（坐标原点在左下角）
        ticker.frame = NSRect(x: 16, y: 2, width: width - 32, height: tickerHeight - 2)
        progressLine.frame = NSRect(x: 20, y: 3, width: width - 40, height: 2)
        scrollView.frame = NSRect(x: 12, y: 10, width: width - 24, height: bodyHeight - 14)
        textView.frame.size.width = scrollView.contentSize.width

        // 刘海两侧（菜单栏那一行）：右边放剩余时间，左边放"跳到最新"按钮
        let sideWidth = (width - notchWidth) / 2 - 16
        hasRoomBesideNotch = sideWidth >= 64
        let buttonWidth = min(sideWidth, 84)
        remainingLabel.frame = NSRect(x: width / 2 + notchWidth / 2 + 8, y: bodyHeight + (topInset - 14) / 2,
                                      width: max(sideWidth - 4, 0), height: 14)
        jumpButton.frame = NSRect(x: width / 2 - notchWidth / 2 - 8 - buttonWidth, y: bodyHeight + (topInset - 20) / 2,
                                  width: buttonWidth, height: 20)
        remainingLabel.isHidden = !hasRoomBesideNotch
        updateJumpButton()
    }
}
