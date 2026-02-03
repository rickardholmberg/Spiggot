//
//  CameraCapture.swift
//  Spiggot
//
//  Captures frames from a gphoto2-compatible camera and publishes to Syphon
//

import Foundation
import CoreImage
import Metal
import AppKit
import Syphon

class CameraCapture {

    // Flip to `true` when diagnosing camera/USB issues.
    private static let verboseLoggingEnabled = false

    private func log(_ message: String) {
        NSLog("[CameraCapture] %@", message)
    }

    private func logVerbose(_ message: String) {
        guard Self.verboseLoggingEnabled else { return }
        NSLog("[CameraCapture] %@", message)
    }

    // libgphoto2 returns -110 with message "I/O in progress" when the camera is busy (eg. during AF/preview).
    // Retrying briefly avoids hard-failing config updates that race camera-side operations.
    private static let gpErrorIOInProgress: Int32 = -110

    private enum GPhotoRetry {
        static let maxAttempts = 10
        static func delaySeconds(forAttempt attempt: Int) -> TimeInterval {
            min(0.35, 0.03 * pow(1.45, Double(attempt)))
        }
    }

    private func cameraGetConfigWithRetry(
        camera: UnsafeMutablePointer<Camera>,
        root: inout OpaquePointer?,
        gpContext: OpaquePointer,
        maxAttempts: Int = GPhotoRetry.maxAttempts
    ) -> Int32 {
        var attempt = 0
        var ret: Int32 = Self.gpErrorIOInProgress

        while attempt < maxAttempts {
            // Defensive: ensure we don't leak a partially-returned widget tree.
            if let existing = root {
                gp_widget_free(existing)
                root = nil
            }

            ret = gp_camera_get_config(camera, &root, gpContext)
            if ret >= GP_OK {
                return ret
            }

            let message = String(cString: gp_result_as_string(ret))
            if ret != Self.gpErrorIOInProgress {
                log("gp_camera_get_config failed: \(ret) (\(message))")
                return ret
            }

            let delay = GPhotoRetry.delaySeconds(forAttempt: attempt)
            logVerbose("gp_camera_get_config busy (attempt \(attempt + 1)/\(maxAttempts)); sleeping \(String(format: "%.3f", delay))s")
            Thread.sleep(forTimeInterval: delay)
            attempt += 1
        }

        let message = String(cString: gp_result_as_string(ret))
        log("gp_camera_get_config exhausted retries: \(ret) (\(message))")
        return ret
    }

    private func cameraSetConfigWithRetry(
        camera: UnsafeMutablePointer<Camera>,
        root: OpaquePointer,
        gpContext: OpaquePointer,
        maxAttempts: Int = GPhotoRetry.maxAttempts
    ) -> Int32 {
        var attempt = 0
        var ret: Int32 = Self.gpErrorIOInProgress

        while attempt < maxAttempts {
            ret = gp_camera_set_config(camera, root, gpContext)
            if ret >= GP_OK {
                return ret
            }

            let message = String(cString: gp_result_as_string(ret))
            if ret != Self.gpErrorIOInProgress {
                log("gp_camera_set_config failed: \(ret) (\(message))")
                return ret
            }

            let delay = GPhotoRetry.delaySeconds(forAttempt: attempt)
            logVerbose("gp_camera_set_config busy (attempt \(attempt + 1)/\(maxAttempts)); sleeping \(String(format: "%.3f", delay))s")
            Thread.sleep(forTimeInterval: delay)
            attempt += 1
        }

        let message = String(cString: gp_result_as_string(ret))
        log("gp_camera_set_config exhausted retries: \(ret) (\(message))")
        return ret
    }

