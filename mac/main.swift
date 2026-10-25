// TV Display: menu-bar app that turns an Android TV running the TV Display receiver into a
// wireless extended display. Streaming lives in Stream.swift; this file is the UI.
//
//   open TVDisplay.app [--args <tv-ip>]

import AppKit
import ScreenCaptureKit
import ServiceManagement

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Preferences

enum Prefs {
    static let d = UserDefaults.standard
    /// The TV's IP address: from discovery, or typed in by hand. Nil until a TV is chosen.
    static var host: String? {
        get { d.string(forKey: "host") }
        set { d.set(newValue, forKey: "host") }
    }
    static var port: UInt16 {
        get { UInt16(d.integer(forKey: "port") == 0 ? 7777 : d.integer(forKey: "port")) }
        set { d.set(Int(newValue), forKey: "port") }
    }
    /// The chosen TV's network name; nil when the address was typed in by hand.
    static var tvName: String? {
        get { d.string(forKey: "tvName") }
        set { d.set(newValue, forKey: "tvName") }
    }
    static var textSize: TextSize {
        get { TextSize(rawValue: d.integer(forKey: "textSize")) ?? .normal }
        set { d.set(newValue.rawValue, forKey: "textSize") }
    }
    static var fps: Int {
        get { d.object(forKey: "fps") as? Int ?? 60 }
        set { d.set(newValue, forKey: "fps") }
    }
    static var mbps: Int {
        get { d.object(forKey: "mbps") as? Int ?? 8 }
        set { d.set(newValue, forKey: "mbps") }
    }
    static var audioOnTV: Bool {
        get { d.bool(forKey: "audioOnTV") }
        set { d.set(newValue, forKey: "audioOnTV") }
    }
    static var welcomed: Bool {
        get { d.bool(forKey: "welcomed") }
        set { d.set(newValue, forKey: "welcomed") }
    }
}

// MARK: - Controller

final class Controller: NSObject, NSMenuDelegate {
    enum State: Equatable {
        case off, searching, starting, needsPermission, waiting, streaming, failed(String)
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var session: StreamSession?
    private var state: State = .off { didSet { refresh() } }
    private var statsText = ""
    private var statsTimer: Timer?
    private var permissionTimer: Timer?
    private let discovery = Discovery()
    private let tvMenu = NSMenu()

    private var tvLabel: String { Prefs.tvName ?? Prefs.host ?? "TV" }

    // Menu items that change while the menu is open
    private let statusLine = NSMenuItem()
    private let statsLine = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private let permissionItem = NSMenuItem()

    override init() {
        super.init()
        buildMenu()
        statusItem.menu = menu
        refresh()

        statsTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(statsTimer!, forMode: .common) // keep ticking while the menu is open

        discovery.onChange = { [weak self] tvs in self?.found(tvs) }
        discovery.start()
    }

    // MARK: Finding the TV

    /// New discovery results: pick a TV on first run, and follow the chosen TV if its address changes.
    private func found(_ tvs: [FoundTV]) {
        if Prefs.host == nil, let first = tvs.first {
            choose(first)
        } else if let name = Prefs.tvName, let tv = tvs.first(where: { $0.name == name }),
                  tv.ip != Prefs.host || tv.port != Prefs.port {
            log("\(name) moved to \(tv.ip)")
            Prefs.host = tv.ip
            Prefs.port = tv.port
            if let s = session, !s.connected { restartIfOn() }
        }
        if state == .searching, Prefs.host != nil { state = .off; turnOn() }
        refresh()
    }

    private func choose(_ tv: FoundTV) {
        Prefs.tvName = tv.name
        Prefs.host = tv.ip
        Prefs.port = tv.port
        log("using \(tv.name) at \(tv.ip):\(tv.port)")
    }

    @objc func pickTV(_ sender: NSMenuItem) {
        guard sender.tag < discovery.tvs.count else { return }
        let tv = discovery.tvs[sender.tag]
        let changed = tv.name != Prefs.tvName || tv.ip != Prefs.host
        choose(tv)
        if changed { restartIfOn() }
        if session == nil { turnOn() }
    }

