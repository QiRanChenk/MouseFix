import Cocoa
import ApplicationServices

// Synthetic event marker (防递归)
private let kSyntheticMarker: Int64 = 0x4D4F4F53 // 'MOOS'

final class MouseFixController: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?

    var reverseScroll = true
    var winKeyRemap = true

    // MARK: - 生命周期
    func applicationDidFinishLaunching(_ n: Notification) {
        setupLog()
        setupMenu()
        if !AXIsProcessTrusted() {
            showAccessibilityAlert()
        }
        installEventTap()
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
        statusItem.button?.title = "MouseFix"
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(makeItem(#selector(toggleScroll), "反向鼠标滚轮"))
        m.addItem(makeItem(#selector(toggleKeyRemap), "Windows 风格 Ctrl 快捷键"))
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
    }

    private func setCheck(_ item: NSMenuItem, on: Bool) {
        let raw = item.title
            .replacingOccurrences(of: "\u{2713} ", with: "")
            .replacingOccurrences(of: "  ", with: "")
        item.title = (on ? "\u{2713} " : "  ") + raw
    }

    @objc private func toggleScroll()   { reverseScroll.toggle(); syncMenuTitles() }
    @objc private func toggleKeyRemap() { winKeyRemap.toggle(); syncMenuTitles() }
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
    // Ctrl+C/V/X/A → Cmd+C/V/X/A；Ctrl+Q → Ctrl+A（保留系统的"移到行首"）。
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
    }

    private func processKey(_ event: CGEvent) -> Unmanaged<CGEvent>? {
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
        case Key.c, Key.v, Key.x, Key.a:
            // Ctrl 换成 Cmd，其余修饰键（如 Shift）原样保留
            var f = flags
            f.remove(.maskControl)
            f.insert(.maskCommand)
            event.flags = f
        case Key.q:
            // Ctrl+Q → Ctrl+A：交给系统原生的"行首"行为
            event.setIntegerValueField(.keyboardEventKeycode, value: Key.a)
        default:
            break
        }
        return Unmanaged.passRetained(event)
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

// MARK: - 入口
let app = NSApplication.shared
let ctrl = MouseFixController()
app.delegate = ctrl
app.setActivationPolicy(.accessory)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)