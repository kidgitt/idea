import AppKit

/// 菜单栏图标和菜单：连接状态、播放速度、暂停、测试滚动、退出
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prompter = PrompterController()
    private let reader = ClaudeReader()

    private var statusItem: NSStatusItem?
    private let statusMenuItem = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
    private let pauseMenuItem = NSMenuItem(title: "暂停播放", action: #selector(AppDelegate.togglePause), keyEquivalent: "")
    private var presetMenuItems: [NSMenuItem] = []
    private let speedSlider = NSSlider(value: 7, minValue: 2, maxValue: 20, target: nil, action: nil)
    private let speedLabel = NSTextField(labelWithString: "")

    private let presets: [(name: String, charsPerSecond: Double)] = [("慢", 4), ("中", 7), ("快", 11)]
    private let speedDefaultsKey = "charsPerSecond"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "Notch Prompter")
        item.menu = buildMenu()
        statusItem = item

        let saved = UserDefaults.standard.double(forKey: speedDefaultsKey)
        setSpeed(saved > 0 ? saved : 7)

        reader.onEvent = { [weak self] event in self?.handle(event) }
        reader.start()
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

        let header = NSMenuItem(title: "播放速度", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for preset in presets {
            let item = NSMenuItem(title: "\(preset.name)（\(Int(preset.charsPerSecond)) 字/秒）",
                                  action: #selector(choosePreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.charsPerSecond
            menu.addItem(item)
            presetMenuItems.append(item)
        }
        menu.addItem(sliderMenuItem())
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

    private func sliderMenuItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        speedSlider.frame = NSRect(x: 20, y: 4, width: 150, height: 20)
        speedSlider.target = self
        speedSlider.action = #selector(sliderChanged(_:))
        speedSlider.isContinuous = true
        speedLabel.frame = NSRect(x: 176, y: 6, width: 60, height: 16)
        speedLabel.font = .menuFont(ofSize: 12)
        speedLabel.textColor = .secondaryLabelColor
        container.addSubview(speedSlider)
        container.addSubview(speedLabel)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func setSpeed(_ value: Double) {
        let speed = value.rounded()
        prompter.charsPerSecond = speed
        speedSlider.doubleValue = speed
        speedLabel.stringValue = "\(Int(speed)) 字/秒"
        for item in presetMenuItems {
            item.state = (item.representedObject as? Double) == speed ? .on : .off
        }
        UserDefaults.standard.set(speed, forKey: speedDefaultsKey)
    }

    @objc private func choosePreset(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { setSpeed(value) }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        setSpeed(sender.doubleValue)
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
        prompter.beginReply()
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
