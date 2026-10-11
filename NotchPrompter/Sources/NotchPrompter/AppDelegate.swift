import AppKit

/// 菜单栏图标和菜单：连接状态、播放速度、显示宽度、暂停、测试滚动、退出
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prompter = PrompterController()
    private let reader = ClaudeReader()
    private let spaceTracker = ClaudeSpaceTracker()

    private var statusItem: NSStatusItem?
    private var spaceCheckTimer: Timer?
    private let statusMenuItem = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
    private let pauseMenuItem = NSMenuItem(title: "暂停播放", action: #selector(AppDelegate.togglePause), keyEquivalent: "")

    private var speedPresetItems: [NSMenuItem] = []
    private let speedSlider = NSSlider(value: 7, minValue: 2, maxValue: 20, target: nil, action: nil)
    private let speedLabel = NSTextField(labelWithString: "")
    private let speedPresets: [(name: String, value: Double)] = [("慢", 4), ("中", 7), ("快", 11)]
    private let speedDefaultsKey = "charsPerSecond"

    private var widthPresetItems: [NSMenuItem] = []
    private let widthSlider = NSSlider(value: 480, minValue: 280, maxValue: 1000, target: nil, action: nil)
    private let widthLabel = NSTextField(labelWithString: "")
    private let widthPresets: [(name: String, value: Double)] = [("窄", 360), ("中", 480), ("宽", 640)]
    private let widthDefaultsKey = "panelWidth"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "Notch Prompter")
        item.menu = buildMenu()
        statusItem = item

        let savedSpeed = UserDefaults.standard.double(forKey: speedDefaultsKey)
        setSpeed(savedSpeed > 0 ? savedSpeed : 7)
        let savedWidth = UserDefaults.standard.double(forKey: widthDefaultsKey)
        setWidth(savedWidth > 0 ? savedWidth : 480, preview: false)

        reader.onEvent = { [weak self] event in self?.handle(event) }
        reader.start()
        startFollowingClaudeSpace()
    }

    /// 只在 Claude 所在的桌面显示。切换桌面时立即判断；
    /// 另外每 0.5 秒更新一次 Claude 所在的桌面（Claude 被移到别的桌面、全屏等情况）
    private func startFollowingClaudeSpace() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            spaceTracker.activeSpaceDidChange()
            prompter.isSuspended = !spaceTracker.isOnClaudeSpace
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            spaceTracker.update()
            prompter.isSuspended = !spaceTracker.isOnClaudeSpace
        }
        RunLoop.main.add(timer, forMode: .common)
        spaceCheckTimer = timer
    }

    private func handle(_ event: ClaudeReader.Event) {
        switch event {
        case .status(let text): statusMenuItem.title = text
        case .started: prompter.beginReply()
        case .appended(let text): prompter.append(text)
        case .finished: prompter.endReply()
        }
    }

    // MARK: - 菜单

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        speedPresetItems = addPresets(to: menu, title: "播放速度", presets: speedPresets, unit: "字/秒",
                                      action: #selector(chooseSpeedPreset(_:)))
        menu.addItem(sliderMenuItem(speedSlider, label: speedLabel, action: #selector(speedSliderChanged(_:))))
        menu.addItem(.separator())

        widthPresetItems = addPresets(to: menu, title: "显示宽度", presets: widthPresets, unit: "pt",
                                      action: #selector(chooseWidthPreset(_:)))
        menu.addItem(sliderMenuItem(widthSlider, label: widthLabel, action: #selector(widthSliderChanged(_:))))
        menu.addItem(.separator())

        pauseMenuItem.target = self
        menu.addItem(pauseMenuItem)
        let testItem = NSMenuItem(title: "测试滚动", action: #selector(playTest), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    /// 添加一个不可点的小标题和几个预设项，返回预设项以便之后更新勾选状态
    private func addPresets(to menu: NSMenu, title: String, presets: [(name: String, value: Double)],
                            unit: String, action: Selector) -> [NSMenuItem] {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        return presets.map { preset -> NSMenuItem in
            let item = NSMenuItem(title: "\(preset.name)（\(Int(preset.value)) \(unit)）", action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = preset.value
            menu.addItem(item)
            return item
        }
    }

    private func sliderMenuItem(_ slider: NSSlider, label: NSTextField, action: Selector) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        slider.frame = NSRect(x: 20, y: 4, width: 150, height: 20)
        slider.target = self
        slider.action = action
        slider.isContinuous = true
        label.frame = NSRect(x: 176, y: 6, width: 60, height: 16)
        label.font = .menuFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        container.addSubview(slider)
        container.addSubview(label)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func updateChecks(_ items: [NSMenuItem], selected value: Double) {
        for item in items {
            item.state = (item.representedObject as? Double) == value ? .on : .off
        }
    }

    private func setSpeed(_ value: Double) {
        let speed = value.rounded()
        prompter.charsPerSecond = speed
        speedSlider.doubleValue = speed
        speedLabel.stringValue = "\(Int(speed)) 字/秒"
        updateChecks(speedPresetItems, selected: speed)
        UserDefaults.standard.set(speed, forKey: speedDefaultsKey)
    }

    /// preview：调整时在刘海处短暂显示面板，方便看到新宽度
    private func setWidth(_ value: Double, preview: Bool) {
        let width = (value / 10).rounded() * 10
        prompter.setPreferredWidth(CGFloat(width), preview: preview)
        widthSlider.doubleValue = width
        widthLabel.stringValue = "\(Int(width)) pt"
        updateChecks(widthPresetItems, selected: width)
        UserDefaults.standard.set(width, forKey: widthDefaultsKey)
    }

    @objc private func chooseSpeedPreset(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { setSpeed(value) }
    }

    @objc private func speedSliderChanged(_ sender: NSSlider) {
        setSpeed(sender.doubleValue)
    }

    @objc private func chooseWidthPreset(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { setWidth(value, preview: true) }
    }

    @objc private func widthSliderChanged(_ sender: NSSlider) {
        setWidth(sender.doubleValue, preview: true)
    }

    @objc private func togglePause() {
        prompter.isUserPaused.toggle()
        pauseMenuItem.title = prompter.isUserPaused ? "继续播放" : "暂停播放"
    }

    /// 不依赖 Claude，模拟一段流式输出，用来检查刘海显示和速度
    @objc private func playTest() {
        let sample = "这是一段测试文字，用来检查刘海提词器的显示效果。\n文字会从右侧进入，按设定的速度向左滚动。\n鼠标悬停可以暂停，点击可以展开查看全文，移开鼠标后收起。"
        let chunks = stride(from: 0, to: sample.count, by: 4).map { start -> String in
            let from = sample.index(sample.startIndex, offsetBy: start)
            let to = sample.index(from, offsetBy: 4, limitedBy: sample.endIndex) ?? sample.endIndex
            return String(sample[from..<to])
        }
        prompter.beginReply(isTest: true)
        for (index, chunk) in chunks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.1) { [weak self] in
                self?.prompter.append(chunk)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(chunks.count) * 0.1) { [weak self] in
            self?.prompter.endReply()
        }
    }
}
