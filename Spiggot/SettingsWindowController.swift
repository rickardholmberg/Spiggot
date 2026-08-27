import Cocoa

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var cameraCapture: CameraCapture?

    private let cropHeaderLabel = NSTextField(labelWithString: "Crop")
    private let cropImageView = NSImageView(frame: .zero)
    private let cropOverlayView = CropOverlayView(frame: .zero)
    private let resetCropButton = NSButton(title: "Reset Crop", target: nil, action: nil)
    private let resetColorButton = NSButton(title: "Reset Color", target: nil, action: nil)

    private let hueLabel = NSTextField(labelWithString: "Hue:")
    private let hueSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let hueValueLabel = NSTextField(labelWithString: "0°")

    private let saturationLabel = NSTextField(labelWithString: "Saturation:")
    private let saturationSlider = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let saturationValueLabel = NSTextField(labelWithString: "100%")

    private let lightnessLabel = NSTextField(labelWithString: "Lightness:")
    private let lightnessSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let lightnessValueLabel = NSTextField(labelWithString: "0%")

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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 980),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        buildUI()
        refreshCameras()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)

        // Refresh from whatever's actually persisted (CameraCapture's own
        // applyCrop(_:) self-corrects independently while Settings is
        // closed, so this may have changed since the window was built).
        cropOverlayView.normalizedRect = cameraCapture?.cropRect ?? CameraCapture.fullFrameCropRect

        // Update the aspect lock for future drags *without* immediately
        // re-snapping/persisting: sourceAspectRatio is still just a 1:1
        // guess until a real preview frame arrives (setSourceAspectRatio
        // will re-snap correctly once one does), and snapping against a
        // wrong guess right now would silently corrupt a perfectly good
        // persisted crop if the camera isn't actively streaming yet.
        cropOverlayView.setAspectRatioWithoutSnapping(cameraCapture?.requiredCropAspectRatio)

        cameraCapture?.onPreviewFrame = { [weak self] cgImage in
            guard let self else { return }
            self.cropImageView.image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            if cgImage.height > 0 {
                self.cropOverlayView.setSourceAspectRatio(CGFloat(cgImage.width) / CGFloat(cgImage.height))
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        cameraCapture?.onPreviewFrame = nil
    }

    @objc private func resetCropPressed() {
        cameraCapture?.cropRect = CameraCapture.fullFrameCropRect
        cropOverlayView.normalizedRect = CameraCapture.fullFrameCropRect
        // If OBS output needs a fixed aspect, snap straight to the centered
        // box that exactly fills it (matches what applyCrop(_:) will also
        // self-correct to on the next frame) rather than leaving the
        // letterboxed full-frame default visible even momentarily.
        cropOverlayView.setDesiredPixelAspectRatio(cameraCapture?.requiredCropAspectRatio)
    }

    @objc private func resetColorPressed() {
        cameraCapture?.hueAdjustDegrees = 0
        cameraCapture?.saturationAdjust = 1.0
        cameraCapture?.lightnessAdjust = 0
        hueSlider.doubleValue = 0
        saturationSlider.doubleValue = 1.0
        lightnessSlider.doubleValue = 0
        hueValueLabel.stringValue = "0°"
        saturationValueLabel.stringValue = "100%"
        lightnessValueLabel.stringValue = "0%"
    }

    @objc private func colorSliderChanged(_ sender: NSSlider) {
        switch sender {
        case hueSlider:
            cameraCapture?.hueAdjustDegrees = hueSlider.doubleValue
            hueValueLabel.stringValue = "\(Int(hueSlider.doubleValue))°"
        case saturationSlider:
            cameraCapture?.saturationAdjust = saturationSlider.doubleValue
            saturationValueLabel.stringValue = "\(Int(saturationSlider.doubleValue * 100))%"
        case lightnessSlider:
            cameraCapture?.lightnessAdjust = lightnessSlider.doubleValue
            lightnessValueLabel.stringValue = "\(Int(lightnessSlider.doubleValue * 100))%"
        default:
            break
        }
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let cameraLabel = NSTextField(labelWithString: "Camera:")
        cameraLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let separator = NSBox()
        separator.boxType = .separator

        let cropSeparator = NSBox()
        cropSeparator.boxType = .separator

        cropHeaderLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        cropHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        cropImageView.translatesAutoresizingMaskIntoConstraints = false
        cropImageView.imageScaling = .scaleProportionallyUpOrDown
        cropImageView.wantsLayer = true
        cropImageView.layer?.backgroundColor = NSColor.black.cgColor

        cropOverlayView.translatesAutoresizingMaskIntoConstraints = false
        cropOverlayView.wantsLayer = true
        cropOverlayView.normalizedRect = cameraCapture?.cropRect ?? CameraCapture.fullFrameCropRect
        cropOverlayView.onRectChanged = { [weak self] rect in
            self?.cameraCapture?.cropRect = rect
        }

        resetCropButton.translatesAutoresizingMaskIntoConstraints = false
        resetCropButton.target = self
        resetCropButton.action = #selector(resetCropPressed)
        resetCropButton.bezelStyle = .rounded

        resetColorButton.translatesAutoresizingMaskIntoConstraints = false
        resetColorButton.target = self
        resetColorButton.action = #selector(resetColorPressed)
        resetColorButton.bezelStyle = .rounded

        for label in [hueLabel, saturationLabel, lightnessLabel, hueValueLabel, saturationValueLabel, lightnessValueLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        hueValueLabel.alignment = .right
        saturationValueLabel.alignment = .right
        lightnessValueLabel.alignment = .right
        hueValueLabel.textColor = .secondaryLabelColor
        saturationValueLabel.textColor = .secondaryLabelColor
        lightnessValueLabel.textColor = .secondaryLabelColor

        hueSlider.translatesAutoresizingMaskIntoConstraints = false
        hueSlider.target = self
        hueSlider.action = #selector(colorSliderChanged)
        hueSlider.doubleValue = cameraCapture?.hueAdjustDegrees ?? 0
        hueValueLabel.stringValue = "\(Int(hueSlider.doubleValue))°"

        saturationSlider.translatesAutoresizingMaskIntoConstraints = false
        saturationSlider.target = self
        saturationSlider.action = #selector(colorSliderChanged)
        saturationSlider.doubleValue = cameraCapture?.saturationAdjust ?? 1.0
        saturationValueLabel.stringValue = "\(Int(saturationSlider.doubleValue * 100))%"

        lightnessSlider.translatesAutoresizingMaskIntoConstraints = false
        lightnessSlider.target = self
        lightnessSlider.action = #selector(colorSliderChanged)
        lightnessSlider.doubleValue = cameraCapture?.lightnessAdjust ?? 0
        lightnessValueLabel.stringValue = "\(Int(lightnessSlider.doubleValue * 100))%"

        cropSeparator.translatesAutoresizingMaskIntoConstraints = false

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

        contentView.addSubview(cropHeaderLabel)
        contentView.addSubview(cropImageView)
        cropImageView.addSubview(cropOverlayView)
        contentView.addSubview(resetCropButton)
        contentView.addSubview(resetColorButton)
        contentView.addSubview(hueLabel)
        contentView.addSubview(hueSlider)
        contentView.addSubview(hueValueLabel)
        contentView.addSubview(saturationLabel)
        contentView.addSubview(saturationSlider)
        contentView.addSubview(saturationValueLabel)
        contentView.addSubview(lightnessLabel)
        contentView.addSubview(lightnessSlider)
        contentView.addSubview(lightnessValueLabel)
        contentView.addSubview(cropSeparator)

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
            cropHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            cropHeaderLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            cropImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            cropImageView.topAnchor.constraint(equalTo: cropHeaderLabel.bottomAnchor, constant: 10),
            cropImageView.widthAnchor.constraint(equalToConstant: 480),
            cropImageView.heightAnchor.constraint(equalToConstant: 270),

            cropOverlayView.leadingAnchor.constraint(equalTo: cropImageView.leadingAnchor),
            cropOverlayView.trailingAnchor.constraint(equalTo: cropImageView.trailingAnchor),
            cropOverlayView.topAnchor.constraint(equalTo: cropImageView.topAnchor),
            cropOverlayView.bottomAnchor.constraint(equalTo: cropImageView.bottomAnchor),

            resetCropButton.leadingAnchor.constraint(equalTo: cropImageView.trailingAnchor, constant: 16),
            resetCropButton.topAnchor.constraint(equalTo: cropImageView.topAnchor),

            resetColorButton.leadingAnchor.constraint(equalTo: resetCropButton.leadingAnchor),
            resetColorButton.topAnchor.constraint(equalTo: resetCropButton.bottomAnchor, constant: 8),

            hueLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            hueLabel.widthAnchor.constraint(equalToConstant: 80),
            hueLabel.topAnchor.constraint(equalTo: cropImageView.bottomAnchor, constant: 16),
            hueSlider.leadingAnchor.constraint(equalTo: hueLabel.trailingAnchor, constant: 8),
            hueSlider.trailingAnchor.constraint(equalTo: hueValueLabel.leadingAnchor, constant: -8),
            hueSlider.centerYAnchor.constraint(equalTo: hueLabel.centerYAnchor),
            hueValueLabel.widthAnchor.constraint(equalToConstant: 50),
            hueValueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            hueValueLabel.centerYAnchor.constraint(equalTo: hueLabel.centerYAnchor),

            saturationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            saturationLabel.widthAnchor.constraint(equalToConstant: 80),
            saturationLabel.topAnchor.constraint(equalTo: hueLabel.bottomAnchor, constant: 12),
            saturationSlider.leadingAnchor.constraint(equalTo: saturationLabel.trailingAnchor, constant: 8),
            saturationSlider.trailingAnchor.constraint(equalTo: saturationValueLabel.leadingAnchor, constant: -8),
            saturationSlider.centerYAnchor.constraint(equalTo: saturationLabel.centerYAnchor),
            saturationValueLabel.widthAnchor.constraint(equalToConstant: 50),
            saturationValueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            saturationValueLabel.centerYAnchor.constraint(equalTo: saturationLabel.centerYAnchor),

            lightnessLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            lightnessLabel.widthAnchor.constraint(equalToConstant: 80),
            lightnessLabel.topAnchor.constraint(equalTo: saturationLabel.bottomAnchor, constant: 12),
            lightnessSlider.leadingAnchor.constraint(equalTo: lightnessLabel.trailingAnchor, constant: 8),
            lightnessSlider.trailingAnchor.constraint(equalTo: lightnessValueLabel.leadingAnchor, constant: -8),
            lightnessSlider.centerYAnchor.constraint(equalTo: lightnessLabel.centerYAnchor),
            lightnessValueLabel.widthAnchor.constraint(equalToConstant: 50),
            lightnessValueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            lightnessValueLabel.centerYAnchor.constraint(equalTo: lightnessLabel.centerYAnchor),

            cropSeparator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            cropSeparator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            cropSeparator.topAnchor.constraint(equalTo: lightnessLabel.bottomAnchor, constant: 16),

            cameraLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            cameraLabel.topAnchor.constraint(equalTo: cropSeparator.bottomAnchor, constant: 16),

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
