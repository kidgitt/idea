import AppKit

/// 管理刘海面板的显示、隐藏和展开：
/// - 回复出现文字时从刘海展开，单行滚动播放
/// - 鼠标悬停时暂停；点击展开成多行，可以回看全文；单击全文中的文字从该处继续播放；鼠标移开后收起
/// - 播放完毕几秒后自动收起
/// - 切到不是 Claude 所在的桌面时收起并暂停，切回来后继续
/// - 文字下方的状态行：进度条和剩余时间；悬停时左侧出现"跳到最新"按钮
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

    /// 当前桌面上能否看到 Claude 窗口。Claude 最小化后通常会暂停刷新页面，读不到新内容，状态行据此提示
    var isClaudeWindowVisible = true

    /// "测试滚动"不依赖 Claude，不受所在桌面影响
    private var ignoresSuspension = false
    private var isEffectivelySuspended: Bool { isSuspended && !ignoresSuspension }

    private let panel = NotchPanel()
    private let content = NotchContentView()
    private let ticker = TickerView()
    private let scrollView = NSScrollView()
    private let textView = ClickableTextView()
    private let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.white,
    ]
    private let progressLine = ProgressLineView()
    private let remainingLabel = NSTextField(labelWithString: "")
    private let jumpButton = FirstMouseButton()

    private let textRowHeight: CGFloat = 30
    /// 文字下方的状态行：进度条、剩余时间、"跳到最新"按钮
    private let statusRowHeight: CGFloat = 16
    private var collapsedHeight: CGFloat { textRowHeight + statusRowHeight }
    private let expandedHeight: CGFloat = 220
    private let hideDelay: TimeInterval = 2.5

    /// 保留换行的全文，用于展开后回看
    private var fullText = ""
    private var isExpanded = false
    private var isHovering = false
    private var isDrained = false
    private var hideWork: DispatchWorkItem?

    override init() {
        super.init()
        panel.contentView = content
        content.addSubview(ticker)
        content.addSubview(scrollView)
        content.addSubview(progressLine)
        content.addSubview(remainingLabel)
        content.addSubview(jumpButton)

        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        remainingLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        remainingLabel.alignment = .right

        jumpButton.title = "跳到最新"
        jumpButton.image = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil)
        jumpButton.imagePosition = .imageLeading
        jumpButton.isBordered = false
        jumpButton.font = .systemFont(ofSize: 10, weight: .medium)
        jumpButton.contentTintColor = .white
        jumpButton.target = self
        jumpButton.action = #selector(jumpButtonClicked)
        jumpButton.isHidden = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.typingAttributes = textAttributes
        textView.onClickCharacter = { [weak self] index in self?.play(fromUTF16Index: index) }
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
        // 追加而不是整体替换，保留展开时已播放部分的变暗效果；展开时也不自动滚动，免得打断选择位置
        textView.textStorage?.append(NSAttributedString(string: text, attributes: textAttributes))
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
        if isExpanded { showPlaybackPosition() }
    }

    @objc private func jumpButtonClicked() {
        jumpToLatest()
    }

    /// 单击全文中的文字：收起全文，从该处继续播放
    private func play(fromUTF16Index index: Int) {
        ticker.jump(toUTF16Index: index)
        cancelHide()
        isDrained = false
        // 鼠标此时还在面板上。不把它算作悬停，让播放立即继续；移开再移回来才会重新暂停
        isHovering = false
        setExpanded(false)
        updateJumpButton()
        updatePause()
    }

    /// 展开全文时：已播放的部分变暗，并滚动到当前播放位置
    private func showPlaybackPosition() {
        guard let storage = textView.textStorage else { return }
        let position = min(ticker.currentUTF16Index, storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: storage.length))
        storage.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.4),
                             range: NSRange(location: 0, length: position))
        storage.endEditing()
        textView.scrollRangeToVisible(NSRange(location: position, length: 0))
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
            text = progress.isComplete ? "" : (isClaudeWindowVisible ? "等待中" : "Claude 窗口未显示")
        }
        if remainingLabel.stringValue != text { remainingLabel.stringValue = text }
    }

    private func updateJumpButton() {
        jumpButton.isHidden = !(isHovering && !isExpanded)
        layoutStatusRow()
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
        remainingLabel.isHidden = expanded
        scrollView.isHidden = !expanded
        applyLayout()
        if expanded {
            cancelHide()
            showPlaybackPosition()
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
        let bodyHeight = isExpanded ? expandedHeight : collapsedHeight
        let height = topInset + bodyHeight

        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height), display: true)
        content.needsDisplay = true
        // 内容区在刘海下方（坐标原点在左下角）
        // 滚动文字始终按收起时的宽度布局：展开时它被隐藏，宽度不变，收起后文字位置才不会错开
        ticker.frame = NSRect(x: 16, y: statusRowHeight, width: collapsedWidth - 32, height: textRowHeight)
        scrollView.frame = NSRect(x: 12, y: 10, width: width - 24, height: bodyHeight - 14)
        textView.frame.size.width = scrollView.contentSize.width
        updateJumpButton()
    }

    /// 状态行：左边是"跳到最新"按钮（仅悬停时），中间是进度条，右边是剩余时间
    private func layoutStatusRow() {
        let width = content.bounds.width
        let labelWidth: CGFloat = 110
        let buttonWidth: CGFloat = 76
        jumpButton.frame = NSRect(x: 14, y: 1, width: buttonWidth, height: 14)
        remainingLabel.frame = NSRect(x: width - 16 - labelWidth, y: 2, width: labelWidth, height: 12)
        let lineStart: CGFloat = jumpButton.isHidden ? 20 : jumpButton.frame.maxX + 6
        progressLine.frame = NSRect(x: lineStart, y: 7, width: max(remainingLabel.frame.minX - 8 - lineStart, 0), height: 2)
    }
}
