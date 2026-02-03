//
//  AppDelegate.swift
//  Spiggot
//
//  Main application delegate with menu bar UI
//

import Cocoa
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    
    private var statusItem: NSStatusItem!
    private var cameraCapture: CameraCapture?
    private var settingsWindowController: SettingsWindowController?
    private var frameCountMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var startStopMenuItem: NSMenuItem!
    private var autofocusMenuItem: NSMenuItem!
    private var autofocusHoldMenuItem: NSMenuItem!
    private var autofocusHoldPresetItems: [NSMenuItem] = []
    private var startAtLoginMenuItem: NSMenuItem!
    private var autoStartOnSyphonClientMenuItem: NSMenuItem!
    private var autoStopWhenNoSyphonClientsMenuItem: NSMenuItem!
    private var pendingAutoStopWorkItem: DispatchWorkItem?
    private var aboutWindow: NSWindow?
    private var licensesTextView: NSTextView?

    private enum DefaultsKeys {
        static let autoStartOnSyphonClient = "AutoStartOnSyphonClient"
        static let autoStopWhenNoSyphonClients = "AutoStopWhenNoSyphonClients"
    }

    private enum SyphonAutoStopTiming {
        static let graceSeconds: TimeInterval = 3.0
    }

    private var autoStartOnSyphonClientEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKeys.autoStartOnSyphonClient) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKeys.autoStartOnSyphonClient) }
    }

    private var autoStopWhenNoSyphonClientsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKeys.autoStopWhenNoSyphonClients) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKeys.autoStopWhenNoSyphonClients) }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        installMinimalMainMenu()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            if let image = NSImage(named: "MenuBarIcon") {
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Camera")
            }

            button.image?.isTemplate = true
        }
        
        // Create menu
        let menu = NSMenu()
        menu.delegate = self
        
        statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        frameCountMenuItem = NSMenuItem(title: "Frames: 0", action: nil, keyEquivalent: "")
        frameCountMenuItem.isEnabled = false
        menu.addItem(frameCountMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        startStopMenuItem = NSMenuItem(title: "Start Capture", action: #selector(toggleCapture), keyEquivalent: "s")
        menu.addItem(startStopMenuItem)

        startAtLoginMenuItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleStartAtLogin),
            keyEquivalent: ""
        )
        startAtLoginMenuItem.target = self
        menu.addItem(startAtLoginMenuItem)

        autoStartOnSyphonClientMenuItem = NSMenuItem(
            title: "Auto-start on Syphon connect",
            action: #selector(toggleAutoStartOnSyphonClient),
            keyEquivalent: ""
        )
        autoStartOnSyphonClientMenuItem.target = self
        autoStartOnSyphonClientMenuItem.state = autoStartOnSyphonClientEnabled ? .on : .off
        menu.addItem(autoStartOnSyphonClientMenuItem)

        autoStopWhenNoSyphonClientsMenuItem = NSMenuItem(
            title: "Auto-stop when no Syphon clients",
            action: #selector(toggleAutoStopWhenNoSyphonClients),
            keyEquivalent: ""
        )
        autoStopWhenNoSyphonClientsMenuItem.target = self
        autoStopWhenNoSyphonClientsMenuItem.state = autoStopWhenNoSyphonClientsEnabled ? .on : .off
        menu.addItem(autoStopWhenNoSyphonClientsMenuItem)

        autofocusMenuItem = NSMenuItem(title: "Refocus Autofocus", action: #selector(refocusAutofocus), keyEquivalent: "f")
        autofocusMenuItem.keyEquivalentModifierMask = [.command, .shift]
        autofocusMenuItem.target = self
        menu.addItem(autofocusMenuItem)

        autofocusHoldMenuItem = NSMenuItem(title: "Autofocus Hold", action: nil, keyEquivalent: "")
        autofocusHoldMenuItem.submenu = makeAutofocusHoldMenu()
        menu.addItem(autofocusHoldMenuItem)

        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))

        let aboutItem = NSMenuItem(title: "About Spiggot…", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu

        updateStartAtLoginMenuUI()
        
        // Initialize camera capture
        cameraCapture = CameraCapture()
        
        if cameraCapture == nil {
            statusMenuItem.title = "Status: Metal init failed"
        }
        
        cameraCapture?.onStatusUpdate = { [weak self] status in
            DispatchQueue.main.async {
                self?.statusMenuItem.title = "Status: \(status)"
            }
        }
        
        cameraCapture?.onFrameCount = { [weak self] count in
            DispatchQueue.main.async {
                self?.frameCountMenuItem.title = "Frames: \(count)"
            }
        }

        cameraCapture?.onSyphonHasClientsChanged = { [weak self] hasClients in
            self?.handleSyphonClientsChanged(hasClients: hasClients)
        }

        updateAutofocusHoldMenuUI()
    }

    private func installMinimalMainMenu() {
        // Status-item apps can still trigger AppKit warnings if the app menu exists
        // but isn't actually attached to the main menu. Provide a tiny, valid main
        // menu to keep the menu system internally consistent.
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Spiggot"

        let mainMenu = NSMenu(title: "Main Menu")
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: appName)
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(title: "About \(appName)…", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        NSApp.mainMenu = mainMenu
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateAutofocusHoldMenuUI()
        updateStartAtLoginMenuUI()
    }

    private func updateStartAtLoginMenuUI() {
        guard startAtLoginMenuItem != nil else { return }

        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            startAtLoginMenuItem.isEnabled = true

            switch status {
            case .enabled:
                startAtLoginMenuItem.state = .on
                startAtLoginMenuItem.toolTip = ""
            case .requiresApproval:
                startAtLoginMenuItem.state = .mixed
                startAtLoginMenuItem.toolTip = "Requires approval in System Settings → Login Items"
            case .notRegistered:
                startAtLoginMenuItem.state = .off
                startAtLoginMenuItem.toolTip = ""
            case .notFound:
                startAtLoginMenuItem.state = .off
                startAtLoginMenuItem.toolTip = "Unable to locate app for login item registration"
            @unknown default:
                startAtLoginMenuItem.state = .off
                startAtLoginMenuItem.toolTip = ""
            }
        } else {
            startAtLoginMenuItem.state = .off
            startAtLoginMenuItem.isEnabled = true
            startAtLoginMenuItem.toolTip = "Start at Login requires macOS 13+"
        }
    }

    @objc private func toggleStartAtLogin() {
        guard #available(macOS 13.0, *) else {
            statusMenuItem.title = "Status: Start at Login requires macOS 13+"
            NSSound.beep()
            return
        }

        do {
            let service = SMAppService.mainApp
            switch service.status {
            case .enabled:
                try service.unregister()
            case .notRegistered, .requiresApproval, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        } catch {
            statusMenuItem.title = "Status: Failed to update Start at Login"
        }

        updateStartAtLoginMenuUI()

        if SMAppService.mainApp.status == .requiresApproval {
            statusMenuItem.title = "Status: Approve Start at Login in Settings"
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func makeAutofocusHoldMenu() -> NSMenu {
        let submenu = NSMenu()

        func addPreset(_ seconds: Int) {
            let title = "\(seconds)s"
            let item = NSMenuItem(title: title, action: #selector(setAutofocusHoldPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            submenu.addItem(item)
            autofocusHoldPresetItems.append(item)
        }

        [3, 5, 10, 15, 20].forEach(addPreset)

        submenu.addItem(.separator())

        let custom = NSMenuItem(title: "Custom…", action: #selector(setAutofocusHoldCustom(_:)), keyEquivalent: "")
        custom.target = self
        submenu.addItem(custom)

        return submenu
    }

    private func updateAutofocusHoldMenuUI() {
        guard let capture = cameraCapture else { return }

        let seconds = capture.autofocusHoldSeconds
        let rounded = Int(seconds.rounded())
        autofocusHoldMenuItem.title = "Autofocus Hold (\(rounded)s)"

        // Mark the nearest matching preset if we're effectively on it.
        let tolerance: TimeInterval = 0.05
        for item in autofocusHoldPresetItems {
            let preset = TimeInterval(item.tag)
            item.state = abs(seconds - preset) <= tolerance ? .on : .off
        }
    }

    @objc private func setAutofocusHoldPreset(_ sender: NSMenuItem) {
        guard let capture = cameraCapture else { return }
        capture.autofocusHoldSeconds = TimeInterval(sender.tag)
        updateAutofocusHoldMenuUI()
    }

    @objc private func setAutofocusHoldCustom(_ sender: NSMenuItem) {
        guard let capture = cameraCapture else { return }

        let alert = NSAlert()
        alert.messageText = "Autofocus Hold Duration"
        alert.informativeText = "Enter the number of seconds to keep autofocus engaged before releasing."
        alert.alertStyle = .informational

        let field = NSTextField(string: String(format: "%.1f", capture.autofocusHoldSeconds))
        field.placeholderString = "Seconds"
        field.alignment = .right
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(raw) {
            capture.autofocusHoldSeconds = value
            updateAutofocusHoldMenuUI()
        } else {
            capture.onStatusUpdate?("Invalid autofocus hold duration")
        }
    }

    @objc func refocusAutofocus() {
        guard let capture = cameraCapture else { return }

        capture.onStatusUpdate?("Refocusing…")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = capture.triggerAutofocus()
            switch result {
            case .success:
                capture.onStatusUpdate?("Autofocus triggered")
            case .failure(let error):
                capture.onStatusUpdate?(error.localizedDescription)
            }
        }
    }

    @objc func showAbout(_ sender: Any?) {
        if aboutWindow == nil {
            aboutWindow = makeAboutWindow()
        }

        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeAboutWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Spiggot"
        window.isReleasedWhenClosed = false
        window.center()

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        window.contentView = contentView

        let tabView = NSTabView(frame: contentView.bounds.insetBy(dx: 16, dy: 16))
        tabView.autoresizingMask = [.width, .height]

        // About tab
        let aboutTab = NSTabViewItem(identifier: "about")
        aboutTab.label = "About"
        aboutTab.view = makeAboutTabView()

        // Licenses tab
        let licensesTab = NSTabViewItem(identifier: "licenses")
        licensesTab.label = "Licenses"
        licensesTab.view = makeLicensesTabView()

        tabView.addTabViewItem(aboutTab)
        tabView.addTabViewItem(licensesTab)

        contentView.addSubview(tabView)

        return window
    }

    private func makeAboutTabView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.autoresizingMask = [.width, .height]

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let nameField = NSTextField(labelWithString: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Spiggot")
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = NSFont.systemFont(ofSize: 20, weight: .semibold)

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let versionString: String
        if let shortVersion, let buildVersion {
            versionString = "Version \(shortVersion) (\(buildVersion))"
        } else if let shortVersion {
            versionString = "Version \(shortVersion)"
        } else {
            versionString = ""
        }

        let versionField = NSTextField(labelWithString: versionString)
        versionField.translatesAutoresizingMaskIntoConstraints = false
        versionField.textColor = .secondaryLabelColor

        let copyrightField = NSTextField(labelWithString: "Copyright © \(Calendar.current.component(.year, from: Date())) Rickard Holmberg")
        copyrightField.translatesAutoresizingMaskIntoConstraints = false
        copyrightField.textColor = .secondaryLabelColor

        let hintField = NSTextField(wrappingLabelWithString: "Third-party licenses and notices are available in the Licenses tab.")
        hintField.translatesAutoresizingMaskIntoConstraints = false
        hintField.textColor = .secondaryLabelColor

        view.addSubview(iconView)
        view.addSubview(nameField)
        view.addSubview(versionField)
        view.addSubview(copyrightField)
        view.addSubview(hintField)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),

            nameField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            nameField.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            versionField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 6),
            versionField.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            copyrightField.topAnchor.constraint(equalTo: versionField.bottomAnchor, constant: 6),
            copyrightField.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            hintField.topAnchor.constraint(equalTo: copyrightField.bottomAnchor, constant: 18),
            hintField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            hintField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        return view
    }

    private func makeLicensesTabView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.autoresizingMask = [.width, .height]

        // Use the system helper to create a correctly-configured scroll + text view
        // so we don't end up with a zero-sized document view.
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.width, .height]

        guard let textView = scrollView.documentView as? NSTextView else {
            return view
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.string = loadLicensesText()

        licensesTextView = textView
        view.addSubview(scrollView)
        return view
    }

    private func loadLicensesText() -> String {
        var parts: [String] = []

        if let url = Bundle.main.url(forResource: "Licenses", withExtension: "txt") {
            do {
                parts.append(try String(contentsOf: url, encoding: .utf8))
            } catch {
                parts.append("Failed to load Licenses.txt from the app bundle: \(error)")
            }
        } else {
            parts.append("Licenses.txt is missing from the app bundle.\n\nThis build may be misconfigured.")
        }

        if let url = Bundle.main.url(forResource: "LGPL-2.1", withExtension: "txt") {
            do {
                parts.append("\n\n===========================\nGNU LGPL v2.1 (full text)\n===========================\n")
                parts.append(try String(contentsOf: url, encoding: .utf8))
            } catch {
                parts.append("\n\nFailed to load LGPL-2.1.txt from the app bundle: \(error)")
            }
        }

        return parts.joined(separator: "\n")
    }

    @objc func openSettings() {
        guard let capture = cameraCapture else { return }

        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(cameraCapture: capture)
        }

        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func toggleCapture() {
        guard let capture = cameraCapture else { return }
        
        if capture.isRunning {
            stopCaptureNow(source: "manual")
        } else {
            _ = startCaptureIfNeeded(source: "manual")
        }

        // Keep the menu bar icon consistent (SVG-derived template image).
        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon") ?? button.image
            button.image?.isTemplate = true
        }
    }

    private func startCaptureIfNeeded(source: String) -> Bool {
        guard let capture = cameraCapture else { return false }
        guard !capture.isRunning else { return false }

        if capture.start() {
            startStopMenuItem.title = "Stop Capture"
            statusMenuItem.title = "Status: Running"

            if let button = statusItem.button {
                button.image = NSImage(named: "MenuBarIcon") ?? button.image
                button.image?.isTemplate = true
            }

            pendingAutoStopWorkItem?.cancel()
            pendingAutoStopWorkItem = nil

            return true
        }

        // If start failed, keep UI in a sensible state.
        statusMenuItem.title = "Status: Idle"
        return false
    }

    private func stopCaptureNow(source: String) {
        guard let capture = cameraCapture else { return }
        guard capture.isRunning else { return }

        capture.stop()
        startStopMenuItem.title = "Start Capture"
        statusMenuItem.title = "Status: Stopped"

        pendingAutoStopWorkItem?.cancel()
        pendingAutoStopWorkItem = nil
    }

    private func scheduleAutoStopIfNeeded() {
        guard autoStopWhenNoSyphonClientsEnabled else { return }
        guard let capture = cameraCapture, capture.isRunning else { return }
        guard pendingAutoStopWorkItem == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only stop if we still have no clients.
            guard (self.cameraCapture?.isRunning ?? false) else { return }
            guard let hasClients = self.cameraCapture?.syphonHasClientsForUI(), hasClients == false else { return }
            self.stopCaptureNow(source: "auto")
        }

        pendingAutoStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SyphonAutoStopTiming.graceSeconds, execute: work)
    }

    private func handleSyphonClientsChanged(hasClients: Bool) {
        if hasClients {
            pendingAutoStopWorkItem?.cancel()
            pendingAutoStopWorkItem = nil

            guard autoStartOnSyphonClientEnabled else { return }
            _ = startCaptureIfNeeded(source: "syphon")
        } else {
            scheduleAutoStopIfNeeded()
        }
    }

    @objc private func toggleAutoStartOnSyphonClient() {
        autoStartOnSyphonClientEnabled.toggle()
        autoStartOnSyphonClientMenuItem.state = autoStartOnSyphonClientEnabled ? .on : .off

        // If enabled while a client is already connected, start immediately.
        if autoStartOnSyphonClientEnabled,
           let hasClients = cameraCapture?.syphonHasClientsForUI(),
           hasClients {
            _ = startCaptureIfNeeded(source: "syphon")
        }
    }

    @objc private func toggleAutoStopWhenNoSyphonClients() {
        autoStopWhenNoSyphonClientsEnabled.toggle()
        autoStopWhenNoSyphonClientsMenuItem.state = autoStopWhenNoSyphonClientsEnabled ? .on : .off

        if autoStopWhenNoSyphonClientsEnabled,
           let hasClients = cameraCapture?.syphonHasClientsForUI(),
           hasClients == false {
            scheduleAutoStopIfNeeded()
        } else if !autoStopWhenNoSyphonClientsEnabled {
            pendingAutoStopWorkItem?.cancel()
            pendingAutoStopWorkItem = nil
        }
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        cameraCapture?.stop()
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
