import Cocoa

final class SettingsWindowController: NSWindowController {
    private weak var cameraCapture: CameraCapture?

    private let cameraPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let useButton = NSButton(title: "Use Selection", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private let settingsHeaderLabel = NSTextField(labelWithString: "Camera settings")
    private let loadSettingsButton = NSButton(title: "Load", target: nil, action: nil)
    private let applySettingsButton = NSButton(title: "Apply", target: nil, action: nil)
    private let settingsStatusLabel = NSTextField(labelWithString: "")
    private let settingsScrollView = NSScrollView(frame: .zero)
    private let settingsContainer = NSView(frame: .zero)
    private let settingsStack = NSStackView(frame: .zero)

    private var cameras: [CameraCapture.DetectedCamera] = []
    private var settings: [CameraCapture.RadioSetting] = []
    private var popupBySettingFullPath: [String: NSPopUpButton] = [:]

    init(cameraCapture: CameraCapture) {
        self.cameraCapture = cameraCapture

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        super.init(window: window)

        buildUI()
        refreshCameras()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let cameraLabel = NSTextField(labelWithString: "Camera:")
        cameraLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let separator = NSBox()
        separator.boxType = .separator

        cameraPopup.translatesAutoresizingMaskIntoConstraints = false
        cameraLabel.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        useButton.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false

        settingsHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        loadSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        applySettingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsScrollView.translatesAutoresizingMaskIntoConstraints = false
        settingsContainer.translatesAutoresizingMaskIntoConstraints = false
        settingsStack.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        refreshButton.bezelStyle = .rounded

        useButton.target = self
        useButton.action = #selector(usePressed)
        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        settingsHeaderLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        loadSettingsButton.target = self
        loadSettingsButton.action = #selector(loadSettingsPressed)
        loadSettingsButton.bezelStyle = .rounded

        applySettingsButton.target = self
        applySettingsButton.action = #selector(applySettingsPressed)
        applySettingsButton.bezelStyle = .rounded
        applySettingsButton.isEnabled = false

        settingsStatusLabel.textColor = .secondaryLabelColor
        settingsStatusLabel.lineBreakMode = .byTruncatingTail
        settingsStatusLabel.stringValue = "Click ‘Load’ to fetch RADIO settings."

        settingsScrollView.hasVerticalScroller = true
        settingsScrollView.borderType = .bezelBorder
        settingsScrollView.documentView = settingsContainer

        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.distribution = .fill
        settingsStack.spacing = 10

        settingsContainer.addSubview(settingsStack)

        contentView.addSubview(cameraLabel)
        contentView.addSubview(cameraPopup)
        contentView.addSubview(refreshButton)
        contentView.addSubview(useButton)
        contentView.addSubview(statusLabel)
        contentView.addSubview(separator)
        contentView.addSubview(settingsHeaderLabel)
        contentView.addSubview(loadSettingsButton)
        contentView.addSubview(settingsStatusLabel)
        contentView.addSubview(settingsScrollView)
        contentView.addSubview(applySettingsButton)

        NSLayoutConstraint.activate([
            cameraLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            cameraLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            cameraPopup.leadingAnchor.constraint(equalTo: cameraLabel.trailingAnchor, constant: 12),
            cameraPopup.centerYAnchor.constraint(equalTo: cameraLabel.centerYAnchor),
            cameraPopup.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -12),

            useButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            useButton.centerYAnchor.constraint(equalTo: cameraLabel.centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: useButton.leadingAnchor, constant: -12),
            refreshButton.centerYAnchor.constraint(equalTo: cameraLabel.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: cameraLabel.bottomAnchor, constant: 14),

            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            separator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),

            settingsHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            settingsHeaderLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),

            loadSettingsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            loadSettingsButton.centerYAnchor.constraint(equalTo: settingsHeaderLabel.centerYAnchor),

            settingsStatusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            settingsStatusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            settingsStatusLabel.topAnchor.constraint(equalTo: settingsHeaderLabel.bottomAnchor, constant: 10),

            settingsScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            settingsScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            settingsScrollView.topAnchor.constraint(equalTo: settingsStatusLabel.bottomAnchor, constant: 10),
            settingsScrollView.bottomAnchor.constraint(equalTo: applySettingsButton.topAnchor, constant: -12),

            applySettingsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            applySettingsButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
        ])

        NSLayoutConstraint.activate([
            settingsContainer.widthAnchor.constraint(equalTo: settingsScrollView.contentView.widthAnchor),

            settingsStack.leadingAnchor.constraint(equalTo: settingsContainer.leadingAnchor, constant: 12),
            settingsStack.trailingAnchor.constraint(equalTo: settingsContainer.trailingAnchor, constant: -12),
            settingsStack.topAnchor.constraint(equalTo: settingsContainer.topAnchor, constant: 12),
            settingsStack.bottomAnchor.constraint(equalTo: settingsContainer.bottomAnchor, constant: -12),
        ])
    }

    @objc private func refreshPressed() {
        refreshCameras()
    }

    private func refreshCameras() {
        guard let capture = cameraCapture else { return }

        statusLabel.stringValue = "Scanning…"
        refreshButton.isEnabled = false
        useButton.isEnabled = false
        cameraPopup.removeAllItems()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Serial numbers require briefly opening each camera.
            let cameras = capture.listAvailableCameras(includeSerialNumbers: true)

            DispatchQueue.main.async {
                self.refreshButton.isEnabled = true
                self.cameras = cameras

                if cameras.isEmpty {
                    self.statusLabel.stringValue = "No cameras detected."
                    self.useButton.isEnabled = false
                    return
                }

                self.cameraPopup.removeAllItems()
                self.cameraPopup.addItems(withTitles: cameras.map { $0.displayName })
                self.useButton.isEnabled = true

                // Preselect persisted camera if available.
                if let desiredSerial = capture.selectedCameraSerial,
                   let index = cameras.firstIndex(where: { $0.serialNumber == desiredSerial }) {
                    self.cameraPopup.selectItem(at: index)
                } else if let desiredModel = capture.selectedCameraModel,
                          let index = cameras.firstIndex(where: { $0.model == desiredModel }) {
                    self.cameraPopup.selectItem(at: index)
                } else {
                    self.cameraPopup.selectItem(at: 0)
                }

                self.statusLabel.stringValue = "Select a camera and click ‘Use Selection’."
            }
        }
    }

    @objc private func loadSettingsPressed() {
        loadSettings()
    }

    private func loadSettings() {
        guard let capture = cameraCapture else { return }

        settingsStatusLabel.stringValue = "Loading…"
        loadSettingsButton.isEnabled = false
        applySettingsButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = capture.readRadioSettings(paths: [["main", "imgsettings"], ["main", "capturesettings"]])

            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.settings = []
                    self.rebuildSettingsUI(settings: [])
                    self.settingsStatusLabel.stringValue = error.localizedDescription
                    self.loadSettingsButton.isEnabled = true
                    self.applySettingsButton.isEnabled = false

                case .success(let settings):
                    self.settings = settings
                    self.rebuildSettingsUI(settings: settings)
                    self.loadSettingsButton.isEnabled = true

                    if settings.isEmpty {
                        self.settingsStatusLabel.stringValue = "No RADIO settings found."
                        self.applySettingsButton.isEnabled = false
                    } else {
                        let writableCount = settings.filter { !$0.readOnly }.count
                        self.settingsStatusLabel.stringValue = "Loaded \(settings.count) settings (\(writableCount) writable)."
                        self.applySettingsButton.isEnabled = writableCount > 0
                    }
                }
            }
        }
    }

    private func rebuildSettingsUI(settings: [CameraCapture.RadioSetting]) {
        popupBySettingFullPath.removeAll()
        settingsStack.arrangedSubviews.forEach { v in
            settingsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        for setting in settings {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = 12

            let label = NSTextField(labelWithString: setting.label)
            label.lineBreakMode = .byTruncatingTail
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: 240).isActive = true
            label.toolTip = setting.fullPath

            let scope = NSTextField(labelWithString: setting.scopeHint ?? "")
            scope.textColor = .secondaryLabelColor
            scope.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            scope.setContentHuggingPriority(.required, for: .horizontal)
            scope.isHidden = (setting.scopeHint?.isEmpty ?? true)

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.addItems(withTitles: setting.choices)

            if !setting.currentValue.isEmpty, popup.itemTitles.contains(setting.currentValue) {
                popup.selectItem(withTitle: setting.currentValue)
            } else {
                popup.selectItem(at: 0)
            }

            popup.isEnabled = !setting.readOnly && !setting.choices.isEmpty
            popup.toolTip = setting.fullPath
            popupBySettingFullPath[setting.fullPath] = popup

            row.addArrangedSubview(label)
            row.addArrangedSubview(scope)
            row.addArrangedSubview(popup)

            settingsStack.addArrangedSubview(row)
        }
    }

    @objc private func applySettingsPressed() {
        guard let capture = cameraCapture else { return }
        guard !settings.isEmpty else { return }

        var updates: [String: String] = [:]
        for setting in settings {
            if setting.readOnly { continue }
            guard let popup = popupBySettingFullPath[setting.fullPath] else { continue }
            guard let value = popup.titleOfSelectedItem else { continue }
            updates[setting.fullPath] = value
        }

        settingsStatusLabel.stringValue = "Applying…"
        applySettingsButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = capture.applyRadioSettings(valuesByFullPath: updates)

            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.settingsStatusLabel.stringValue = error.localizedDescription
                    self.applySettingsButton.isEnabled = true
                case .success:
                    self.settingsStatusLabel.stringValue = "Applied. (Some cameras may require mode changes for settings to take effect.)"
                    self.applySettingsButton.isEnabled = true
                }
            }
        }
    }

    @objc private func usePressed() {
        guard let capture = cameraCapture else { return }
        let index = cameraPopup.indexOfSelectedItem
        guard index >= 0, index < cameras.count else { return }

        let selected = cameras[index]

        // Persist in a port-independent way.
        if let serial = selected.serialNumber, !serial.isEmpty {
            capture.selectedCameraSerial = serial
            capture.selectedCameraModel = selected.model
            statusLabel.stringValue = "Saved: \(selected.model) — \(serial)"
        } else {
            // Fallback: model only (port can change). This is best-effort.
            capture.selectedCameraSerial = nil
            capture.selectedCameraModel = selected.model
            statusLabel.stringValue = "Saved model (serial unavailable): \(selected.model)"
        }
    }
}