    private static func configureGPhoto2EnvironmentForBundledCamlibs() {
        // If we distribute as a self-contained .app, libgphoto2's camera drivers (camlibs)
        // live inside the app bundle and must be discoverable via env vars.
        guard let resourcesURL = Bundle.main.resourceURL else { return }

        let camlibsURL = resourcesURL.appendingPathComponent("libgphoto2/camlibs", isDirectory: true)
        if FileManager.default.fileExists(atPath: camlibsURL.path) {
            setenv("CAMLIBS", camlibsURL.path, 1)
        }
    }
    enum CameraCaptureError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            }
        }
    }

    struct RadioSetting: Hashable {
        let path: [String]
        let name: String
        let label: String
        let readOnly: Bool
        let currentValue: String
        let choices: [String]

        var fullPath: String {
            "/" + (path + [name]).joined(separator: "/")
        }

        var scopeHint: String? {
            path.last
        }
    }

    struct DetectedCamera: Hashable {
        let model: String
        let port: String
        let serialNumber: String?

        var displayName: String {
            if let serialNumber, !serialNumber.isEmpty {
                return "\(model) — \(serialNumber)"
            }
            return "\(model) — \(port)"
        }
    }

    private enum DefaultsKeys {
        static let selectedCameraSerial = "SelectedCameraSerial"
        static let selectedCameraModel = "SelectedCameraModel"
        static let autofocusHoldSeconds = "AutofocusHoldSeconds"
    }

    private enum AutofocusTiming {
        static let edgeGapSeconds: TimeInterval = 0.06
        static let remoteReleaseHoldSeconds: TimeInterval = 0.25
        static let latchResetDelaySeconds: TimeInterval = 2.5
    }

    private enum AutofocusHoldPreference {
        static let defaultSeconds: TimeInterval = 10.0
        static let minSeconds: TimeInterval = 0.2
        static let maxSeconds: TimeInterval = 60.0

        static func clamp(_ seconds: TimeInterval) -> TimeInterval {
            guard seconds.isFinite else { return defaultSeconds }
            return max(minSeconds, min(maxSeconds, seconds))
        }
    }

    private var camera: UnsafeMutablePointer<Camera>?
    private var gpContext: OpaquePointer?
    private var syphonServer: SyphonMetalServer?
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private var running = false
    private var captureThread: Thread?

    // Syphon client monitoring (used to auto-start capture when a sink connects).
    var onSyphonHasClientsChanged: ((Bool) -> Void)?
    private var syphonHasClientsLast: Bool = false
    private var syphonClientMonitorTimer: DispatchSourceTimer?

    private let gphotoLock = NSLock()

    private let autofocusResetLock = NSLock()
    private var pendingAutofocusReset: DispatchWorkItem?

    var selectedCameraSerial: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.selectedCameraSerial) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: DefaultsKeys.selectedCameraSerial)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.selectedCameraSerial)
            }
        }
    }

    var selectedCameraModel: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.selectedCameraModel) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: DefaultsKeys.selectedCameraModel)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.selectedCameraModel)
            }
        }
    }

    /// How long to keep Canon AF "pressed" before releasing it again.
    /// Stored in `UserDefaults` so it can be changed at runtime.
    var autofocusHoldSeconds: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: DefaultsKeys.autofocusHoldSeconds)
            if stored <= 0 {
                return AutofocusHoldPreference.defaultSeconds
            }
            return AutofocusHoldPreference.clamp(stored)
        }
        set {
            let clamped = AutofocusHoldPreference.clamp(newValue)
            UserDefaults.standard.set(clamped, forKey: DefaultsKeys.autofocusHoldSeconds)
        }
    }

    private func forceStopPTPCameraDaemons() {
        logVerbose("Killing PTPCamera daemons (best-effort)")
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["-9", "PTPCamera", "ptpcamerad", "mscamerad-xpc"]
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                logVerbose("killall exited with status \(task.terminationStatus)")
            }
        } catch {
            log("killall failed to run: \(error)")
        }
    }

    private func initCameraWithRetries(camera: UnsafeMutablePointer<Camera>, gpContext: OpaquePointer) -> Bool {
        let maxAttempts = 8
        let baseDelay: TimeInterval = 0.12

        for attempt in 1...maxAttempts {
            logVerbose("gp_camera_init attempt \(attempt)/\(maxAttempts) (withCameraSession)")
            forceStopPTPCameraDaemons()

            let ret = gp_camera_init(camera, gpContext)
            if ret >= GP_OK {
                logVerbose("gp_camera_init succeeded")
                return true
            }

            let message = String(cString: gp_result_as_string(ret))
            logVerbose("gp_camera_init failed: ret=\(ret) (\(message))")

            if ret != GP_ERROR_IO_USB_CLAIM {
                log("gp_camera_init failed: \(ret) (\(message))")
                return false
            }

            let delay = min(0.6, baseDelay * pow(1.25, Double(attempt - 1)))
            logVerbose("USB claimed; sleeping \(String(format: "%.3f", delay))s")
            Thread.sleep(forTimeInterval: delay)
        }

        log("gp_camera_init exhausted retries")
        return false
    }

    private func withCameraSession<T>(_ body: (_ camera: UnsafeMutablePointer<Camera>, _ gpContext: OpaquePointer) -> T) -> Result<T, CameraCaptureError> {
        if let camera = camera, let gpContext = gpContext {
            gphotoLock.lock()
            defer { gphotoLock.unlock() }
            return .success(body(camera, gpContext))
        }

        forceStopPTPCameraDaemons()
        Thread.sleep(forTimeInterval: 0.1)

        let context = gp_context_new()
        guard let context else {
            return .failure(.message("Failed to create gphoto2 context"))
        }
        defer { gp_context_unref(context) }

        let candidates = autodetectCameras(gpContext: context)
        guard !candidates.isEmpty else {
            return .failure(.message("No cameras detected"))
        }

        // Resolve which camera to open (prefer selected serial, else selected model, else single camera).
        var chosen: (model: String, port: String)?
        if let desiredSerial = selectedCameraSerial, !desiredSerial.isEmpty {
            for candidate in candidates {
                var tmpCamera: UnsafeMutablePointer<Camera>?
                if gp_camera_new(&tmpCamera) < GP_OK || tmpCamera == nil { continue }
                guard let tmpCamera else { continue }
                defer { gp_camera_free(tmpCamera) }

                if !configure(camera: tmpCamera, model: candidate.model, port: candidate.port, gpContext: context) {
                    continue
                }
                if !initCameraWithRetries(camera: tmpCamera, gpContext: context) {
                    continue
                }
                defer { gp_camera_exit(tmpCamera, context) }

                if let summary = cameraSummaryString(camera: tmpCamera, gpContext: context),
                   let serial = parseSerialNumber(fromSummary: summary),
                   serial == desiredSerial {
                    chosen = (candidate.model, candidate.port)
                    break
                }
            }
        } else if let desiredModel = selectedCameraModel {
            let matches = candidates.filter { $0.model == desiredModel }
            if matches.count == 1 {
                chosen = (matches[0].model, matches[0].port)
            }
        } else if candidates.count == 1 {
            chosen = (candidates[0].model, candidates[0].port)
        }

        guard let chosen else {
            return .failure(.message("Unable to resolve selected camera. Open Settings and choose a camera."))
        }

        var tmpCamera: UnsafeMutablePointer<Camera>?
        let newRet = gp_camera_new(&tmpCamera)
        guard newRet >= GP_OK, let tmpCamera else {
            let message = String(cString: gp_result_as_string(newRet))
            return .failure(.message("Failed to create camera: \(newRet) (\(message))"))
        }
        defer { gp_camera_free(tmpCamera) }

        guard configure(camera: tmpCamera, model: chosen.model, port: chosen.port, gpContext: context) else {
            return .failure(.message("Failed to configure camera (model/port)"))
        }

        guard initCameraWithRetries(camera: tmpCamera, gpContext: context) else {
            return .failure(.message("Failed to initialize camera (device busy?)"))
        }
        defer { gp_camera_exit(tmpCamera, context) }

        return .success(body(tmpCamera, context))
    }

    private func widgetChild(parent: OpaquePointer?, name: String) -> OpaquePointer? {
        guard let parent else { return nil }
        var child: OpaquePointer?

        if gp_widget_get_child_by_name(parent, name, &child) >= GP_OK, let child {
            return child
        }

        // Some cameras expose slightly different naming; try label lookup as a fallback.
        if gp_widget_get_child_by_label(parent, name, &child) >= GP_OK, let child {
            return child
        }

        return nil
    }

    private func readRadioSettings(camera: UnsafeMutablePointer<Camera>, gpContext: OpaquePointer, path: [String]) -> Result<[RadioSetting], CameraCaptureError> {
        var root: OpaquePointer?
        let ret = cameraGetConfigWithRetry(camera: camera, root: &root, gpContext: gpContext)
        guard ret >= GP_OK, let root else {
            let message = String(cString: gp_result_as_string(ret))
            return .failure(.message("Failed to read camera config: \(ret) (\(message))"))
        }
        defer { gp_widget_free(root) }

        var node: OpaquePointer? = root
        var canonicalPath = ""
        for component in path {
            canonicalPath += "/\(component)"
            node = widgetChild(parent: node, name: component)
            if node == nil {
                return .failure(.message("Camera config missing \(canonicalPath)"))
            }
        }

        guard let container = node else {
            return .success([])
        }

        let count = gp_widget_count_children(container)
        guard count >= 0 else {
            return .failure(.message("Failed to enumerate \(canonicalPath)"))
        }
        if count == 0 { return .success([]) }

        var settings: [RadioSetting] = []
        settings.reserveCapacity(Int(count))

        for i in 0..<count {
            var child: OpaquePointer?
            if gp_widget_get_child(container, i, &child) < GP_OK { continue }
            guard let child else { continue }

            var type = GP_WIDGET_WINDOW
            if gp_widget_get_type(child, &type) < GP_OK { continue }
            if type != GP_WIDGET_RADIO { continue }

            var namePtr: UnsafePointer<CChar>?
            _ = gp_widget_get_name(child, &namePtr)
            let name = namePtr.map { String(cString: $0) } ?? ""
            if name.isEmpty { continue }

            var labelPtr: UnsafePointer<CChar>?
            _ = gp_widget_get_label(child, &labelPtr)
            let label = labelPtr.map { String(cString: $0) } ?? name

            var readOnlyInt: Int32 = 0
            _ = gp_widget_get_readonly(child, &readOnlyInt)

            var valuePtr: UnsafeMutablePointer<CChar>?
            _ = gp_widget_get_value(child, &valuePtr)
            let currentValue = valuePtr.map { String(cString: $0) } ?? ""

            let choiceCount = gp_widget_count_choices(child)
            var choices: [String] = []
            if choiceCount > 0 {
                choices.reserveCapacity(Int(choiceCount))
                for ci in 0..<choiceCount {
                    var choicePtr: UnsafePointer<CChar>?
                    if gp_widget_get_choice(child, ci, &choicePtr) >= GP_OK, let choicePtr {
                        choices.append(String(cString: choicePtr))
                    }
                }
            }

            settings.append(
                RadioSetting(
                    path: path,
                    name: name,
                    label: label,
                    readOnly: readOnlyInt != 0,
                    currentValue: currentValue,
                    choices: choices
                )
            )
        }

        return .success(
            settings.sorted {
                let cmp = $0.label.localizedCaseInsensitiveCompare($1.label)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.fullPath.localizedCaseInsensitiveCompare($1.fullPath) == .orderedAscending
            }
        )
    }

    private func applyRadioSettings(camera: UnsafeMutablePointer<Camera>, gpContext: OpaquePointer, path: [String], valuesByName: [String: String]) -> Result<Void, CameraCaptureError> {
        var root: OpaquePointer?
        let ret = cameraGetConfigWithRetry(camera: camera, root: &root, gpContext: gpContext)
        guard ret >= GP_OK, let root else {
            let message = String(cString: gp_result_as_string(ret))
            return .failure(.message("Failed to read camera config: \(ret) (\(message))"))
        }
        defer { gp_widget_free(root) }

        var node: OpaquePointer? = root
        var canonicalPath = ""
        for component in path {
            canonicalPath += "/\(component)"
            node = widgetChild(parent: node, name: component)
            if node == nil {
                return .failure(.message("Camera config missing \(canonicalPath)"))
            }
        }

        guard let container = node else {
            return .success(())
        }

        for (name, value) in valuesByName {
            guard let widget = widgetChild(parent: container, name: name) else { continue }

            var type = GP_WIDGET_WINDOW
            if gp_widget_get_type(widget, &type) < GP_OK { continue }
            if type != GP_WIDGET_RADIO { continue }

            var readOnlyInt: Int32 = 0
            _ = gp_widget_get_readonly(widget, &readOnlyInt)
            if readOnlyInt != 0 { continue }

            let setRet: Int32 = value.withCString { cstr in
                gp_widget_set_value(widget, UnsafeMutableRawPointer(mutating: cstr))
            }
            if setRet < GP_OK {
                let message = String(cString: gp_result_as_string(setRet))
                return .failure(.message("Failed to set \(name)=\(value): \(setRet) (\(message))"))
            }
        }

        let commitRet = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
        if commitRet < GP_OK {
            let message = String(cString: gp_result_as_string(commitRet))
            return .failure(.message("Failed to apply camera config: \(commitRet) (\(message))"))
        }

        return .success(())
    }

    private func findWidget(in root: OpaquePointer, path: [String], name: String) -> OpaquePointer? {
        var node: OpaquePointer? = root
        for component in path {
            node = widgetChild(parent: node, name: component)
            if node == nil { return nil }
        }
        guard let node else { return nil }
        return widgetChild(parent: node, name: name)
    }

    private func widgetName(_ widget: OpaquePointer) -> String? {
        var namePtr: UnsafePointer<CChar>?
        let ret = gp_widget_get_name(widget, &namePtr)
        guard ret >= GP_OK, let namePtr else { return nil }
        return String(cString: namePtr)
    }

    private func widgetLabel(_ widget: OpaquePointer) -> String? {
        var labelPtr: UnsafePointer<CChar>?
        let ret = gp_widget_get_label(widget, &labelPtr)
        guard ret >= GP_OK, let labelPtr else { return nil }
        return String(cString: labelPtr)
    }

    private func describeWidget(_ widget: OpaquePointer) -> String {
        let name = widgetName(widget) ?? "(unknown)"
        let label = widgetLabel(widget) ?? ""
        let type = widgetType(for: widget)
        if label.isEmpty {
            return "name=\(name) type=\(type)"
        }
        return "name=\(name) label=\(label) type=\(type)"
    }

    private func findWidgetRecursive(in parent: OpaquePointer, matchingName wantedName: String) -> OpaquePointer? {
        let count = gp_widget_count_children(parent)
        guard count > 0 else { return nil }

        for i in 0..<count {
            var child: OpaquePointer?
            if gp_widget_get_child(parent, i, &child) < GP_OK { continue }
            guard let child else { continue }

            if widgetName(child) == wantedName {
                return child
            }

            if let found = findWidgetRecursive(in: child, matchingName: wantedName) {
                return found
            }
        }

        return nil
    }

    private struct AutofocusTriggerOutcome {
        let widgetType: CameraWidgetType
        let resetWidgetName: String?
    }

    private enum CameraWidgetType {
        case toggle
        case button
        case radio
        case text
        case range
        case other
    }

    private func widgetType(for widget: OpaquePointer) -> CameraWidgetType {
        var type = GP_WIDGET_WINDOW
        if gp_widget_get_type(widget, &type) < GP_OK { return .other }

        switch type {
        case GP_WIDGET_TOGGLE: return .toggle
        case GP_WIDGET_BUTTON: return .button
        case GP_WIDGET_RADIO: return .radio
        case GP_WIDGET_TEXT: return .text
        case GP_WIDGET_RANGE: return .range
        default: return .other
        }
    }

    private func readRadioChoices(widget: OpaquePointer) -> [String] {
        let count = gp_widget_count_choices(widget)
        guard count > 0 else { return [] }

        var choices: [String] = []
        choices.reserveCapacity(Int(count))

        for i in 0..<count {
            var ptr: UnsafePointer<CChar>?
            if gp_widget_get_choice(widget, i, &ptr) < GP_OK { continue }
            guard let ptr else { continue }
            choices.append(String(cString: ptr))
        }

        return choices
    }

    private enum CanonRemoteReleaseChoiceKind {
        case none
        case pressHalf
        case releaseHalf
    }

    private func bestCanonRemoteReleaseChoice(choices: [String], kind: CanonRemoteReleaseChoiceKind) -> String? {
        // Canon EOS bodies typically expose eosremoterelease choices like:
        // "None", "Press Half", "Press Full", "Release Half", "Release Full".
        // Be conservative: avoid "Full" so we don't accidentally fire the shutter.
        let lowered = choices.map { $0.lowercased() }

        func pick(_ predicate: (String) -> Bool) -> String? {
            for (idx, value) in lowered.enumerated() {
                if predicate(value) { return choices[idx] }
            }
            return nil
        }

        switch kind {
        case .none:
            return pick { $0 == "none" || $0.contains("none") }
        case .pressHalf:
            return pick { $0.contains("press") && $0.contains("half") }
        case .releaseHalf:
            return pick { $0.contains("release") && $0.contains("half") }
        }
    }

    private func triggerCanonEosRemoteRelease(camera: UnsafeMutablePointer<Camera>, gpContext: OpaquePointer, root: OpaquePointer, widget: OpaquePointer) -> Result<Void, CameraCaptureError> {
        // Best-effort: return to None (if supported), half-press to start AF, then release half,
        // then return to None again. Some bodies seem to require this to retrigger reliably.
        let choices = readRadioChoices(widget: widget)
        guard !choices.isEmpty else {
            return .failure(.message("eosremoterelease has no choices"))
        }

        let noneChoice = bestCanonRemoteReleaseChoice(choices: choices, kind: .none)
        guard let pressHalf = bestCanonRemoteReleaseChoice(choices: choices, kind: .pressHalf),
              let releaseHalf = bestCanonRemoteReleaseChoice(choices: choices, kind: .releaseHalf) else {
            return .failure(.message("eosremoterelease missing Press Half / Release Half choices. Available: \(choices.joined(separator: ", "))"))
        }

        func setRadio(_ value: String) -> Result<Void, CameraCaptureError> {
            let setRet: Int32 = value.withCString { cstr in
                gp_widget_set_value(widget, UnsafeMutableRawPointer(mutating: cstr))
            }
            if setRet < GP_OK {
                let message = String(cString: gp_result_as_string(setRet))
                return .failure(.message("Failed to set eosremoterelease=\(value): \(setRet) (\(message))"))
            }

            let commitRet = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
            if commitRet < GP_OK {
                let message = String(cString: gp_result_as_string(commitRet))
                return .failure(.message("Failed to apply eosremoterelease=\(value): \(commitRet) (\(message))"))
            }

            return .success(())
        }

        if let noneChoice {
            _ = setRadio(noneChoice)
            Thread.sleep(forTimeInterval: AutofocusTiming.edgeGapSeconds)
        }

        switch setRadio(pressHalf) {
        case .failure(let error):
            return .failure(error)
        case .success:
            break
        }

        // Give the AF system a moment to move.
        Thread.sleep(forTimeInterval: AutofocusTiming.remoteReleaseHoldSeconds)

        switch setRadio(releaseHalf) {
        case .failure(let error):
            return .failure(error)
        case .success:
            break
        }

        if let noneChoice {
            Thread.sleep(forTimeInterval: AutofocusTiming.edgeGapSeconds)
            return setRadio(noneChoice)
        }

        return .success(())
    }

    private func applyWidgetValueAndCommit(camera: UnsafeMutablePointer<Camera>, gpContext: OpaquePointer, root: OpaquePointer, widget: OpaquePointer, widgetName: String) -> Result<AutofocusTriggerOutcome, CameraCaptureError> {
        let type = widgetType(for: widget)
        if type == .other {
            return .failure(.message("Autofocus widget has unsupported type"))
        }

        logVerbose("AF using \(describeWidget(widget))")

        // Many cameras implement AF as a momentary "drive" action which expects an edge.
        // Doing a 0(commit) → 1(commit) pulse retriggers reliably without aborting focus.
        func commitOrError(_ ret: Int32, action: String) -> Result<Void, CameraCaptureError> {
            if ret < GP_OK {
                let message = String(cString: gp_result_as_string(ret))
                return .failure(.message("\(action) failed: \(ret) (\(message))"))
            }
            return .success(())
        }

        func logSetValueResult(_ ret: Int32, valueDescription: String) {
            let message = String(cString: gp_result_as_string(ret))
            logVerbose("AF gp_widget_set_value(\(valueDescription)) ret=\(ret) (\(message))")
        }

        // Many cameras expose AF as a latch-like control: once it is at 1, setting 1 again is a no-op.
        // For these controls, schedule a delayed reset to 0 (after AF has had time to complete), and
        // if we detect it's already at 1, generate a 0→1 edge immediately.
        let shouldResetToZeroLater = (type != .button)
        let resetWidgetName: String? = shouldResetToZeroLater ? widgetName : nil

        func toggleCurrentValue() -> Int32? {
            var current: Int32 = 0
            let ret = gp_widget_get_value(widget, &current)
            return ret >= GP_OK ? current : nil
        }

        func textCurrentValue() -> String? {
            var valuePtr: UnsafeMutablePointer<CChar>?
            let ret = gp_widget_get_value(widget, &valuePtr)
            guard ret >= GP_OK else { return nil }
            return valuePtr.map { String(cString: $0) }
        }

        func rangeCurrentValue() -> Float? {
            var current: Float = 0
            let ret = gp_widget_get_value(widget, &current)
            return ret >= GP_OK ? current : nil
        }

        switch type {
        case .button:
            let setRet = gp_widget_set_value(widget, nil)
            if case .failure(let err) = commitOrError(setRet, action: "Trigger autofocus") { return .failure(err) }

            let commitRet = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
            switch commitOrError(commitRet, action: "Apply autofocus") {
            case .failure(let error):
                return .failure(error)
            case .success:
                return .success(.init(widgetType: type, resetWidgetName: nil))
            }

        case .toggle:
            let current = toggleCurrentValue()
            if let current {
                logVerbose("AF toggle current=\(current)")
            } else {
                logVerbose("AF toggle current=(unreadable)")
            }

            if let current, current != 0 {
                logVerbose("AF forcing 0→1 edge")
                var zero: Int32 = 0
                let set0 = gp_widget_set_value(widget, &zero)
                logSetValueResult(set0, valueDescription: "toggle=0")
                if case .failure(let err) = commitOrError(set0, action: "Reset autofocus") { return .failure(err) }
                let commit0 = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
                if case .failure(let err) = commitOrError(commit0, action: "Apply autofocus reset") { return .failure(err) }
                Thread.sleep(forTimeInterval: AutofocusTiming.edgeGapSeconds)
            }

            var one: Int32 = 1
            let set1 = gp_widget_set_value(widget, &one)
            logSetValueResult(set1, valueDescription: "toggle=1")
            if case .failure(let err) = commitOrError(set1, action: "Trigger autofocus") { return .failure(err) }

            let commit1 = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
            switch commitOrError(commit1, action: "Apply autofocus") {
            case .failure(let error):
                return .failure(error)
            case .success:
                return .success(.init(widgetType: type, resetWidgetName: resetWidgetName))
            }

        case .radio:
            // Not used for Canon EOS AF; handled by eosremoterelease.
            return .failure(.message("Unsupported autofocus widget type: radio"))

        case .text:
            if let current = textCurrentValue(), current != "0" {
                logVerbose("AF forcing 0→1 edge")
                let set0: Int32 = "0".withCString { cstr in
                    gp_widget_set_value(widget, UnsafeMutableRawPointer(mutating: cstr))
                }
                if case .failure(let err) = commitOrError(set0, action: "Reset autofocus") { return .failure(err) }
                let commit0 = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
                if case .failure(let err) = commitOrError(commit0, action: "Apply autofocus reset") { return .failure(err) }
                Thread.sleep(forTimeInterval: AutofocusTiming.edgeGapSeconds)
            }

            let set1: Int32 = "1".withCString { cstr in
                gp_widget_set_value(widget, UnsafeMutableRawPointer(mutating: cstr))
            }
            if case .failure(let err) = commitOrError(set1, action: "Trigger autofocus") { return .failure(err) }

            let commit1 = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
            switch commitOrError(commit1, action: "Apply autofocus") {
            case .failure(let error):
                return .failure(error)
            case .success:
                return .success(.init(widgetType: type, resetWidgetName: resetWidgetName))
            }

        case .range:
            if let current = rangeCurrentValue(), current != 0 {
                logVerbose("AF forcing 0→1 edge")
                var zero: Float = 0
                let set0 = gp_widget_set_value(widget, &zero)
                if case .failure(let err) = commitOrError(set0, action: "Reset autofocus") { return .failure(err) }
                let commit0 = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
                if case .failure(let err) = commitOrError(commit0, action: "Apply autofocus reset") { return .failure(err) }
                Thread.sleep(forTimeInterval: AutofocusTiming.edgeGapSeconds)
            }

            var one: Float = 1
            let set1 = gp_widget_set_value(widget, &one)
            if case .failure(let err) = commitOrError(set1, action: "Trigger autofocus") { return .failure(err) }

            let commit1 = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
            switch commitOrError(commit1, action: "Apply autofocus") {
            case .failure(let error):
                return .failure(error)
            case .success:
                return .success(.init(widgetType: type, resetWidgetName: resetWidgetName))
            }

        case .other:
            return .failure(.message("Autofocus widget has unsupported type"))
        }
    }

    private func scheduleAutofocusReset(widgetName: String, delaySeconds: TimeInterval) {
        logVerbose("Scheduling AF reset for widget=\(widgetName) in \(String(format: "%.2f", delaySeconds))s")
        autofocusResetLock.lock()
        pendingAutofocusReset?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            _ = self.withCameraSession { camera, gpContext in
                self.logVerbose("AF reset executing for widget=\(widgetName)")
                var root: OpaquePointer?
                let ret = self.cameraGetConfigWithRetry(camera: camera, root: &root, gpContext: gpContext)
                guard ret >= GP_OK, let root else {
                    self.log("AF reset failed: could not read config")
                    return Result<Void, CameraCaptureError>.failure(.message("Failed to read camera config for autofocus reset"))
                }
                defer { gp_widget_free(root) }

                guard let widget = self.findWidget(in: root, path: ["main", "actions"], name: widgetName) ??
                    self.findWidget(in: root, path: ["main"], name: widgetName) ??
                    self.findWidgetRecursive(in: root, matchingName: widgetName) else {
                    self.logVerbose("AF reset: widget not found: \(widgetName)")
                    return .success(())
                }

                switch self.widgetType(for: widget) {
                case .toggle:
                    var zero: Int32 = 0
                    let setRet = gp_widget_set_value(widget, &zero)
                    if setRet >= GP_OK {
                        _ = self.cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
                    } else {
                        self.logVerbose("AF reset failed to set toggle=0: \(setRet) (\(String(cString: gp_result_as_string(setRet))))")
                    }
                case .text:
                    let setRet: Int32 = "0".withCString { cstr in
                        gp_widget_set_value(widget, UnsafeMutableRawPointer(mutating: cstr))
                    }
                    if setRet >= GP_OK {
                        _ = self.cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
                    } else {
                        self.logVerbose("AF reset failed to set text=0: \(setRet) (\(String(cString: gp_result_as_string(setRet))))")
                    }
                case .range:
                    var zero: Float = 0
                    let setRet = gp_widget_set_value(widget, &zero)
                    if setRet >= GP_OK {
                        _ = self.cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
                    } else {
                        self.logVerbose("AF reset failed to set range=0: \(setRet) (\(String(cString: gp_result_as_string(setRet))))")
                    }
                case .radio, .button, .other:
                    break
                }

                return .success(())
            }
        }

        pendingAutofocusReset = workItem
        autofocusResetLock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delaySeconds, execute: workItem)
    }

    private func pulseCancelAutofocusIfAvailable(camera: UnsafeMutablePointer<Camera>, gpContext: OpaquePointer, root: OpaquePointer, context: String) {
        guard let cancelWidget = findWidget(in: root, path: ["main", "actions"], name: "cancelautofocus") ??
            findWidget(in: root, path: ["main"], name: "cancelautofocus") ??
            findWidgetRecursive(in: root, matchingName: "cancelautofocus") else {
            logVerbose("AF cancelautofocus not found (\(context))")
            return
        }

        guard widgetType(for: cancelWidget) == .toggle else {
            logVerbose("AF cancelautofocus found but not toggle (\(context)): \(describeWidget(cancelWidget))")
            return
        }

        logVerbose("AF pulsing cancelautofocus (\(context))")

        var one: Int32 = 1
        let set1 = gp_widget_set_value(cancelWidget, &one)
        if set1 >= GP_OK {
            let commit1 = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
            if commit1 < GP_OK {
                logVerbose("AF cancelautofocus=1 commit failed: \(commit1) (\(String(cString: gp_result_as_string(commit1))))")
            }
        }

        Thread.sleep(forTimeInterval: AutofocusTiming.edgeGapSeconds)

        var zero: Int32 = 0
        let set0 = gp_widget_set_value(cancelWidget, &zero)
        if set0 >= GP_OK {
            let commit0 = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
            if commit0 < GP_OK {
                logVerbose("AF cancelautofocus=0 commit failed: \(commit0) (\(String(cString: gp_result_as_string(commit0))))")
            }
        }
    }

    private func tryCanonAutofocusdriveWithCancelPulse(holdSeconds: TimeInterval) -> Result<Bool, CameraCaptureError> {
        // For Canon EOS bodies, autofocusdrive=1 can leave the camera in an AF state.
        // Per gphoto2 ticket #116, cancelautofocus=1 (or autofocusdrive=0) exits that state.
        // Important: do NOT hold the gphoto lock for the full AF duration; keep preview running.

        let started: Result<Bool, CameraCaptureError> = withCameraSession { camera, gpContext in
            var root: OpaquePointer?
            let ret = cameraGetConfigWithRetry(camera: camera, root: &root, gpContext: gpContext)
            guard ret >= GP_OK, let root else {
                let message = String(cString: gp_result_as_string(ret))
                return .failure(.message("Failed to read camera config: \(ret) (\(message))"))
            }
            defer { gp_widget_free(root) }

            guard let driveWidget = findWidget(in: root, path: ["main", "actions"], name: "autofocusdrive") ??
                findWidgetRecursive(in: root, matchingName: "autofocusdrive") else {
                return .success(false)
            }

            guard widgetType(for: driveWidget) == .toggle else {
                return .success(false)
            }

            logVerbose("AF (Canon) autofocusdrive holdSeconds=\(String(format: "%.1f", holdSeconds))")
            pulseCancelAutofocusIfAvailable(camera: camera, gpContext: gpContext, root: root, context: "pre")

            var one: Int32 = 1
            let set1 = gp_widget_set_value(driveWidget, &one)
            if set1 < GP_OK {
                let message = String(cString: gp_result_as_string(set1))
                return .failure(.message("Failed to set autofocusdrive=1: \(set1) (\(message))"))
            }

            let commit1 = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
            if commit1 < GP_OK {
                let message = String(cString: gp_result_as_string(commit1))
                return .failure(.message("Failed to apply autofocusdrive=1: \(commit1) (\(message))"))
            }

            return .success(true)
        }.flatMap { $0 }

        switch started {
        case .failure(let error):
            return .failure(error)
        case .success(false):
            return .success(false)
        case .success(true):
            break
        }

        // Let AF run while preview continues.
        Thread.sleep(forTimeInterval: holdSeconds)

        let finished: Result<Void, CameraCaptureError> = withCameraSession { camera, gpContext in
            var root: OpaquePointer?
            let ret = cameraGetConfigWithRetry(camera: camera, root: &root, gpContext: gpContext)
            guard ret >= GP_OK, let root else {
                let message = String(cString: gp_result_as_string(ret))
                return .failure(.message("Failed to read camera config: \(ret) (\(message))"))
            }
            defer { gp_widget_free(root) }

            pulseCancelAutofocusIfAvailable(camera: camera, gpContext: gpContext, root: root, context: "post")

            guard let driveWidget = findWidget(in: root, path: ["main", "actions"], name: "autofocusdrive") ??
                findWidgetRecursive(in: root, matchingName: "autofocusdrive") else {
                return .success(())
            }

            var zero: Int32 = 0
            let set0 = gp_widget_set_value(driveWidget, &zero)
            if set0 >= GP_OK {
                let commit0 = cameraSetConfigWithRetry(camera: camera, root: root, gpContext: gpContext)
                if commit0 < GP_OK {
                    logVerbose("AF autofocusdrive=0 commit failed: \(commit0) (\(String(cString: gp_result_as_string(commit0))))")
                }
            }

            return .success(())
        }.flatMap { $0 }

        switch finished {
        case .failure(let error):
            return .failure(error)
        case .success:
            return .success(true)
        }
    }

    func triggerAutofocus() -> Result<Void, CameraCaptureError> {
        logVerbose("triggerAutofocus()")

        // Canon EOS autofocusdrive: use cancelautofocus pulse and hold AF for a while without blocking preview.
        switch tryCanonAutofocusdriveWithCancelPulse(holdSeconds: autofocusHoldSeconds) {
        case .failure(let error):
            return .failure(error)
        case .success(true):
            return .success(())
        case .success(false):
            break
        }

        let result: Result<AutofocusTriggerOutcome, CameraCaptureError> = withCameraSession { camera, gpContext in
            var root: OpaquePointer?
            let ret = cameraGetConfigWithRetry(camera: camera, root: &root, gpContext: gpContext)
            guard ret >= GP_OK, let root else {
                let message = String(cString: gp_result_as_string(ret))
                return .failure(.message("Failed to read camera config: \(ret) (\(message))"))
            }
            defer { gp_widget_free(root) }

            let wantedNames = ["autofocusdrive", "autofocus"]
            let candidatePaths: [[String]] = [
                ["main", "actions"],
                ["main"],
                []
            ]

            for wantedName in wantedNames {
                for path in candidatePaths {
                    if let widget = findWidget(in: root, path: path, name: wantedName) {
                        logVerbose("AF found widget /\(path.joined(separator: "/"))/\(wantedName)")
                        return applyWidgetValueAndCommit(camera: camera, gpContext: gpContext, root: root, widget: widget, widgetName: wantedName)
                    }
                }

                if let widget = findWidgetRecursive(in: root, matchingName: wantedName) {
                    logVerbose("AF found widget (recursive) \(wantedName)")
                    return applyWidgetValueAndCommit(camera: camera, gpContext: gpContext, root: root, widget: widget, widgetName: wantedName)
                }
            }

            // Fallback: Canon EOS bodies may expose AF via eosremoterelease (half-press / release).
            if let remoteRelease = findWidget(in: root, path: ["main", "actions"], name: "eosremoterelease") ??
                findWidgetRecursive(in: root, matchingName: "eosremoterelease") {
                if widgetType(for: remoteRelease) == .radio {
                    logVerbose("AF using eosremoterelease fallback")
                    switch triggerCanonEosRemoteRelease(camera: camera, gpContext: gpContext, root: root, widget: remoteRelease) {
                    case .failure(let error):
                        logVerbose("AF eosremoterelease failed: \(error.localizedDescription)")
                        return .failure(error)
                    case .success:
                        logVerbose("AF eosremoterelease succeeded")
                        return .success(.init(widgetType: .radio, resetWidgetName: nil))
                    }
                }
            }

            logVerbose("AF failed: no supported autofocus widget found")
            return .failure(.message("Camera does not expose autofocus control (tried 'autofocusdrive')."))
        }.flatMap { $0 }

        switch result {
        case .failure:
            return result.map { _ in () }
        case .success(let outcome):
            // Reset latch-style AF controls back to 0 after AF has had time to finish.
            // A longer delay avoids aborting focus on bodies which treat 0 as "stop".
            if let resetWidgetName = outcome.resetWidgetName {
                scheduleAutofocusReset(widgetName: resetWidgetName, delaySeconds: AutofocusTiming.latchResetDelaySeconds)
            }
            return .success(())
        }
    }

    private func readImgSettingsRadio(camera: UnsafeMutablePointer<Camera>, gpContext: OpaquePointer) -> Result<[RadioSetting], CameraCaptureError> {
        readRadioSettings(camera: camera, gpContext: gpContext, path: ["main", "imgsettings"])
    }

    private func applyImgSettingsRadio(camera: UnsafeMutablePointer<Camera>, gpContext: OpaquePointer, valuesByName: [String: String]) -> Result<Void, CameraCaptureError> {
        applyRadioSettings(camera: camera, gpContext: gpContext, path: ["main", "imgsettings"], valuesByName: valuesByName)
    }

    func readImgSettingsRadio() -> Result<[RadioSetting], CameraCaptureError> {
        return withCameraSession { camera, gpContext in
            readImgSettingsRadio(camera: camera, gpContext: gpContext)
        }.flatMap { $0 }
    }

    func applyImgSettingsRadio(_ valuesByName: [String: String]) -> Result<Void, CameraCaptureError> {
        guard !valuesByName.isEmpty else { return .success(()) }

        return withCameraSession { camera, gpContext in
            applyImgSettingsRadio(camera: camera, gpContext: gpContext, valuesByName: valuesByName)
        }.flatMap { $0 }
    }

    func readCaptureSettingsRadio() -> Result<[RadioSetting], CameraCaptureError> {
        return withCameraSession { camera, gpContext in
            readRadioSettings(camera: camera, gpContext: gpContext, path: ["main", "capturesettings"])
        }.flatMap { $0 }
    }

    func applyCaptureSettingsRadio(_ valuesByName: [String: String]) -> Result<Void, CameraCaptureError> {
        guard !valuesByName.isEmpty else { return .success(()) }

        return withCameraSession { camera, gpContext in
            applyRadioSettings(camera: camera, gpContext: gpContext, path: ["main", "capturesettings"], valuesByName: valuesByName)
        }.flatMap { $0 }
    }

    /// Reads RADIO settings for multiple config subtrees and returns a single merged list.
    /// Keep `paths` expandable to later support scanning broader areas of the config tree.
    func readRadioSettings(paths: [[String]]) -> Result<[RadioSetting], CameraCaptureError> {
        return withCameraSession { camera, gpContext in
            var merged: [RadioSetting] = []
            for path in paths {
                switch readRadioSettings(camera: camera, gpContext: gpContext, path: path) {
                case .failure(let error):
                    return .failure(error)
                case .success(let settings):
                    merged.append(contentsOf: settings)
                }
            }

            let sorted = merged.sorted {
                let cmp = $0.label.localizedCaseInsensitiveCompare($1.label)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.fullPath.localizedCaseInsensitiveCompare($1.fullPath) == .orderedAscending
            }
            return .success(sorted)
        }.flatMap { $0 }
    }

    /// Applies RADIO settings across (potentially) multiple config subtrees.
    /// Keys are full widget paths like `/main/imgsettings/iso`.
    func applyRadioSettings(valuesByFullPath: [String: String]) -> Result<Void, CameraCaptureError> {
        guard !valuesByFullPath.isEmpty else { return .success(()) }

        var grouped: [[String]: [String: String]] = [:]
        grouped.reserveCapacity(4)

        for (fullPath, value) in valuesByFullPath {
            let parts = fullPath.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts.last!
            let containerPath = Array(parts.dropLast())
            grouped[containerPath, default: [:]][name] = value
        }

        return withCameraSession { camera, gpContext in
            for (path, valuesByName) in grouped {
                let result = applyRadioSettings(camera: camera, gpContext: gpContext, path: path, valuesByName: valuesByName)
                if case .failure(let error) = result {
                    return .failure(error)
                }
            }
            return .success(())
        }.flatMap { $0 }
    }

    private func parseSerialNumber(fromSummary summary: String) -> String? {
        // Example line from Canon: "Serial Number: 5ecc..."
        for line in summary.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("serial number:") {
                let value = trimmed.dropFirst("Serial Number:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func cameraSummaryString(camera: UnsafeMutablePointer<Camera>, gpContext: OpaquePointer) -> String? {
        var text = CameraText()
        let ret = gp_camera_get_summary(camera, &text, gpContext)
        guard ret >= GP_OK else { return nil }

        // `CameraText` contains a large fixed-size `char[]` which Swift doesn't import as a named field.
        // Interpret the struct bytes as a C string.
        return withUnsafeBytes(of: &text) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let cStringPtr = baseAddress.assumingMemoryBound(to: CChar.self)
            return String(cString: cStringPtr)
        }
    }

    private func configure(camera: UnsafeMutablePointer<Camera>, model: String, port: String, gpContext: OpaquePointer) -> Bool {
        // Camera abilities (by model)
        var abilitiesList: OpaquePointer?
        var ret = gp_abilities_list_new(&abilitiesList)
        guard ret >= GP_OK, let abilitiesList else { return false }
        defer { gp_abilities_list_free(abilitiesList) }

        ret = gp_abilities_list_load(abilitiesList, gpContext)
        guard ret >= GP_OK else { return false }

        let modelIndex = gp_abilities_list_lookup_model(abilitiesList, model)
        guard modelIndex >= 0 else { return false }

        var abilities = CameraAbilities()
        ret = gp_abilities_list_get_abilities(abilitiesList, modelIndex, &abilities)
        guard ret >= GP_OK else { return false }

        ret = gp_camera_set_abilities(camera, abilities)
        guard ret >= GP_OK else { return false }

        // Port info (by port path)
        var portInfoList: OpaquePointer?
        ret = gp_port_info_list_new(&portInfoList)
        guard ret >= GP_OK, let portInfoList else { return false }
        defer { gp_port_info_list_free(portInfoList) }

        ret = gp_port_info_list_load(portInfoList)
        guard ret >= GP_OK else { return false }

        let portIndex = gp_port_info_list_lookup_path(portInfoList, port)
        guard portIndex >= 0 else { return false }

        var portInfo: GPPortInfo?
        ret = gp_port_info_list_get_info(portInfoList, portIndex, &portInfo)
        guard ret >= GP_OK, let portInfo else { return false }

        ret = gp_camera_set_port_info(camera, portInfo)
        return ret >= GP_OK
    }

    private func autodetectCameras(gpContext: OpaquePointer) -> [(model: String, port: String)] {
        var list: OpaquePointer?
        var ret = gp_list_new(&list)
        guard ret >= GP_OK, let list else { return [] }
        defer { gp_list_free(list) }

        ret = gp_camera_autodetect(list, gpContext)
        guard ret >= GP_OK else { return [] }

        let count = gp_list_count(list)
        guard count > 0 else { return [] }

        var result: [(String, String)] = []
        result.reserveCapacity(Int(count))

        for i in 0..<count {
            var namePtr: UnsafePointer<CChar>?
            var valuePtr: UnsafePointer<CChar>?

            if gp_list_get_name(list, i, &namePtr) < GP_OK { continue }
            if gp_list_get_value(list, i, &valuePtr) < GP_OK { continue }
            guard let namePtr, let valuePtr else { continue }

            let model = String(cString: namePtr)
            let port = String(cString: valuePtr)
            result.append((model, port))
        }

        return result
    }

    func listAvailableCameras(includeSerialNumbers: Bool) -> [DetectedCamera] {
        forceStopPTPCameraDaemons()
        Thread.sleep(forTimeInterval: 0.1)

        let context = gp_context_new()
        guard let context else { return [] }
        defer { gp_context_unref(context) }

        let candidates = autodetectCameras(gpContext: context)
        guard !candidates.isEmpty else { return [] }

        if !includeSerialNumbers {
            return candidates.map { DetectedCamera(model: $0.model, port: $0.port, serialNumber: nil) }
        }

        // Best-effort: open each camera briefly to read summary + serial.
        var detected: [DetectedCamera] = []
        detected.reserveCapacity(candidates.count)

        for candidate in candidates {
            var serial: String?

            // Create camera
            var tmpCamera: UnsafeMutablePointer<Camera>?
            if gp_camera_new(&tmpCamera) >= GP_OK, let tmpCamera {
                if configure(camera: tmpCamera, model: candidate.model, port: candidate.port, gpContext: context) {
                    if gp_camera_init(tmpCamera, context) >= GP_OK {
                        if let summary = cameraSummaryString(camera: tmpCamera, gpContext: context) {
                            serial = parseSerialNumber(fromSummary: summary)
                        }
                        gp_camera_exit(tmpCamera, context)
                    }
                }
                gp_camera_free(tmpCamera)
            }

            detected.append(DetectedCamera(model: candidate.model, port: candidate.port, serialNumber: serial))
        }

        return detected
    }

    private func initializeCameraWithRetries(gpContext: OpaquePointer, model: String?, port: String?) -> Bool {
        // On modern macOS, `ptpcamerad` may re-spawn and re-claim the interface.
        // A short burst of retries tends to succeed once the device settles.
        let maxAttempts = 12
        let baseDelay: TimeInterval = 0.12

        for attempt in 1...maxAttempts {
            if Thread.current.isCancelled { return false }

            logVerbose("initializeCameraWithRetries attempt \(attempt)/\(maxAttempts) model=\(model ?? "(nil)") port=\(port ?? "(nil)")")
            forceStopPTPCameraDaemons()

            // Create a fresh camera per attempt.
            var ret = gp_camera_new(&camera)
            if ret < GP_OK || camera == nil {
                let message = String(cString: gp_result_as_string(ret))
                log("gp_camera_new failed: \(ret) (\(message))")
                onStatusUpdate?("Failed to create camera: \(ret) (\(message))")
                self.camera = nil
                return false
            }

            if let camera, let model, let port {
                if !configure(camera: camera, model: model, port: port, gpContext: gpContext) {
                    gp_camera_free(camera)
                    self.camera = nil
                    onStatusUpdate?("Failed to configure camera (model/port)")
                    return false
                }
            }

            ret = gp_camera_init(camera, gpContext)
            logVerbose("gp_camera_init (start) ret=\(ret) (\(String(cString: gp_result_as_string(ret))))")
            if ret >= GP_OK {
                return true
            }

            let message = String(cString: gp_result_as_string(ret))
            gp_camera_free(camera)
            self.camera = nil

            if ret == GP_ERROR_IO_USB_CLAIM {
                onStatusUpdate?("Camera busy (USB claimed). Retrying… (\(attempt)/\(maxAttempts))")
            } else {
                onStatusUpdate?("Failed to initialize camera: \(ret) (\(message))")
                return false
            }

            // Tiny backoff; keep total time short (~< 2s).
            let delay = min(0.6, baseDelay * pow(1.25, Double(attempt - 1)))
            logVerbose("initializeCameraWithRetries sleeping \(String(format: "%.3f", delay))s")
            Thread.sleep(forTimeInterval: delay)
        }

        onStatusUpdate?("Failed to initialize camera: USB device stays claimed. Try again or enable sudo/privileged helper.")
        return false
    }
    
    // Status callback
    var onStatusUpdate: ((String) -> Void)?
    var onFrameCount: ((Int) -> Void)?
    
    init?() {
        Self.configureGPhoto2EnvironmentForBundledCamlibs()

        // Initialize Metal
        guard let device = MTLCreateSystemDefaultDevice() else {
            log("Failed to create Metal device")
            return nil
        }
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            log("Failed to create command queue")
            return nil
        }
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device)

        logVerbose("Metal initialized")

        // Create Syphon server immediately so clients can discover/connect even
        // when capture is not running.
        self.syphonServer = SyphonMetalServer(name: "GPhoto2 Camera", device: device)
        self.syphonHasClientsLast = self.syphonServer?.hasClients ?? false
        startSyphonClientMonitoring()
    }

    deinit {
        syphonClientMonitorTimer?.setEventHandler {}
        syphonClientMonitorTimer?.cancel()
        syphonClientMonitorTimer = nil
    }

    private func startSyphonClientMonitoring() {
        // Polling is intentionally simple and robust; Syphon's hasClients is
        // cheap to query and avoids relying on KVO behavior.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let hasClients = self.syphonServer?.hasClients ?? false
            if hasClients != self.syphonHasClientsLast {
                self.syphonHasClientsLast = hasClients
                DispatchQueue.main.async { [weak self] in
                    self?.onSyphonHasClientsChanged?(hasClients)
                }
            }
        }
        timer.resume()
        syphonClientMonitorTimer = timer
    }
    
    func start() -> Bool {
        logVerbose("start()")

        if running {
            return true
        }

        // Ensure Syphon server exists (it should be created in init, but be defensive).
        if syphonServer == nil, let device = self.device {
            syphonServer = SyphonMetalServer(name: "GPhoto2 Camera", device: device)
            syphonHasClientsLast = syphonServer?.hasClients ?? false
        }

        if syphonServer == nil {
            onStatusUpdate?("Syphon server could not be created")
            return false
        }

        // Best-effort stop; on modern macOS these daemons tend to respawn quickly,
        // so actual init uses a small retry loop.
        forceStopPTPCameraDaemons()
        Thread.sleep(forTimeInterval: 0.2)
        
        // Initialize gphoto2 context
        gpContext = gp_context_new()
        guard let gpContext else {
            onStatusUpdate?("Failed to create gphoto2 context")
            return false
        }

        // Decide which camera to open.
        let candidates = autodetectCameras(gpContext: gpContext)
        logVerbose("autodetectCameras found \(candidates.count) candidates")
        if candidates.isEmpty {
            onStatusUpdate?("No cameras detected")
            gp_context_unref(gpContext)
            self.gpContext = nil
            return false
        }

        // If a serial is selected, try to find that camera regardless of port.
        if let desiredSerial = selectedCameraSerial, !desiredSerial.isEmpty {
            for candidate in candidates {
                // Attempt to init candidate
                guard initializeCameraWithRetries(gpContext: gpContext, model: candidate.model, port: candidate.port) else {
                    continue
                }

                if let camera = camera, let summary = cameraSummaryString(camera: camera, gpContext: gpContext) {
                    let serial = parseSerialNumber(fromSummary: summary)
                    if serial == desiredSerial {
                        selectedCameraModel = candidate.model
                        onStatusUpdate?("Camera initialized")
                        break
                    }
                }

                // Not the one: close and try next.
                if let camera = camera {
                    gp_camera_exit(camera, gpContext)
                    gp_camera_free(camera)
                    self.camera = nil
                }
            }

            if camera == nil {
                onStatusUpdate?("Selected camera not found; open Settings to choose")
                gp_context_unref(gpContext)
                self.gpContext = nil
                return false
            }
        } else {
            // If there’s exactly one camera, just open it.
            if candidates.count == 1 {
                let c = candidates[0]
                guard initializeCameraWithRetries(gpContext: gpContext, model: c.model, port: c.port) else {
                    gp_context_unref(gpContext)
                    self.gpContext = nil
                    return false
                }
                selectedCameraModel = c.model
            } else if let model = selectedCameraModel {
                // If a model is stored and uniquely matches, use it.
                let matches = candidates.filter { $0.model == model }
                if matches.count == 1 {
                    let c = matches[0]
                    guard initializeCameraWithRetries(gpContext: gpContext, model: c.model, port: c.port) else {
                        gp_context_unref(gpContext)
                        self.gpContext = nil
                        return false
                    }
                } else {
                    onStatusUpdate?("Multiple cameras detected; open Settings to choose")
                    gp_context_unref(gpContext)
                    self.gpContext = nil
                    return false
                }
            } else {
                onStatusUpdate?("Multiple cameras detected; open Settings to choose")
                gp_context_unref(gpContext)
                self.gpContext = nil
                return false
            }
        }
        
        onStatusUpdate?("Camera initialized")
        
        // Start capture thread
        logVerbose("Starting capture thread")
        running = true
        captureThread = Thread { [weak self] in
            self?.captureLoop()
        }
        captureThread?.name = "CameraCapture"
        captureThread?.start()
        
        return true
    }
    
    func stop() {
        running = false
        captureThread?.cancel()

        gphotoLock.lock()
        defer { gphotoLock.unlock() }

        if let camera = camera, let gpContext = gpContext {
            gp_camera_exit(camera, gpContext)
            gp_camera_free(camera)
            self.camera = nil
        }

        if let gpContext {
            gp_context_unref(gpContext)
            self.gpContext = nil
        }
        
        onStatusUpdate?("Stopped")
    }
    
    private func captureLoop() {
        logVerbose("captureLoop starting")
        var texture: MTLTexture?
        var frameCount = 0

        var lastPreviewErrorLog: Date = .distantPast
        var consecutivePreviewErrors = 0
        
        while running && !Thread.current.isCancelled {
            autoreleasepool {
                // Keep gphoto2 lock scope as small as possible so UI-triggered camera commands
                // (like autofocus) can execute reliably while capture is running.
                let jpegData: Data?
                gphotoLock.lock()
                do {
                    defer { gphotoLock.unlock() }
                    guard let camera = camera, let gpContext = gpContext else {
                        jpegData = nil
                        return
                    }

                    // Create file to hold preview data
                    var file: OpaquePointer?
                    var ret = gp_file_new(&file)
                    guard ret >= GP_OK, let cameraFile = file else {
                        jpegData = nil
                        return
                    }
                    defer { gp_file_free(cameraFile) }

                    // Capture preview frame
                    ret = gp_camera_capture_preview(camera, cameraFile, gpContext)
                    guard ret >= GP_OK else {
                        consecutivePreviewErrors += 1
                        let now = Date()
                        if now.timeIntervalSince(lastPreviewErrorLog) > 1.0 {
                            lastPreviewErrorLog = now
                            let msg = String(cString: gp_result_as_string(ret))
                            log("gp_camera_capture_preview failed ret=\(ret) (\(msg)) consecutiveErrors=\(consecutivePreviewErrors)")
                        }
                        jpegData = nil
                        Thread.sleep(forTimeInterval: 0.01)
                        return
                    }

                    if consecutivePreviewErrors > 0 {
                        logVerbose("gp_camera_capture_preview recovered after \(consecutivePreviewErrors) errors")
                        consecutivePreviewErrors = 0
                    }

                    // Get data from file
                    var dataPtr: UnsafePointer<CChar>?
                    var dataSize: UInt = 0
                    ret = gp_file_get_data_and_size(cameraFile, &dataPtr, &dataSize)
                    guard ret >= GP_OK, let data = dataPtr, dataSize > 0 else {
                        jpegData = nil
                        return
                    }

                    // Copy bytes out while the gp_file is alive.
                    jpegData = Data(bytes: data, count: Int(dataSize))
                }

                guard let jpegData else { return }

                // Decode JPEG to CIImage
                guard let ciImage = CIImage(data: jpegData) else { return }
                
                let width = Int(ciImage.extent.width)
                let height = Int(ciImage.extent.height)
                
                // Create or recreate texture if needed
                if texture == nil || texture!.width != width || texture!.height != height {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .rgba8Unorm,
                        width: width,
                        height: height,
                        mipmapped: false
                    )
                    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                    texture = device?.makeTexture(descriptor: descriptor)
                }
                
                guard let tex = texture else { return }

                guard let commandQueue = commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else {
                    return
                }
                
                // Render to texture
                ciContext?.render(
                    ciImage,
                    to: tex,
                    commandBuffer: commandBuffer,
                    bounds: ciImage.extent,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                
                // Publish to Syphon
                syphonServer?.publishFrameTexture(
                    tex,
                    on: commandBuffer,
                    imageRegion: NSRect(x: 0, y: 0, width: width, height: height),
                    flipped: false
                )

                commandBuffer.commit()
                
                frameCount += 1
                if frameCount % 30 == 0 {
                    DispatchQueue.main.async { [weak self] in
                        self?.onFrameCount?(frameCount)
                    }
                }
            }
        }
    }
    
    var isRunning: Bool {
        return running
    }

    /// Best-effort current Syphon client state for UI/automation decisions.
    /// Safe to call from the main thread.
    func syphonHasClientsForUI() -> Bool {
        return syphonServer?.hasClients ?? false
    }
}