    private func rebuildTVMenu() {
        tvMenu.removeAllItems()
        if discovery.tvs.isEmpty {
            let none = NSMenuItem(title: "Looking for TVs…", action: nil, keyEquivalent: "")
            none.isEnabled = false
            tvMenu.addItem(none)
        }
        for (i, tv) in discovery.tvs.enumerated() {
            let it = item(tv.name, #selector(pickTV(_:)))
            it.tag = i
            it.state = tv.name == Prefs.tvName ? .on : .off
            it.toolTip = "\(tv.ip):\(tv.port)"
            tvMenu.addItem(it)
        }
        tvMenu.addItem(.separator())
        let manual = item(Prefs.tvName == nil && Prefs.host != nil ? "Address: \(Prefs.host!)…" : "Enter Address Manually…",
                          #selector(editAddress))
        if Prefs.tvName == nil && Prefs.host != nil { manual.state = .on }
        tvMenu.addItem(manual)
    }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        let header = NSMenuItem()
        header.attributedTitle = NSAttributedString(string: "TV Display", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)])
        header.isEnabled = false
        menu.addItem(header)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        statsLine.isEnabled = false
        menu.addItem(statsLine)
        menu.addItem(.separator())

        toggleItem.action = #selector(toggle)
        toggleItem.target = self
        toggleItem.keyEquivalent = "t"
        menu.addItem(toggleItem)
        permissionItem.title = "Allow Screen Recording…"
        permissionItem.action = #selector(openPrivacy)
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(item("Arrange Displays…", #selector(openDisplays)))
        menu.addItem(.separator())

        let tvItem = NSMenuItem(title: "TV", action: nil, keyEquivalent: "")
        tvItem.submenu = tvMenu
        menu.addItem(tvItem)

        let textMenu = NSMenu()
        for size in TextSize.allCases {
            let i = item(size.title, #selector(setTextSize(_:)))
            i.tag = size.rawValue
            textMenu.addItem(i)
        }
        let textItem = NSMenuItem(title: "Text Size", action: nil, keyEquivalent: "")
        textItem.submenu = textMenu
        menu.addItem(textItem)

        let fpsMenu = NSMenu()
        for f in [30, 60] {
            let i = item("\(f) fps", #selector(setFps(_:)))
            i.tag = f
            fpsMenu.addItem(i)
        }
        let fpsItem = NSMenuItem(title: "Frame Rate", action: nil, keyEquivalent: "")
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)

        let qMenu = NSMenu()
        for (name, m) in [("Balanced — 5 Mbps", 5), ("High — 8 Mbps", 8), ("Maximum — 12 Mbps", 12)] {
            let i = item(name, #selector(setQuality(_:)))
            i.tag = m
            qMenu.addItem(i)
        }
        let qItem = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        qItem.submenu = qMenu
        menu.addItem(qItem)

        if #available(macOS 14.2, *) {
            let sMenu = NSMenu()
            for (name, tv) in [("Mac Speakers", false), ("TV Speakers", true)] {
                let i = item(name, #selector(setSound(_:)))
                i.tag = tv ? 1 : 0
                sMenu.addItem(i)
            }
            let sItem = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
            sItem.submenu = sMenu
            menu.addItem(sItem)
        }

        if Adb.path != nil {
            menu.addItem(item("Open Receiver on TV", #selector(openReceiver)))
        }
        let login = item("Open at Login", #selector(toggleLogin(_:)))
        login.identifier = NSUserInterfaceItemIdentifier("login")
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("About TV Display", #selector(about)))
        menu.addItem(item("Quit TV Display", #selector(quit), key: "q"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        rebuildTVMenu()
        for i in menu.items {
            if let sub = i.submenu {
                for s in sub.items {
                    if s.action == #selector(setFps(_:)) { s.state = s.tag == Prefs.fps ? .on : .off }
                    if s.action == #selector(setQuality(_:)) { s.state = s.tag == Prefs.mbps ? .on : .off }
                    if s.action == #selector(setSound(_:)) { s.state = (s.tag == 1) == Prefs.audioOnTV ? .on : .off }
                    if s.action == #selector(setTextSize(_:)) { s.state = s.tag == Prefs.textSize.rawValue ? .on : .off }
                }
            }
            if i.identifier?.rawValue == "login" {
                i.state = SMAppService.mainApp.status == .enabled ? .on : .off
            }
            if i.submenu === tvMenu { i.title = Prefs.host == nil ? "TV" : "TV: \(tvLabel)" }
        }
    }

    private func dot(_ color: NSColor, _ text: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "●  ", attributes: [.foregroundColor: color,
                                                                     .font: NSFont.systemFont(ofSize: 10)])
        s.append(NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0),
                                                               .foregroundColor: NSColor.labelColor]))
        return s
    }

    private func refresh() {
        let on: Bool
        switch state {
        case .off:
            statusLine.attributedTitle = dot(.tertiaryLabelColor, "Off")
            on = false
        case .searching:
            statusLine.attributedTitle = dot(.systemYellow, "Looking for your TV…")
            on = true
        case .starting:
            statusLine.attributedTitle = dot(.systemYellow, "Starting…")
            on = true
        case .needsPermission:
            statusLine.attributedTitle = dot(.systemOrange, "Needs Screen Recording permission")
            on = false
        case .waiting:
            statusLine.attributedTitle = dot(.systemYellow, "Connecting to \(tvLabel)…")
            on = true
        case .streaming:
            statusLine.attributedTitle = dot(.systemGreen, "Streaming to \(tvLabel)")
            on = true
        case .failed(let msg):
            statusLine.attributedTitle = dot(.systemRed, msg)
            on = false
        }
        statsLine.attributedTitle = NSAttributedString(string: "     " + statsText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor])
        statsLine.isHidden = state != .streaming || statsText.isEmpty
        toggleItem.title = on ? "Turn Off TV Display" : "Turn On TV Display"
        permissionItem.isHidden = state != .needsPermission

        let symbol: String
        switch state {
        case .streaming: symbol = "tv.fill"
        case .needsPermission, .failed: symbol = "exclamationmark.triangle"
        default: symbol = "tv"
        }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "TV Display") {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "TV"
        }
        statusItem.button?.appearsDisabled = state == .off
        statusItem.button?.toolTip = "TV Display — " + (statusLine.attributedTitle?.string.dropFirst(3).description ?? "")
    }

    // MARK: Streaming

    @objc func toggle() {
        if session != nil || state == .starting || state == .searching { turnOff() } else { turnOn() }
    }

    func turnOn() {
        guard session == nil else { return }
        guard let host = Prefs.host else {
            // First run: wait for discovery to find a TV (found() starts streaming then).
            state = .searching
            return
        }
        guard hasScreenRecording(prompt: true) else {
            state = .needsPermission
            watchForPermission()
            return
        }
        state = .starting
        statsText = ""
        let settings = StreamSettings(host: host, port: Prefs.port, fps: Prefs.fps, mbps: Prefs.mbps,
                                      textSize: Prefs.textSize)
        Task { @MainActor in
            do {
                let s = try StreamSession(settings)
                s.onError = { err in
                    DispatchQueue.main.async { self.fail(err) }
                }
                session = s
                try await s.start()
                s.setAudioOnTV(Prefs.audioOnTV)
                if state == .starting { state = .waiting }
            } catch {
                session = nil
                fail(error)
            }
        }
    }

    func turnOff() {
        session?.stop()
        session = nil
        statsText = ""
        state = .off
    }

    private func fail(_ error: Error) {
        session?.stop()
        session = nil
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue {
            state = .needsPermission
            watchForPermission()
        } else {
            state = .failed(error.localizedDescription)
        }
    }

    private func tick() {
        guard let s = session, state == .waiting || state == .streaming else { return }
        if !s.connected {
            // The TV app starts by itself when the TV is on; just keep trying.
            if state != .waiting { state = .waiting }
            _ = s.takeStats()
            return
        }
        let st = s.takeStats()
        let lat = st.latencies.sorted()
        var parts = ["\(st.frames) fps", String(format: "%.1f Mbps", Double(st.bytes) * 8 / 1e6)]
        if !lat.isEmpty { parts.append(String(format: "%.0f ms", lat.reduce(0, +) / Double(lat.count))) }
        statsText = parts.joined(separator: "  ·  ")
        log(statsText + "  (TV shown \(lat.count)/s" + (st.dropped > 0 ? ", dropped \(st.dropped)" : "") + (st.skipped > 0 ? ", paced \(st.skipped)" : "") + ")")
        if state != .streaming { state = .streaming } else { refresh() }
    }

    private func restartIfOn() {
        guard session != nil else { return }
        turnOff()
        turnOn()
    }

    // MARK: Permission

    private func hasScreenRecording(prompt: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return prompt ? CGRequestScreenCaptureAccess() : false
    }

    private func watchForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.state != .needsPermission { t.invalidate(); return }
            if self.hasScreenRecording(prompt: false) {
                t.invalidate()
                self.turnOn()
            }
        }
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc func openDisplays() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    // MARK: Settings

    @objc func editAddress() {
        if askForAddress() { restartIfOn() }
    }

    /// Returns true if a valid address was saved.
    private func askForAddress() -> Bool {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "TV Address"
        alert.informativeText = "Open TV Display on your TV. Its address is shown in the middle of the screen."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = Prefs.host ?? ""
        field.placeholderString = "192.168.1.20"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let ip = field.stringValue.trimmingCharacters(in: .whitespaces)
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else {
            let bad = NSAlert()
            bad.messageText = "“\(ip)” isn’t a valid IP address."
            bad.runModal()
            return askForAddress()
        }
        Prefs.host = ip
        Prefs.port = 7777
        Prefs.tvName = nil // typed in by hand: stop following discovery
        return true
    }

    @objc func setFps(_ sender: NSMenuItem) { Prefs.fps = sender.tag; restartIfOn() }
    @objc func setQuality(_ sender: NSMenuItem) { Prefs.mbps = sender.tag; restartIfOn() }
    @objc func setTextSize(_ sender: NSMenuItem) {
        Prefs.textSize = TextSize(rawValue: sender.tag) ?? .normal
        session?.apply(textSize: Prefs.textSize) // switches live
    }
    @objc func setSound(_ sender: NSMenuItem) {
        Prefs.audioOnTV = sender.tag == 1
        session?.setAudioOnTV(Prefs.audioOnTV) // switches live, no restart
    }

    @objc func openReceiver() {
        if let h = Prefs.host { Adb.launchReceiver(host: h) }
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert(error: error)
            a.messageText = "Couldn’t change Open at Login"
            a.runModal()
        }
    }

    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Wireless extended display for Android TV.\nInstall TV Display on the TV, then turn it on from the menu bar.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc func quit() {
        turnOff()
        NSApp.terminate(nil)
    }

    func showWelcomeIfNeeded() {
        guard !Prefs.welcomed else { return }
        Prefs.welcomed = true
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        a.messageText = "TV Display is in your menu bar"
        a.informativeText = """
        With TV Display installed on your TV, it finds the TV on your network and connects by \
        itself; the TV switches to it automatically. Your TV appears as a second display: \
        drag any window onto it. Use Text Size in the menu if text is too small to read.

        macOS will ask to find devices on your local network and for Screen Recording \
        permission the first time; both are needed to send the picture to the TV.
        """
        a.addButton(withTitle: "Got It")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - adb helper (optional: opens the receiver on the TV if Android platform tools are installed)

enum Adb {
    static let path: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", home + "/Library/Android/sdk/platform-tools/adb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func launchReceiver(host: String) {
        guard let adb = path else { return }
        DispatchQueue.global().async {
            let target = host + ":5555"
            run(adb, ["connect", target])
            run(adb, ["-s", target, "shell", "am", "start", "-n", "app.tvscreen/.MainActivity"])
            log("asked the TV to open the receiver via adb")
        }
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - Main

if let ip = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
    Prefs.host = ip
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()

// Ctrl-C / kill also remove the virtual display cleanly.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { controller.quit() }
    src.resume()
    signalSources.append(src)
}

DispatchQueue.main.async {
    controller.showWelcomeIfNeeded()
    controller.turnOn()
}
app.run()
