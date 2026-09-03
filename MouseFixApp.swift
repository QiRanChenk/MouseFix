import Cocoa
import ApplicationServices

// Synthetic event marker (防递归)
private let kSyntheticMarker: Int64 = 0x4D4F4F53 // 'MOOS'

final class MouseFixController: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?

    // MARK: - 功能开关（UserDefaults 持久化：勾选即保存，下次启动恢复；缺省全开）
    private enum PrefKey {
        static let reverseScroll        = "reverseScroll"
        static let winKeyRemap          = "winKeyRemap"
        static let winSwitcher          = "winSwitcher"
        static let winKeyLauncher       = "winKeyLauncher"
        static let winShowDesktop       = "winShowDesktop"
        static let winThumbnails        = "winThumbnails"
        static let middleClickCopyPaste = "middleClickCopyPaste"
    }

    private static func pref(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    private static func setPref(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var reverseScroll: Bool {
        get { Self.pref(PrefKey.reverseScroll) }
        set { Self.setPref(PrefKey.reverseScroll, newValue) }
    }
    var winKeyRemap: Bool {
        get { Self.pref(PrefKey.winKeyRemap) }
        set { Self.setPref(PrefKey.winKeyRemap, newValue) }
    }
    var winSwitcher: Bool {
        get { Self.pref(PrefKey.winSwitcher) }
        set { Self.setPref(PrefKey.winSwitcher, newValue) }
    }
    var winKeyLauncher: Bool {
        get { Self.pref(PrefKey.winKeyLauncher) }
        set { Self.setPref(PrefKey.winKeyLauncher, newValue) }
    }
    var winShowDesktop: Bool {
        get { Self.pref(PrefKey.winShowDesktop) }
        set { Self.setPref(PrefKey.winShowDesktop, newValue) }
    }
    var winThumbnails: Bool {
        get { Self.pref(PrefKey.winThumbnails) }
        set { Self.setPref(PrefKey.winThumbnails, newValue) }
    }
    var middleClickCopyPaste: Bool {
        get { Self.pref(PrefKey.middleClickCopyPaste) }
        set { Self.setPref(PrefKey.middleClickCopyPaste, newValue) }
    }

    private let switcher = WindowSwitcherController()
    private let launcher = AppLauncherController()
    /// Win 键（macOS 上映射为 Command）「单独点按」检测：按下时置位，任何组合键/鼠标动作清除
    private var cmdAlonePending = false

    // MARK: - 生命周期
    func applicationDidFinishLaunching(_ n: Notification) {
        setupLog()
        setupMenu()
        switcher.log = { [weak self] s in self?.log(s) }
        launcher.log = { [weak self] s in self?.log(s) }
        // 缩略图开关持久化值同步给切换器（此前只在菜单点击时同步，启动时默认 true 会漂移）
        switcher.thumbnailsEnabled = winThumbnails
        log("config: reverseScroll=\(reverseScroll) winKeyRemap=\(winKeyRemap) winSwitcher=\(winSwitcher) "
          + "winKeyLauncher=\(winKeyLauncher) winShowDesktop=\(winShowDesktop) winThumbnails=\(winThumbnails) "
          + "middleClickCopyPaste=\(middleClickCopyPaste)")
        // 调试预览：--preview-switcher 直接展示切换器面板（不装 tap，无需授权，便于截图验证 UI）
        if CommandLine.arguments.contains("--preview-switcher") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.switcher.preview()
            }
            return
        }
        if CommandLine.arguments.contains("--preview-launcher") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.launcher.show()
            }
            return
        }
        if AXIsProcessTrusted() {
            installEventTap()
        } else {
            showAccessibilityAlert()
            waitForTrustThenInstall()
        }
        // 中键功能端到端自测：需先装好 tap，跑完自动退出
        if CommandLine.arguments.contains("--selftest-middle") {
            runMiddleClickSelfTest()
        }
    }

    // 授权可能在启动后才给：轮询直到 trusted，再装 tap，免去手动重启
    private func waitForTrustThenInstall() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, AXIsProcessTrusted() else { return }
            t.invalidate()
            self.log("accessibility granted, installing tap")
            self.installEventTap()
        }
    }

    // MARK: - 日志
    private func setupLog() {
        let logPath = NSHomeDirectory() + "/Library/Logs/MouseFix.log"
        let attrs: [FileAttributeKey: Any]? = nil
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: attrs)
        logFileHandle = FileHandle(forWritingAtPath: logPath)
        logFileHandle?.seekToEndOfFile()
        log("launched. trusted=\(AXIsProcessTrusted())")
    }

    private var logFileHandle: FileHandle?

    private func log(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        if let data = line.data(using: .utf8) {
            logFileHandle?.write(data)
        }
        NSLog("[MouseFix] %@", s)
    }

    // MARK: - 菜单栏
    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 菜单栏图标：自绘鼠标剪影模板图（紧贴画布不裁切），自动跟随明暗菜单栏反色
        if let img = NSImage(named: "menubar-icon") {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.imagePosition = .imageOnly
        } else {
            statusItem.button?.title = "MouseFix"
        }
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(makeItem(#selector(toggleScroll), "反向鼠标滚轮"))
        m.addItem(makeItem(#selector(toggleKeyRemap), "Windows 风格 Ctrl 快捷键"))
        m.addItem(makeItem(#selector(toggleSwitcher), "Windows 风格 Alt+Tab 切换器"))
        m.addItem(makeItem(#selector(toggleLauncher), "Win 键打开应用列表"))
        m.addItem(makeItem(#selector(toggleShowDesktopPref), "Win+D 显示桌面"))
        m.addItem(makeItem(#selector(toggleThumbnails), "窗口缩略图（需屏幕录制）"))
        m.addItem(makeItem(#selector(toggleMiddleClick), "中键复制/粘贴（无选中时粘贴）"))
        m.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)
        statusItem.menu = m
        syncMenuTitles()
    }

    private func makeItem(_ sel: Selector, _ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        return it
    }

    private func syncMenuTitles() {
        let m = statusItem.menu!
        setCheck(m.item(at: 0)!, on: reverseScroll)
        setCheck(m.item(at: 1)!, on: winKeyRemap)
        setCheck(m.item(at: 2)!, on: winSwitcher)
        setCheck(m.item(at: 3)!, on: winKeyLauncher)
        setCheck(m.item(at: 4)!, on: winShowDesktop)
        setCheck(m.item(at: 5)!, on: winThumbnails)
        setCheck(m.item(at: 5)!, on: winThumbnails)
        setCheck(m.item(at: 6)!, on: middleClickCopyPaste)
    }

    private func setCheck(_ item: NSMenuItem, on: Bool) {
        let raw = item.title
            .replacingOccurrences(of: "\u{2713} ", with: "")
            .replacingOccurrences(of: "  ", with: "")
        item.title = (on ? "\u{2713} " : "  ") + raw
    }

    @objc private func toggleScroll()   { reverseScroll.toggle(); syncMenuTitles() }
    @objc private func toggleKeyRemap() { winKeyRemap.toggle(); syncMenuTitles() }
    @objc private func toggleSwitcher() {
        winSwitcher.toggle()
        syncMenuTitles()
        if !winSwitcher { switcher.cancel() }
    }
    @objc private func toggleLauncher() {
        winKeyLauncher.toggle()
        syncMenuTitles()
        if !winKeyLauncher { launcher.hide() }
    }
    @objc private func toggleShowDesktopPref() { winShowDesktop.toggle(); syncMenuTitles() }
    @objc private func toggleThumbnails() {
        winThumbnails.toggle()
        syncMenuTitles()
        switcher.thumbnailsEnabled = winThumbnails
    }
    @objc private func toggleMiddleClick() { middleClickCopyPaste.toggle(); syncMenuTitles() }
    @objc private func quitApp()        { NSApp.terminate(nil) }

    // MARK: - 授权
    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能授权"
        alert.informativeText = """
        MouseFix 需要「辅助功能」权限才能拦截滚轮事件。

        1. 点击下方按钮打开「系统设置」
        2. 隐私与安全性 → 辅助功能
        3. 找到 MouseFix 并勾选
        4. 退出本应用，重新打开
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - 事件 Tap（滚轮 + 键盘）
    private func installEventTap() {
        let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
                              | (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)
                              | (1 << CGEventType.leftMouseDown.rawValue)
                              | (1 << CGEventType.rightMouseDown.rawValue)
                              | (1 << CGEventType.otherMouseDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let ctrl = Unmanaged<MouseFixController>
                    .fromOpaque(refcon!).takeUnretainedValue()
                switch type {
                case .scrollWheel:
                    return ctrl.processScroll(event)
                case .keyDown, .keyUp:
                    return ctrl.processKey(event)
                case .flagsChanged:
                    return ctrl.processFlags(event)
                case .leftMouseDown, .rightMouseDown:
                    return ctrl.processMouse(event)
                case .otherMouseDown:
                    return ctrl.processMiddleClick(event)
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    if let tap = ctrl.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passRetained(event)
                default:
                    return Unmanaged.passRetained(event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            log("tapCreate returned nil - check Accessibility permission")
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("tap installed and enabled")
    }

    // MARK: - 键盘：Windows 风格 Ctrl 快捷键
    // Ctrl+C/V/X/A/S/Z → Cmd 同键；Ctrl+Y → Cmd+Shift+Z（重做）；Ctrl+Q → Ctrl+A（保留系统的"移到行首"）。
    // 终端里 Ctrl+C 是 SIGINT，Ctrl+A/Q 也各有含义，故终端类 app 全部跳过。
    private let excludedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
    ]

    // ANSI 键码
    private enum Key {
        static let a: Int64 = 0x00
        static let x: Int64 = 0x07
        static let c: Int64 = 0x08
        static let v: Int64 = 0x09
        static let q: Int64 = 0x0C
        static let s: Int64 = 0x01
        static let z: Int64 = 0x06
        static let y: Int64 = 0x10
    }

    private func processKey(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 出现任何按键都说明 Win 键不是「单独点按」
        cmdAlonePending = false
        // Alt+Tab 切换器优先：命中即吞掉事件
        if winSwitcher, switcher.handleKeyEvent(event) { return nil }

        // Win+D（PC 键盘上映射为 Cmd+D）→ 显示桌面 / 恢复
        if winShowDesktop, event.type == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if keyCode == 0x02, mods == .maskCommand {   // 0x02 = D
                toggleShowDesktop()
                return nil
            }
        }

        guard winKeyRemap else { return Unmanaged.passRetained(event) }

        let flags = event.flags
        // 只处理"按住 Ctrl 且没按 Cmd"的组合，避免误伤 Cmd 系快捷键
        guard flags.contains(.maskControl), !flags.contains(.maskCommand) else {
            return Unmanaged.passRetained(event)
        }

        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           excludedBundleIDs.contains(bid) {
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch keyCode {
        case Key.c, Key.v, Key.x, Key.a, Key.s, Key.z:
            // Ctrl 换成 Cmd，其余修饰键（如 Shift）原样保留
            var f = flags
            f.remove(.maskControl)
            f.insert(.maskCommand)
            event.flags = f
            if event.type == .keyDown { log("remap Ctrl+\(keyCode) -> Cmd") }
        case Key.y:
            // Ctrl+Y → Cmd+Shift+Z：macOS 标准重做
            var f = flags
            f.remove(.maskControl)
            f.insert(.maskCommand)
            f.insert(.maskShift)
            event.flags = f
            event.setIntegerValueField(.keyboardEventKeycode, value: Key.z)
            if event.type == .keyDown { log("remap Ctrl+Y -> Cmd+Shift+Z") }
        case Key.q:
            // Ctrl+Q → Ctrl+A：交给系统原生的"行首"行为
            event.setIntegerValueField(.keyboardEventKeycode, value: Key.a)
        default:
            break
        }
        return Unmanaged.passRetained(event)
    }

    // MARK: - Win+D 显示桌面（隐藏全部应用，再按一次恢复）
    private var desktopShown = false
    private var hiddenByUs: [pid_t] = []

    private func toggleShowDesktop() {
        if desktopShown {
            for pid in hiddenByUs {
                NSRunningApplication(processIdentifier: pid)?.unhide()
            }
            hiddenByUs = []
            desktopShown = false
            log("show desktop OFF")
        } else {
            hiddenByUs = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isHidden
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }.map { $0.processIdentifier }
            for pid in hiddenByUs {
                NSRunningApplication(processIdentifier: pid)?.hide()
            }
            desktopShown = true
            log("show desktop ON, hid \(hiddenByUs.count) apps")
        }
    }

    // MARK: - 修饰键 / 鼠标：服务于 Alt+Tab 切换器与 Win 键启动器
    private func processFlags(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if winSwitcher { switcher.handleFlagsChanged(event) }

        // Option 按下即预热缩略图：利用「按 Option → 按 Tab」之间的间隙提前截好，
        // 面板出现时图片已就绪。无常驻轮询，屏幕捕捉指示器只在切换窗口时短暂出现。
        if winSwitcher, winThumbnails {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if (keyCode == 0x3A || keyCode == 0x3D), event.flags.contains(.maskAlternate) {
                switcher.prewarm()
            }
        }

        // Win 键（PC 键盘映射为 Command）单独点按 → 打开/关闭应用列表。
        // 判定：Cmd 按下后没有任何其他按键/鼠标动作，直到 Cmd 松开。
        if winKeyLauncher, !switcher.isVisible {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 0x37 || keyCode == 0x36 {   // 左/右 Command
                if event.flags.contains(.maskCommand) {
                    cmdAlonePending = true
                } else if cmdAlonePending {
                    cmdAlonePending = false
                    launcher.toggle()
                }
            } else {
                // 组合了其他修饰键（如 Cmd+Shift）则不算单独点按
                cmdAlonePending = false
            }
        }
        return Unmanaged.passRetained(event)
    }

    private func processMouse(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        cmdAlonePending = false
        // 点击落在面板外 = 取消；落在面板内则交给面板自己处理（点击选中切换/启动）
        if switcher.isVisible {
            if let f = switcher.panelFrame, !f.contains(NSEvent.mouseLocation) {
                switcher.cancel()
            }
        }
        if launcher.isVisible {
            if let f = launcher.panelFrame, !f.contains(NSEvent.mouseLocation) {
                launcher.hide()
            }
        }
        return Unmanaged.passRetained(event)
    }

    // MARK: - 中键：有选中 → 复制，无选中 → 粘贴
    // 原理：中键按下先合成 Cmd+C「探测」，~250ms 内剪贴板 changeCount 变了 = 原本有选中（复制完成）；
    // 没变 = 无选中，再合成 Cmd+V 粘贴。比 AX 选中检测通用（很多应用不暴露 kAXSelectedText）。
    // 作用对象与系统快捷键一致：当前聚焦（frontmost）应用。
    private var middleClickToken = 0
    private var middleProbeTimer: DispatchSourceTimer?

    private func processMiddleClick(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        cmdAlonePending = false
        // 功能关闭时走普通鼠标处理（面板外点击取消等），中键原样放行
        guard middleClickCopyPaste else { return processMouse(event) }
        // 只接管中键（button 2），鼠标侧键不受影响
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passRetained(event)
        }
        // 中键点在切换器/启动器期间一律先收起面板（面板里没有可复制内容，避免误粘贴到后方应用）
        if switcher.isVisible { switcher.cancel() }
        if launcher.isVisible { launcher.hide() }
        startCopyPasteProbe()
        return nil   // 吞掉中键，避免应用同时响应（浏览器中键开新链接、按住中键平移画布等）
    }

    /// 复制/粘贴探测。连续快速中键时以最后一次为准（token 作废上一轮未完成的探测）。
    private func startCopyPasteProbe() {
        middleClickToken += 1
        let token = middleClickToken
        middleProbeTimer?.cancel()
        middleProbeTimer = nil

        let original = NSPasteboard.general.changeCount
        postCmdKey(Key.c)
        var tries = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            guard let self, self.middleClickToken == token else { timer.cancel(); return }
            if NSPasteboard.general.changeCount != original {
                timer.cancel()
                self.middleProbeTimer = nil
                self.log("middle click -> copy")
            } else if tries >= 9 {   // ≈250ms 剪贴板无变化 = 无选中
                timer.cancel()
                self.middleProbeTimer = nil
                switch self.focusedEditableState() {
                case false:   // AX 明确表明聚焦的不是可编辑文本 → 不粘贴
                    self.log("middle click -> paste skipped (no focused text input)")
                default:      // 输入框激活，或 AX 无法判断（保底粘贴，兼容终端等 AX 薄弱应用）
                    self.postCmdKey(Key.v)
                    self.log("middle click -> paste")
                }
            }
            tries += 1
        }
        timer.resume()
        middleProbeTimer = timer
    }

    /// AX 判断当前聚焦元素是否可编辑文本（输入框激活）。
    /// true = 文本框/文本域等；false = 有角色但明确不是可编辑文本；nil = 无法判断（无聚焦元素/AX 不可用）。
    private func focusedEditableState() -> Bool? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)   // 主线程调用，限时防卡
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value else { return nil }
        let axEl = element as! AXUIElement
        AXUIElementSetMessagingTimeout(axEl, 0.1)

        // 常见可编辑文本角色
        var roleObj: AnyObject?
        let role = (AXUIElementCopyAttributeValue(axEl, kAXRoleAttribute as CFString, &roleObj) == .success)
            ? (roleObj as? String) ?? "" : ""
        if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) { return true }

        // 自绘编辑器/终端等：支持读写选区即视为可编辑
        var rangeObj: AnyObject?
        if AXUIElementCopyAttributeValue(axEl, kAXSelectedTextRangeAttribute as CFString, &rangeObj) == .success,
           rangeObj != nil { return true }

        // 有角色但既不是文本角色也不支持选区 → 明确不是输入框
        return role.isEmpty ? nil : false
    }

    /// 合成 Cmd+键（打 synthetic 标记；事件会再次经过自己的 tap，processKey 只放行 Cmd 组合不会拦截）
    private func postCmdKey(_ keyCode: Int64) {
        let key = CGKeyCode(keyCode)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            e.flags = .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - 中键自测（--selftest-middle）：自建窗口 + 合成事件端到端验证，结果写日志后退出
    // 阶段 1：文本框全选 + 合成中键 → 剪贴板应变为文本（复制路径）
    // 阶段 2：光标移到末尾（无选中）+ 剪贴板放 token + 合成中键 → 文本应追加 token（粘贴路径）
    private func runMiddleClickSelfTest() {
        NSApp.setActivationPolicy(.regular)
        // 程序化创建的裸应用没有主菜单，Cmd+C/V 找不到菜单等价键会是 no-op；
        // 真实应用都有 Edit 菜单（功能正是模拟按这些快捷键），这里补一个最小 Edit 菜单
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu

        let win = NSWindow(contentRect: NSRect(x: 300, y: 500, width: 420, height: 100),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.title = "MouseFix SelfTest"
        let field = NSTextField(frame: NSRect(x: 20, y: 40, width: 380, height: 24))
        field.stringValue = "hello middle click"
        win.contentView?.addSubview(field)
        // 可聚焦的非文本视图（模拟无输入框激活的场景）
        final class FocusAnchor: NSView {
            override var acceptsFirstResponder: Bool { true }
        }
        let anchor = FocusAnchor(frame: NSRect(x: 20, y: 8, width: 120, height: 14))
        win.contentView?.addSubview(anchor)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(field)
        log("selftest: window ready")

        let pb = NSPasteboard.general
        let text = "hello middle click"
        func ensureActive(_ tag: String) {
            NSApp.activate(ignoringOtherApps: true)
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            log("selftest \(tag): active=\(NSApp.isActive) keyWin=\(win.isKeyWindow) front=\(front)")
        }
        func postMiddle() {
            // 事件会被自己的 tap 吞掉，坐标仅是元数据，不参与命中
            if let e = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                               mouseCursorPosition: win.frame.origin, mouseButton: .center) {
                e.post(tap: .cgSessionEventTap)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // 阶段 1：有选中 → 复制
            ensureActive("phase1")
            field.currentEditor()?.selectAll(nil)
            pb.clearContents()
            let before = pb.changeCount
            postMiddle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let copyOK = pb.changeCount != before && pb.string(forType: .string) == text
                self.log("selftest copy: \(copyOK ? "OK" : "FAIL")")
                // 阶段 2：无选中 → 粘贴
                ensureActive("phase2")
                pb.clearContents()
                pb.setString("PASTE-TOKEN", forType: .string)
                if let ed = field.currentEditor() {
                    ed.selectedRange = NSRange(location: (text as NSString).length, length: 0)
                }
                postMiddle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let pasteOK = field.stringValue.contains("PASTE-TOKEN")
                    self.log("selftest paste: \(pasteOK ? "OK" : "FAIL"), field=\(field.stringValue)")
                    // 阶段 3（观察）：非输入框聚焦 → 粘贴应被跳过（AX 可识别时）
                    win.makeFirstResponder(anchor)
                    pb.clearContents()
                    pb.setString("NOPE-TOKEN", forType: .string)
                    postMiddle()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let skipped = !field.stringValue.contains("NOPE-TOKEN")
                        self.log("selftest skip-path: skipped=\(skipped), editableState=\(String(describing: self.focusedEditableState()))")
                        let ok = copyOK && pasteOK
                        self.log("SELFTEST-MIDDLE \(ok ? "PASS" : "FAIL")")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(ok ? 0 : 1) }
                    }
                }
            }
        }
    }


    // MARK: - 滚轮：仅反转鼠标，触摸板不动；动量平滑滚动
    private func processScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // 跳过自己发出去的 synthetic 事件
        if event.getIntegerValueField(.eventSourceUserData) == kSyntheticMarker {
            return Unmanaged.passRetained(event)
        }
        guard reverseScroll else { return Unmanaged.passRetained(event) }

        // 触摸板（isContinuous=1）不动
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1
        if continuous { return Unmanaged.passRetained(event) }

        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let py = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        log("mouse scroll dy=\(dy) py=\(py)")

        // 反向后转为像素位移，注入动量；吞掉原事件
        let pixels = py != 0 ? Double(-py) : Double(-dy) * 40
        applyImpulse(pixels)
        return nil
    }

    // MARK: - 动量滚动（模拟触摸板惯性）
    // 速度随每帧指数衰减；同向连续滚动累加速度，反向立即归零。
    private var velocity: Double = 0          // 当前速度（像素/帧）
    private var subPixel: Double = 0          // 亚像素累积，防整数漂移
    private var scrollTimer: DispatchSourceTimer?

    /// 每帧速度保留比例：越大滑行越久。0.88 ≈ 24 帧(~380ms) 衰减到 5%。
    private let friction: Double = 0.92
    /// 速度低于此值即停止（像素/帧）。
    private let stopThreshold: Double = 0.2
    /// 输入 delta 转为初始速度的比例。总位移 ≈ impulseFraction/(1-friction) × delta ≈ 1.7× delta。
    private let impulseFraction: Double = 0.2
    /// 速度上限，防止极速滚动失控（像素/帧）。
    private let maxVelocity: Double = 100

    private func applyImpulse(_ pixels: Double) {
        guard pixels != 0 else { return }
        // 反向：立即归零再注入新速度，保证方向切换灵敏不拖泥带水
        if velocity != 0 && (velocity > 0) != (pixels > 0) {
            velocity = 0
            subPixel = 0
        }
        velocity += pixels * impulseFraction
        velocity = min(max(velocity, -maxVelocity), maxVelocity)
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        if scrollTimer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        scrollTimer = timer
    }

    private func tick() {
        // 当前速度转为整数像素发送（亚像素累积防漂移）
        subPixel += velocity
        let toPost = Int64(subPixel.rounded(.toNearestOrAwayFromZero))
        subPixel -= Double(toPost)
        if toPost != 0 {
            postSyntheticScroll(pixels: toPost)
        }
        // 指数衰减
        velocity *= friction
        if abs(velocity) < stopThreshold {
            velocity = 0
            subPixel = 0
            scrollTimer?.cancel()
            scrollTimer = nil
        }
    }

    private func postSyntheticScroll(pixels: Int64) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil,
                              units: .pixel,
                              wheelCount: 1,
                              wheel1: Int32(pixels),
                              wheel2: 0,
                              wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pixels)
        e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
        e.post(tap: .cgSessionEventTap)
    }
}

// MARK: - Windows 风格 Alt+Tab 切换器
// Option+Tab 呼出：应用图标 + 统一尺寸窗口缩略图；Tab/Shift+Tab 移动选择，
// 松开 Option 确认切换，Esc 或点击别处取消。列表按屏幕前后顺序排列（= 最近使用顺序），
// 默认选中第 2 项，快速点按 Alt+Tab 即在最近两个窗口间来回切换（与 Windows 一致）。

private let kTabKey: Int64 = 0x30
private let kEscapeKey: Int64 = 0x35
private let kOptionLeft: Int64 = 0x3A
private let kOptionRight: Int64 = 0x3D

private struct SwitcherItem {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage?
    let bounds: CGRect

    var displayName: String {
        title.isEmpty ? appName : "\(appName) — \(title)"
    }
}

/// 切换器卡片：支持鼠标点击切换与悬停高亮
private final class CardView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// 缩略图右上角的关闭按钮；命中测试时优先把点击交给它
    var closeButton: NSButton?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // 卡片内的点击一律由卡片接收（NSImageView/NSTextField 是 NSControl，会吞掉鼠标事件），
    // 但关闭按钮区域例外，交还给按钮自己。
    // 注意：hitTest 传入的 point 在父视图坐标系，需先转到卡片坐标系再比较按钮 frame。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        if let b = closeButton, !b.isHidden {
            let p = superview?.convert(point, to: self) ?? point
            if b.frame.contains(p) { return b }
        }
        return self
    }

    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent)  { onHover?(false) }
    override func mouseDown(with e: NSEvent) { onClick?() }
}

final class WindowSwitcherController {

    var log: (String) -> Void = { _ in }
    private(set) var isVisible = false
    /// 面板在屏幕坐标系中的位置（供事件 tap 判断点击是否落在面板内）
    var panelFrame: NSRect? { panel?.frame }

    // 卡片几何：所有缩略图统一 204×128，等比裁剪铺满，保证整齐划一
    private let cardW: CGFloat = 220
    private let cardH: CGFloat = 178
    private let thumbSize = NSSize(width: 204, height: 128)
    private let gap: CGFloat = 12
    private let pad: CGFloat = 18

    private var panel: NSPanel?
    private var items: [SwitcherItem] = []
    private var cards: [CardView] = []
    private var thumbViews: [NSImageView] = []
    private var selectedIndex = 0
    private var hoverIndex: Int?
    private var session = 0                 // 异步截图会话号，防过期回调写脏新面板
    private var titleLabel: NSTextField?
    private var askedScreenPermission = false

    // MARK: 缩略图缓存（按下 Option 时预热截取，无常驻轮询，Alt+Tab 出现即带图）
    var thumbnailsEnabled = true          // 关闭后纯图标模式：完全不捕捉屏幕
    private var thumbCache: [CGWindowID: NSImage] = [:]
    private var prewarming = false

    /// Option 键按下的瞬间调用：趁用户按 Tab 前的间隙提前截好缩略图
    func prewarm() {
        guard thumbnailsEnabled, !isVisible, !prewarming,
              CGPreflightScreenCaptureAccess() else { return }
        prewarming = true
        let snapshot = collectItems()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var new: [CGWindowID: NSImage] = [:]
            for item in snapshot {
                if let img = self?.captureThumbnail(item) {
                    new[item.windowID] = img
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbCache = new
                self.prewarming = false
            }
        }
    }

    /// 调试预览入口：直接展示面板，不依赖事件 tap
    func preview() { show() }

    // MARK: 按键（返回 true 表示吞掉该事件）
    @discardableResult
    func handleKeyEvent(_ event: CGEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if isVisible {
            switch keyCode {
            case kTabKey:    moveSelection(forward: !event.flags.contains(.maskShift))
            case kEscapeKey: cancel()
            default:         break
            }
            return true   // 面板可见期间吞掉所有按键，避免漏进后方应用
        }
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        guard keyCode == kTabKey, mods == .maskAlternate else { return false }
        show()
        return true
    }

    /// Option 松开 → 确认当前选择
    func handleFlagsChanged(_ event: CGEvent) {
        guard isVisible else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if (keyCode == kOptionLeft || keyCode == kOptionRight),
           !event.flags.contains(.maskAlternate) {
            commit()
        }
    }

    // MARK: 窗口收集（.optionOnScreenOnly 返回前到后顺序，即 MRU）
    private func collectItems() -> [SwitcherItem] {
        let screenW = NSScreen.main?.frame.width ?? 1440
        let maxItems = max(3, Int((screenW - 160) / (cardW + gap)))
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var result: [SwitcherItem] = []
        for w in raw {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID,
                  let bd = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  bounds.width >= 120, bounds.height >= 120,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy != .prohibited,
                  !app.isTerminated
            else { continue }
            let title = (w[kCGWindowName as String] as? String) ?? ""
            let wid = CGWindowID(w[kCGWindowNumber as String] as? Int ?? 0)
            result.append(SwitcherItem(windowID: wid, pid: pid,
                                       appName: app.localizedName ?? "App",
                                       title: title, icon: app.icon, bounds: bounds))
            if result.count >= maxItems { break }
        }
        return result
    }

    // MARK: 显示 / 隐藏
    private func show() {
        let newItems = collectItems()
        guard !newItems.isEmpty else { return }
        if thumbnailsEnabled { ensureScreenPermission() }
        hidePanelOnly()
        items = newItems
        selectedIndex = items.count > 1 ? 1 : 0
        buildPanel()
        isVisible = true
        refreshHighlight()
        if let p = panel {
            // 面板淡入，避免生硬弹出
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                p.animator().alphaValue = 1
            }
        }
        if thumbnailsEnabled { captureThumbnails() }
        log("switcher shown, \(items.count) windows")
    }

    private func hidePanelOnly() {
        panel?.orderOut(nil)
        panel = nil
        cards = []
        thumbViews = []
        titleLabel = nil
    }

    func cancel() {
        guard isVisible else { return }
        hidePanelOnly()
        items = []
        isVisible = false
        hoverIndex = nil
        session += 1   // 作废进行中的截图回调
    }

    private func commit() {
        guard isVisible, items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        log("switch to \(item.displayName)")
        cancel()
        activate(item)
    }

    // MARK: 面板与卡片
    private func buildPanel() {
        let n = items.count
        let width = pad * 2 + CGFloat(n) * cardW + CGFloat(n - 1) * gap
        let height = pad + cardH + 12 + 20 + 10
        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(x: screen.frame.midX - width / 2,
                             y: screen.frame.midY - height / 2)

        let p = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.acceptsMouseMovedEvents = true   // 悬停高亮需要

        // 毛玻璃底板 + 大圆角
        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        blur.material = .popover
        blur.state = .active
        blur.wantsLayer = true
        blur.autoresizingMask = [.width, .height]   // 关闭窗口后面板收窄时自适应
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        p.contentView = blur

        let cardsY = height - pad - cardH
        for (i, item) in items.enumerated() {
            let card = makeCard(item)
            card.frame = NSRect(x: pad + CGFloat(i) * (cardW + gap), y: cardsY,
                                width: cardW, height: cardH)
            // 闭包按卡片身份反查索引，关闭窗口导致左移后仍然正确
            card.onClick = { [weak self, weak card] in
                guard let self, let card,
                      let idx = self.cards.firstIndex(where: { $0 === card }) else { return }
                self.commitIndex(idx)
            }
            card.onHover = { [weak self, weak card] inside in
                guard let self, let card,
                      let idx = self.cards.firstIndex(where: { $0 === card }) else { return }
                self.hoverIndex = inside ? idx : (self.hoverIndex == idx ? nil : self.hoverIndex)
                card.closeButton?.isHidden = !inside   // 悬停时才显示关闭按钮
                self.refreshHighlight()
            }
            card.closeButton?.target = self
            card.closeButton?.action = #selector(closeClicked(_:))
            blur.addSubview(card)
            cards.append(card)
        }

        // 底部居中显示当前选中窗口的完整标题
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.frame = NSRect(x: pad, y: 8, width: width - pad * 2, height: 20)
        blur.addSubview(label)
        titleLabel = label

        panel = p
    }

    private func makeCard(_ item: SwitcherItem) -> CardView {
        let card = CardView(frame: NSRect(x: 0, y: 0, width: cardW, height: cardH))
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true

        // 统一尺寸缩略图：初始留空（不先用图标占位，避免图标一闪而过的卡顿感），
        // 截图异步完成直接显示缩略图；仅截图失败时才回退为应用图标
        let thumb = NSImageView(frame: NSRect(x: 8, y: cardH - 8 - thumbSize.height,
                                              width: thumbSize.width, height: thumbSize.height))
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor
        thumb.imageScaling = .scaleAxesIndependently
        if thumbnailsEnabled {
            thumb.image = thumbCache[item.windowID]   // 预热缓存命中：零等待带图显示
        } else {
            thumb.image = iconPlaceholder(item.icon)  // 纯图标模式：完全不捕捉屏幕
        }
        card.addSubview(thumb)
        thumbViews.append(thumb)

        // 关闭按钮：缩略图右上角，悬停卡片时显示
        let close = NSButton(frame: NSRect(x: 8 + thumbSize.width - 18, y: cardH - 8 - 18,
                                           width: 24, height: 24))
        close.isBordered = false
        close.title = ""
        close.wantsLayer = true
        close.layer?.cornerRadius = 12
        close.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭窗口") {
            close.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)) ?? img
        }
        close.contentTintColor = .white
        close.isHidden = true
        card.addSubview(close)
        card.closeButton = close

        // 图标 + 应用名整体居中（图标加大到 28pt）
        let stripH = cardH - 8 - thumbSize.height   // 底部条高度
        let iconS: CGFloat = 28
        let iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: iconS, height: iconS))
        iconView.image = item.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: item.appName)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        let nameW = min(name.fittingSize.width, cardW - 16 - iconS - 6)
        let groupW = iconS + 6 + nameW
        let startX = (cardW - groupW) / 2
        iconView.frame.origin = NSPoint(x: startX, y: (stripH - iconS) / 2)
        name.frame = NSRect(x: startX + iconS + 6, y: (stripH - 20) / 2, width: nameW, height: 20)
        card.addSubview(iconView)
        card.addSubview(name)
        return card
    }

    private func refreshHighlight() {
        for (i, card) in cards.enumerated() {
            let on = i == selectedIndex
            let hover = i == hoverIndex
            card.layer?.backgroundColor = (on ? NSColor.controlAccentColor.withAlphaComponent(0.30)
                                              : hover ? NSColor.labelColor.withAlphaComponent(0.08)
                                                      : NSColor.clear).cgColor
            card.layer?.borderWidth = on ? 1.5 : 0
            card.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        }
        if items.indices.contains(selectedIndex) {
            titleLabel?.stringValue = items[selectedIndex].displayName
        }
    }

    /// 鼠标点击卡片：选中并立即切换（Windows 行为一致）
    private func commitIndex(_ i: Int) {
        guard isVisible, items.indices.contains(i) else { return }
        selectedIndex = i
        refreshHighlight()
        commit()
    }

    // MARK: 关闭窗口
    @objc private func closeClicked(_ sender: NSButton) {
        guard let card = sender.superview as? CardView,
              let idx = cards.firstIndex(where: { $0 === card }) else { return }
        closeItem(at: idx)
    }

    /// 关闭指定窗口并就地移除卡片，其余卡片左移、面板收窄
    private func closeItem(at idx: Int) {
        guard isVisible, items.indices.contains(idx) else { return }
        let item = items[idx]
        log("close window \(item.displayName)")
        closeWindow(item)

        items.remove(at: idx)
        cards[idx].removeFromSuperview()
        cards.remove(at: idx)
        thumbViews.remove(at: idx)

        if items.isEmpty { cancel(); return }
        if selectedIndex >= items.count { selectedIndex = items.count - 1 }
        if let h = hoverIndex, h >= items.count { hoverIndex = nil }
        compactLayout()
        refreshHighlight()
    }

    private func compactLayout() {
        guard let p = panel else { return }
        let n = items.count
        let width = pad * 2 + CGFloat(n) * cardW + CGFloat(max(0, n - 1)) * gap
        var f = p.frame
        f.origin.x = f.midX - width / 2
        f.size.width = width
        p.setFrame(f, display: true)
        for (j, c) in cards.enumerated() {
            c.frame.origin.x = pad + CGFloat(j) * (cardW + gap)
        }
        titleLabel?.frame.size.width = width - pad * 2
    }

    private func moveSelection(forward: Bool) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + (forward ? 1 : -1) + items.count) % items.count
        refreshHighlight()
    }

    // MARK: 缩略图（需「屏幕录制」权限，失败则保留图标占位）
    private func captureThumbnails() {
        session += 1
        let token = session
        let snapshot = items
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failed = 0
            for (i, item) in snapshot.enumerated() {
                let img = self?.captureThumbnail(item)
                if img == nil { failed += 1 }
                DispatchQueue.main.async {
                    guard let self, self.session == token, i < self.thumbViews.count else { return }
                    if let img { self.thumbCache[item.windowID] = img }
                    // 已有缓存图：静默替换（无闪烁）；空位新图：淡入；失败：回退图标
                    let animated = self.thumbViews[i].image == nil
                    self.setThumbnail(self.thumbViews[i],
                                      image: img ?? self.iconPlaceholder(item.icon),
                                      animated: animated)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.session == token, !snapshot.isEmpty else { return }
                if failed == snapshot.count {
                    self.log("all thumbnails failed — 需授予「屏幕录制」权限：系统设置 → 隐私与安全性 → 屏幕录制 → MouseFix")
                }
            }
        }
    }

    /// 设置缩略图；animated=true 时淡入，避免图片生硬弹出
    private func setThumbnail(_ view: NSImageView, image: NSImage, animated: Bool) {
        guard animated else { view.image = image; return }
        view.alphaValue = 0
        view.image = image
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            view.animator().alphaValue = 1
        }
    }

    private func captureThumbnail(_ item: SwitcherItem) -> NSImage? {
        // nominalResolution 足够 204×128 显示，比 bestResolution 快得多（缓存高频刷新的关键）
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, item.windowID,
                                               [.boundsIgnoreFraming, .nominalResolution]) else { return nil }
        let src = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return croppedToFill(src, size: thumbSize)
    }

    /// 等比裁剪铺满统一尺寸（Windows 风格整齐网格的关键）
    private func croppedToFill(_ image: NSImage, size: NSSize) -> NSImage {
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let s = image.size
        if s.width > 0, s.height > 0 {
            let scale = max(size.width / s.width, size.height / s.height)
            let w = s.width * scale, h = s.height * scale
            image.draw(in: NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h),
                       from: .zero, operation: .sourceOver, fraction: 1)
        }
        out.unlockFocus()
        return out
    }

    private func iconPlaceholder(_ icon: NSImage?) -> NSImage {
        let out = NSImage(size: thumbSize)
        out.lockFocus()
        if let icon {
            let s: CGFloat = 56
            icon.draw(in: NSRect(x: (thumbSize.width - s) / 2, y: (thumbSize.height - s) / 2,
                                 width: s, height: s),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
        out.unlockFocus()
        return out
    }

    // MARK: 激活与窗口置顶
    private func activate(_ item: SwitcherItem) {
        NSRunningApplication(processIdentifier: item.pid)?
            .activate(options: [.activateIgnoringOtherApps])
        raiseWindow(item)
    }

    /// 用 AX 按「标题 + 位置」双匹配定位窗口，避免同名窗口认错
    private func findAXWindow(_ item: SwitcherItem) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(item.pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return nil }

        var exact: AXUIElement?
        var titleOnly: AXUIElement?
        for win in windows {
            var t: AnyObject?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t)
            let title = (t as? String) ?? ""
            var pos = CGPoint.zero
            var p: AnyObject?
            if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &p) == .success,
               let pv = p {
                AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
            }
            let posOK = abs(pos.x - item.bounds.origin.x) < 3 && abs(pos.y - item.bounds.origin.y) < 3
            if title == item.title, posOK { exact = win; break }
            if !item.title.isEmpty, title == item.title, titleOnly == nil { titleOnly = win }
            if item.title.isEmpty, posOK, exact == nil { exact = win }
        }
        return exact ?? titleOnly ?? windows.first
    }

    private func raiseWindow(_ item: SwitcherItem) {
        guard let target = findAXWindow(item) else { return }
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue!)
    }

    /// 点击缩略图右上角的 ×：触发应用自身的关闭按钮（保留「是否保存」等确认流程）
    private func closeWindow(_ item: SwitcherItem) {
        guard let win = findAXWindow(item) else { return }
        var btn: AnyObject?
        if AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &btn) == .success,
           let closeBtn = btn {
            AXUIElementPerformAction(closeBtn as! AXUIElement, kAXPressAction as CFString)
        }
    }

    // MARK: 屏幕录制权限（缩略图需要，首次呼出时申请一次）
    private func ensureScreenPermission() {
        guard !askedScreenPermission else { return }
        askedScreenPermission = true
        if !CGPreflightScreenCaptureAccess() {
            log("requesting screen recording permission for thumbnails")
            CGRequestScreenCaptureAccess()
        }
    }
}

// MARK: - Win 键应用启动器（列出 Dock 常驻应用，类似 Windows 开始菜单）
// 单独点按 Win 键（macOS 上 = Command）呼出；点击图标启动/切换，支持输入过滤，
// Enter 启动第一个匹配，Esc 或点击面板外关闭。

/// 可成为 key window 的无边框面板（接收键盘输入用于搜索）
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct DockApp {
    let name: String
    let url: URL
    let icon: NSImage
}

final class AppLauncherController: NSObject, NSTextFieldDelegate {

    var log: (String) -> Void = { _ in }
    private(set) var isVisible = false
    var panelFrame: NSRect? { panel?.frame }

    private var panel: NSPanel?
    private var searchField: NSTextField?
    private var grid: NSView?
    private var allApps: [DockApp] = []
    private var filtered: [DockApp] = []

    private let cols = 6
    private let cellW: CGFloat = 104
    private let cellH: CGFloat = 98
    private let pad: CGFloat = 16

    func toggle() { isVisible ? hide() : show() }

    func show() {
        hide()
        loadDockApps()
        guard !allApps.isEmpty else { return }
        filtered = allApps
        buildPanel()
        rebuildGrid()
        isVisible = true
        panel?.makeKeyAndOrderFront(nil)
        if let sf = searchField { panel?.makeFirstResponder(sf) }
        log("launcher shown, \(allApps.count) dock apps")
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        isVisible = false
    }

    // MARK: Dock 常驻应用
    private func loadDockApps() {
        let path = NSHomeDirectory() + "/Library/Preferences/com.apple.dock.plist"
        guard let dict = NSDictionary(contentsOfFile: path),
              let tiles = dict["persistent-apps"] as? [[String: Any]] else { return }
        var apps: [DockApp] = []
        var seen = Set<String>()
        for tile in tiles {
            let data = (tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
            guard let urlStr = data?["_CFURLString"] as? String,
                  let url = URL(string: urlStr), !seen.contains(urlStr) else { continue }
            seen.insert(urlStr)
            let name = (tile["tile-data"] as? [String: Any])?["file-label"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 64, height: 64)
            apps.append(DockApp(name: name, url: url, icon: icon))
        }
        allApps = apps
    }

    // MARK: 面板与网格
    private func buildPanel() {
        let rows = max(1, Int(ceil(Double(allApps.count) / Double(cols))))
        let w = pad * 2 + CGFloat(cols) * cellW
        let searchH: CGFloat = 34
        let h = pad + searchH + 10 + CGFloat(rows) * cellH + pad
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        // 类似 Windows 开始菜单：底部居中，贴着 Dock 上方
        let origin = NSPoint(x: vf.midX - w / 2, y: vf.minY + 40)

        let p = KeyPanel(contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.material = .popover
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        p.contentView = blur

        let sf = NSTextField(frame: NSRect(x: pad, y: h - pad - searchH, width: w - pad * 2, height: searchH))
        sf.placeholderString = "搜索应用…"
        sf.bezelStyle = .roundedBezel
        sf.font = .systemFont(ofSize: 14)
        sf.delegate = self
        blur.addSubview(sf)
        searchField = sf

        let g = NSView(frame: NSRect(x: pad, y: pad, width: w - pad * 2, height: CGFloat(rows) * cellH))
        blur.addSubview(g)
        grid = g
        panel = p
    }

    private func rebuildGrid() {
        guard let grid else { return }
        grid.subviews.forEach { $0.removeFromSuperview() }
        for (i, app) in filtered.enumerated() {
            let col = i % cols, row = i / cols
            let b = NSButton(frame: NSRect(x: CGFloat(col) * cellW,
                                           y: grid.bounds.height - CGFloat(row + 1) * cellH,
                                           width: cellW, height: cellH))
            b.isBordered = false
            b.image = app.icon
            b.imageScaling = .scaleProportionallyUpOrDown
            b.imagePosition = .imageAbove
            b.title = app.name
            b.font = .systemFont(ofSize: 11)
            b.cell?.lineBreakMode = .byTruncatingMiddle
            b.tag = i
            b.target = self
            b.action = #selector(launchApp(_:))
            grid.addSubview(b)
        }
    }

    // MARK: 搜索 / 键盘
    func controlTextDidChange(_ obj: Notification) {
        let q = searchField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        filtered = q.isEmpty ? allApps
                             : allApps.filter { $0.name.localizedCaseInsensitiveContains(q) }
        rebuildGrid()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {   // Enter：启动第一个匹配
            if let first = filtered.first { open(first) }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { // Esc：关闭
            hide()
            return true
        }
        return false
    }

    // MARK: 启动
    @objc private func launchApp(_ sender: NSButton) {
        guard filtered.indices.contains(sender.tag) else { return }
        open(filtered[sender.tag])
    }

    private func open(_ app: DockApp) {
        hide()
        log("launch \(app.name)")
        NSWorkspace.shared.openApplication(at: app.url,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}

// MARK: - 入口
let app = NSApplication.shared
let ctrl = MouseFixController()
app.delegate = ctrl
app.setActivationPolicy(.accessory)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)