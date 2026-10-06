// Tack: ⌃⌥P で前面のウィンドウを常に手前にピン留めする。
//
// macOS には他アプリのウィンドウを最前面に固定する公開 API がないので、
// 対象ウィンドウを ScreenCaptureKit で取り込み、自前の浮いたパネルに映す。
// パネルをクリックすると本物のウィンドウを同じ位置に出して操作でき、
// 別のアプリに移るとパネルが戻ってくる。

import AppKit
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

// AXUIElement から CGWindowID を引く非公開関数（Rectangle や AltTab も使っている）
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// グローバル座標（左上原点）と Cocoa 座標（左下原点）の変換
func flipY(_ rect: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}

func currentBounds(of windowID: CGWindowID) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
          let dict = list.first?[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
    return rect
}

// MARK: - ミラー表示

final class MirrorView: NSView {
    var onClick: (() -> Void)?
    private var downEvent: NSEvent?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.actions = ["contents": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragged = false
    }

    // ドラッグならパネルを動かし、動かさずに離したらクリック扱い
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let down = downEvent else { return }
        dragged = true
        window?.performDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick?() }
        downEvent = nil
    }
}

// MARK: - ピン 1 つ分

final class Pin: NSObject, SCStreamOutput, SCStreamDelegate, NSWindowDelegate {
    let windowID: CGWindowID
    let pid: pid_t
    let label: String
    var onClose: ((Pin) -> Void)?
    /// 本物のウィンドウを出していてパネルを隠している間 true
    private(set) var showingOriginal = false

    private let scWindow: SCWindow
    private let panel: NSPanel
    private let view: MirrorView
    private var stream: SCStream?
    private var closed = false
    private let queue = DispatchQueue(label: "tack.capture")

    init(window: SCWindow, pid: pid_t) {
        scWindow = window
        windowID = window.windowID
        self.pid = pid
        let app = window.owningApplication?.applicationName ?? "?"
        let title = window.title ?? ""
        label = title.isEmpty ? app : "\(app) — \(title)"

        let frame = flipY(window.frame)
        view = MirrorView(frame: NSRect(origin: .zero, size: frame.size))
        panel = NSPanel(contentRect: frame,
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.contentView = view
        panel.contentAspectRatio = frame.size
        panel.setFrame(frame, display: true)
        panel.delegate = self
        view.onClick = { [weak self] in self?.showOriginal() }
    }

    func start() async throws {
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(scWindow.frame.width * scale)
        config.height = Int(scWindow.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 5

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        await MainActor.run { panel.orderFrontRegardless() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in self?.view.layer?.contents = surface }
    }

    // 元のウィンドウが閉じられるとストリームが止まる
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.close() }
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }

    /// パネルを隠し、本物のウィンドウをパネルの位置に出して前面にする
    func showOriginal() {
        if AXIsProcessTrusted(), let axWindow = axWindow() {
            let frame = flipY(panel.frame)
            var origin = frame.origin
            var size = frame.size
            if let value = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value)
            }
            if let value = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, value)
            }
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
        panel.orderOut(nil)
        showingOriginal = true
    }

    /// 別のアプリに移ったらパネルを元のウィンドウの位置に戻す
    func showMirror() {
        guard showingOriginal, !closed else { return }
        showingOriginal = false
        if let bounds = currentBounds(of: windowID) {
            let frame = flipY(bounds)
            panel.contentAspectRatio = frame.size
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
    }

    func close() {
        guard !closed else { return }
        closed = true
        stream?.stopCapture { _ in }
        stream = nil
        panel.delegate = nil
        panel.close()
        onClose?(self)
    }

    private func axWindow() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { element in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success && id == windowID
        }
    }
}

// MARK: - アプリ本体

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pins: [CGWindowID: Pin] = [:]
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Tack")
        rebuildMenu()
        registerHotKey()

        // クリックで本物のウィンドウを出す機能に使う。無くてもピン留め自体は動く
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // 初回起動時だけログイン項目に入れる。以降はメニューの切り替えに従う
        if !UserDefaults.standard.bool(forKey: "didSetupLoginItem") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetupLoginItem")
            rebuildMenu()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for pin in pins.values where pin.showingOriginal && pin.pid != app.processIdentifier {
            pin.showMirror()
        }
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let controller = Unmanaged<AppController>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { controller.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        let id = EventHotKeyID(signature: OSType(0x5441_434B), id: 1) // 'TACK'
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    /// ⌃⌥P: ピン留め中のものがあれば、どのアプリが前面でも全部外す。無ければ前面のウィンドウを留める。
    /// 前面基準だけにすると、留めた後に別アプリへ移ってから押したとき解除ではなくそのアプリを留めてしまう
    @objc func toggle() {
        if pins.isEmpty {
            pinFrontWindow()
        } else {
            NSLog("Tack: unpin all (%d)", pins.count)
            unpinAll()
        }
    }

    /// 前面アプリの一番手前のウィンドウをピン留めする。既にピン留め済みなら外す
    @objc func pinFrontWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let info = list.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                      && ($0[kCGWindowLayer as String] as? Int) == 0
              }),
              let windowID = info[kCGWindowNumber as String] as? CGWindowID
        else {
            NSSound.beep()
            return
        }

        if let pin = pins[windowID] {
            NSLog("Tack: unpin %u", windowID)
            pin.close()
            return
        }
        NSLog("Tack: pin %u (%@)", windowID, app.localizedName ?? "?")
        let pid = app.processIdentifier
        Task { @MainActor in await self.pin(windowID: windowID, pid: pid) }
    }

    @MainActor private func pin(windowID: CGWindowID, pid: pid_t) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                NSSound.beep()
                return
            }
            let pin = Pin(window: window, pid: pid)
            pin.onClose = { [weak self] closed in
                self?.pins[closed.windowID] = nil
                self?.rebuildMenu()
            }
            pins[windowID] = pin
            try await pin.start()
            rebuildMenu()
        } catch {
            pins[windowID] = nil
            showPermissionAlert(error)
        }
    }

    private func showPermissionAlert(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "画面収録の権限が必要です"
        alert.informativeText = "システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音 で Tack を許可してから、Tack を再起動してください。\n\n(\(error.localizedDescription))"
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "閉じる")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: pins.isEmpty ? "前面のウィンドウをピン留め" : "すべて解除",
                                action: #selector(toggle), keyEquivalent: "p")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.target = self
        menu.addItem(toggle)
        if !pins.isEmpty {
            let add = NSMenuItem(title: "前面のウィンドウを追加でピン留め", action: #selector(pinFrontWindow), keyEquivalent: "")
            add.target = self
            menu.addItem(add)
        }

        if !pins.isEmpty {
            menu.addItem(.separator())
            for pin in pins.values.sorted(by: { $0.label < $1.label }) {
                let item = NSMenuItem(title: "解除: \(pin.label)", action: #selector(unpinItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pin
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Tack を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func unpinItem(_ sender: NSMenuItem) {
        (sender.representedObject as? Pin)?.close()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Tack: login item: %@", error.localizedDescription)
            NSSound.beep()
        }
        rebuildMenu()
    }

    @objc private func unpinAll() {
        pins.values.forEach { $0.close() }
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
