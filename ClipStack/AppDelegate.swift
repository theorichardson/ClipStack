import AppKit
import ScreenCaptureKit
import Sparkle
import SwiftData

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Sparkle updater. Starts checking for updates against `SUFeedURL`
    /// (set in Info.plist) on launch and on a recurring schedule. The
    /// `Check for Updates…` menu item forwards to this controller.
    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()

    private var statusItem: NSStatusItem?
    private var recordingStatusItem: NSStatusItem?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?
    private var manageWindowController: ManagePresetsWindowController?
    private var manageCaptureWindowController: ManageCapturePresetsWindowController?
    private var permissionsWindowController: PermissionsWindowController?
    private var popoverController: StatusBarPopoverController?

    /// PID of the app that was frontmost the moment the user opened the
    /// popover / status menu. We capture it before activating ClipStack
    /// because once we activate, `NSWorkspace.frontmostApplication` points
    /// at us, and any window-resize action would target a ClipStack window
    /// instead of the user's actual target (e.g. Chrome).
    private(set) var capturedTargetPID: pid_t?

    /// Capture the currently-frontmost non-ClipStack app as the target
    /// for upcoming window-resize actions. Safe to call multiple times;
    /// each call refreshes the captured pid.
    func captureTargetApplicationPID() {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ourPID {
            capturedTargetPID = front.processIdentifier
        }
    }

    func clearCapturedTargetApplicationPID() {
        capturedTargetPID = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrapClipboardStack()

        _ = updaterController

        // Mirrors WidthSync's launch flow: a single call to
        // requestAccessibilityAccess() when AXIsProcessTrusted() reports
        // false. This keeps the System Settings entry's designated
        // requirement fresh; combined with the pinned dev-cert signing in
        // project.yml, AXIsProcessTrusted() returns true on subsequent
        // launches and the system prompt does not appear.
        if !PermissionManager.hasAccessibilityAccess {
            PermissionManager.requestAccessibilityAccess()
        }

        installStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(presetsDidChange),
            name: .widthPresetsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(capturePresetsDidChange),
            name: .capturePresetsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        HotKeyManager.register(appDelegate: self)
        rebuildMenu()

        Task {
            await PermissionManager.refreshPermissionStatus()
            rebuildMenu()
            if !PermissionManager.hasAllPermissions {
                openPermissions(nil)
            }
        }
    }

    @objc private func applicationDidBecomeActive() {
        Task {
            await PermissionManager.refreshPermissionStatus()
            rebuildMenu()
            // Refresh, but do NOT auto-close the permissions window here.
            // Becoming active can flip AXIsProcessTrusted() from false to
            // true on the first query after launch (TCC lazy-registers the
            // app), and closing the window in that window of time looks
            // like "the permissions menu opens and closes" to the user.
            // The user (or an explicit Allow click) decides when to close.
            permissionsWindowController?.refreshStatus()
        }
    }

    @objc private func presetsDidChange() {
        rebuildMenu()
    }

    @objc private func capturePresetsDidChange() {
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {}

    /// Builds the SwiftData stack used for clipboard history, wires the
    /// pasteboard monitor and prepares the keyboard-picker panel that
    /// opens via ⌘⇧X.
    private func bootstrapClipboardStack() {
        let schema = Schema([ClipboardEntry.self])
        let configuration = ModelConfiguration(
            "ClipStack",
            schema: schema,
            url: AppStorage.appSupportDirectory.appendingPathComponent("history.store"),
            allowsSave: true
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            AppModelContainer.shared = container
            ClipboardStore.shared.configure(modelContext: container.mainContext)
        } catch {
            assertionFailure("Could not create ClipStack ModelContainer: \(error)")
            return
        }

        PasteboardMonitor.shared.onNewEntry = { item in
            ClipboardStore.shared.add(item)
        }
        PasteboardMonitor.shared.start()
        PanelController.shared.prepare()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let image = NSImage(systemSymbolName: "appwindow.swipe.rectangle", accessibilityDescription: "ClipStack")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.toolTip = "ClipStack"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        popoverController = StatusBarPopoverController(appDelegate: self)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isRightClick {
            showRightClickMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        guard let popoverController else { return }
        if popoverController.isShown {
            popoverController.close()
        } else {
            syncRecordingStatusItem()
            popoverController.show(from: button)
        }
    }

    private func showRightClickMenu(from button: NSStatusBarButton) {
        popoverController?.close()
        // Capture the target app *before* the menu opens. Status-bar menus
        // on an LSUIElement app usually don't activate us, but some user
        // actions in the menu (e.g. presenting an alert) will, and we want
        // resize actions to target the previously-frontmost app regardless.
        captureTargetApplicationPID()
        let menu = buildFullMenu()
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
        clearCapturedTargetApplicationPID()
    }

    private func syncRecordingStatusItem() {
        let recording = ScreenCaptureService.shared.isRecording
        if recording, recordingStatusItem == nil {
            installRecordingStatusItem()
        } else if !recording, recordingStatusItem != nil {
            removeRecordingStatusItem()
        }
    }

    private func installRecordingStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = .systemRed
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(stopRecording(_:))
            button.toolTip = "Stop ClipStack recording (⌘⇧.)"
        }
        recordingStatusItem = item
        recordingStartedAt = .now
        updateRecordingStatusTitle()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRecordingStatusTitle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func updateRecordingStatusTitle() {
        guard
            let started = recordingStartedAt,
            let button = recordingStatusItem?.button
        else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(started)))
        let mins = elapsed / 60
        let secs = elapsed % 60
        let text = String(format: " Stop %d:%02d", mins, secs)
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.menuBarFont(ofSize: 0),
        ]
        button.attributedTitle = NSAttributedString(string: text, attributes: attributes)
    }

    private func removeRecordingStatusItem() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
        if let item = recordingStatusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        recordingStatusItem = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        syncRecordingStatusItem()
    }

    func buildFullMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        if ScreenCaptureService.shared.isRecording {
            let stopItem = NSMenuItem(
                title: "Stop Recording",
                action: #selector(stopRecording(_:)),
                keyEquivalent: "."
            )
            stopItem.keyEquivalentModifierMask = [.command, .shift]
            stopItem.target = self
            menu.addItem(stopItem)
            menu.addItem(.separator())
        }

        menu.addItem(makeMenuSectionHeader("Screenshot"))

        menu.addItem(makeCaptureMenuItem(
            title: "Screenshot Region…",
            action: #selector(screenshotRegion(_:)),
            symbol: CaptureActionSymbol.screenshotRegion,
            keyEquivalent: "r",
            modifiers: [.command, .shift, .option]
        ))

        menu.addItem(makeCaptureMenuItem(
            title: "Screenshot Window…",
            action: #selector(captureWindow(_:)),
            symbol: CaptureActionSymbol.screenshotWindow,
            keyEquivalent: "c",
            modifiers: [.command, .shift, .option]
        ))

        menu.addItem(makeMenuSectionHeader("Recording"))

        menu.addItem(makeCaptureMenuItem(
            title: "Record Region…",
            action: #selector(recordRegion(_:)),
            symbol: CaptureActionSymbol.recordRegion,
            keyEquivalent: "t",
            modifiers: [.command, .shift, .option],
            enabled: !ScreenCaptureService.shared.isRecording
        ))

        menu.addItem(makeCaptureMenuItem(
            title: "Record Window…",
            action: #selector(recordWindow(_:)),
            symbol: CaptureActionSymbol.recordWindow,
            keyEquivalent: "w",
            modifiers: [.command, .shift, .option],
            enabled: !ScreenCaptureService.shared.isRecording
        ))

        menu.addItem(.separator())
        menu.addItem(capturePresetsSubmenu())
        menu.addItem(.separator())

        let saveItem = NSMenuItem(
            title: "Save Frontmost Window Width…",
            action: #selector(saveFrontmostWidth(_:)),
            keyEquivalent: "s"
        )
        saveItem.keyEquivalentModifierMask = [.command, .shift]
        saveItem.target = self
        menu.addItem(saveItem)

        menu.addItem(.separator())

        let presets = PresetStore.shared.presets
        if presets.isEmpty {
            let emptyItem = NSMenuItem(title: "No saved widths yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for (index, preset) in presets.enumerated() {
                let title = "\(preset.name) (\(Int(preset.width)) px)"
                let item = NSMenuItem(title: title, action: #selector(applyPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id

                if index < 9 {
                    item.keyEquivalent = String(index + 1)
                    item.keyEquivalentModifierMask = [.command, .shift]
                }

                let submenu = NSMenu()
                submenu.addItem(makeActionItem(
                    title: "Apply",
                    action: #selector(applyPreset(_:)),
                    representedObject: preset.id
                ))
                submenu.addItem(makeActionItem(
                    title: "Rename…",
                    action: #selector(renamePreset(_:)),
                    representedObject: preset.id
                ))
                submenu.addItem(.separator())
                submenu.addItem(makeActionItem(
                    title: "Delete",
                    action: #selector(deletePreset(_:)),
                    representedObject: preset.id
                ))
                item.submenu = submenu
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let manageItem = NSMenuItem(
            title: "Manage Width Presets…",
            action: #selector(openManagePresets(_:)),
            keyEquivalent: ""
        )
        manageItem.target = self
        menu.addItem(manageItem)

        let manageCaptureItem = NSMenuItem(
            title: "Manage Capture Presets…",
            action: #selector(openManageCapturePresets(_:)),
            keyEquivalent: ""
        )
        manageCaptureItem.target = self
        menu.addItem(manageCaptureItem)

        menu.addItem(.separator())

        menu.addItem(permissionsSubmenu())

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit ClipStack",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Popover menu builders

    /// Menu shown when the user clicks the "Width Presets" icon in the
    /// horizontal popover toolbar.
    func buildWidthPresetsMenu() -> NSMenu {
        let menu = NSMenu()

        let presets = PresetStore.shared.presets
        if presets.isEmpty {
            let empty = NSMenuItem(title: "No saved widths yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, preset) in presets.enumerated() {
                let title = "\(preset.name) (\(Int(preset.width)) px)"
                let item = NSMenuItem(title: title, action: #selector(applyPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id
                if index < 9 {
                    item.keyEquivalent = String(index + 1)
                    item.keyEquivalentModifierMask = [.command, .shift]
                }

                let submenu = NSMenu()
                submenu.addItem(makeActionItem(
                    title: "Apply",
                    action: #selector(applyPreset(_:)),
                    representedObject: preset.id
                ))
                submenu.addItem(makeActionItem(
                    title: "Rename…",
                    action: #selector(renamePreset(_:)),
                    representedObject: preset.id
                ))
                submenu.addItem(.separator())
                submenu.addItem(makeActionItem(
                    title: "Delete",
                    action: #selector(deletePreset(_:)),
                    representedObject: preset.id
                ))
                item.submenu = submenu
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let saveItem = NSMenuItem(
            title: "Save Frontmost Window Width…",
            action: #selector(saveFrontmostWidth(_:)),
            keyEquivalent: ""
        )
        saveItem.target = self
        menu.addItem(saveItem)

        let manageItem = NSMenuItem(
            title: "Manage Width Presets…",
            action: #selector(openManagePresets(_:)),
            keyEquivalent: ""
        )
        manageItem.target = self
        menu.addItem(manageItem)

        return menu
    }

    /// Menu shown when the user clicks the "Capture Presets" icon in the
    /// horizontal popover toolbar.
    func buildCapturePresetsMenu() -> NSMenu {
        let menu = NSMenu()

        let presets = CapturePresetStore.shared.presets
        if presets.isEmpty {
            let empty = NSMenuItem(title: "No saved regions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for preset in presets {
                let presetItem = NSMenuItem(
                    title: "\(preset.name) — \(preset.region.displayDescription)",
                    action: nil,
                    keyEquivalent: ""
                )
                let presetMenu = NSMenu()
                presetMenu.addItem(makeCaptureActionItem(
                    title: "Show Region",
                    action: #selector(showCaptureRegion(_:)),
                    representedObject: preset.id
                ))
                presetMenu.addItem(makeCaptureActionItem(
                    title: "Screenshot",
                    action: #selector(screenshotCapturePreset(_:)),
                    representedObject: preset.id
                ))
                presetMenu.addItem(makeCaptureActionItem(
                    title: "Record",
                    action: #selector(recordCapturePreset(_:)),
                    representedObject: preset.id
                ))
                presetMenu.addItem(.separator())
                presetMenu.addItem(makeCaptureActionItem(
                    title: "Rename…",
                    action: #selector(renameCapturePreset(_:)),
                    representedObject: preset.id
                ))
                presetMenu.addItem(makeCaptureActionItem(
                    title: "Delete",
                    action: #selector(deleteCapturePreset(_:)),
                    representedObject: preset.id
                ))
                presetItem.submenu = presetMenu
                menu.addItem(presetItem)
            }
        }

        menu.addItem(.separator())

        menu.addItem(makeMenuSectionHeader("Screenshot"))
        menu.addItem(makeCaptureMenuItem(
            title: "Screenshot Region…",
            action: #selector(screenshotRegion(_:)),
            symbol: CaptureActionSymbol.screenshotRegion
        ))
        menu.addItem(makeCaptureMenuItem(
            title: "Screenshot Window…",
            action: #selector(captureWindow(_:)),
            symbol: CaptureActionSymbol.screenshotWindow
        ))

        menu.addItem(makeMenuSectionHeader("Recording"))
        menu.addItem(makeCaptureMenuItem(
            title: "Record Region…",
            action: #selector(recordRegion(_:)),
            symbol: CaptureActionSymbol.recordRegion,
            enabled: !ScreenCaptureService.shared.isRecording
        ))
        menu.addItem(makeCaptureMenuItem(
            title: "Record Window…",
            action: #selector(recordWindow(_:)),
            symbol: CaptureActionSymbol.recordWindow,
            enabled: !ScreenCaptureService.shared.isRecording
        ))

        menu.addItem(.separator())

        let manageItem = NSMenuItem(
            title: "Manage Capture Presets…",
            action: #selector(openManageCapturePresets(_:)),
            keyEquivalent: ""
        )
        manageItem.target = self
        menu.addItem(manageItem)

        return menu
    }

    /// Overflow menu shown from the trailing "•••" icon in the popover.
    func buildMoreMenu() -> NSMenu {
        let menu = NSMenu()

        let manageWidth = NSMenuItem(
            title: "Manage Width Presets…",
            action: #selector(openManagePresets(_:)),
            keyEquivalent: ""
        )
        manageWidth.target = self
        menu.addItem(manageWidth)

        let manageCapture = NSMenuItem(
            title: "Manage Capture Presets…",
            action: #selector(openManageCapturePresets(_:)),
            keyEquivalent: ""
        )
        manageCapture.target = self
        menu.addItem(manageCapture)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let clearHistoryItem = NSMenuItem(
            title: "Clear Clipboard History",
            action: #selector(clearClipboardHistory(_:)),
            keyEquivalent: ""
        )
        clearHistoryItem.target = self
        menu.addItem(clearHistoryItem)

        menu.addItem(.separator())

        let summary: String
        if PermissionManager.hasAllPermissions {
            summary = "Permissions: Ready"
        } else if PermissionManager.screenCaptureNeedsRelaunch {
            summary = "Permissions: Relaunch Required"
        } else {
            summary = "Permissions: Setup Required"
        }
        let permissions = NSMenuItem(
            title: summary,
            action: #selector(openPermissions(_:)),
            keyEquivalent: ""
        )
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(
            title: "Quit ClipStack",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    /// Invoked by the popover's stop button.
    func stopActiveRecordingFromUI() {
        Task { await stopActiveRecording() }
    }

    private func capturePresetsSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Capture Presets", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let presets = CapturePresetStore.shared.presets
        if presets.isEmpty {
            let emptyItem = NSMenuItem(title: "No saved regions yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for preset in presets {
                let presetItem = NSMenuItem(
                    title: "\(preset.name) — \(preset.region.displayDescription)",
                    action: nil,
                    keyEquivalent: ""
                )
                let presetMenu = NSMenu()
                presetMenu.addItem(makeCaptureActionItem(
                    title: "Show Region",
                    action: #selector(showCaptureRegion(_:)),
                    representedObject: preset.id
                ))
                presetMenu.addItem(makeCaptureActionItem(
                    title: "Screenshot",
                    action: #selector(screenshotCapturePreset(_:)),
                    representedObject: preset.id
                ))
                presetMenu.addItem(makeCaptureActionItem(
                    title: "Record",
                    action: #selector(recordCapturePreset(_:)),
                    representedObject: preset.id
                ))
                presetMenu.addItem(.separator())
                presetMenu.addItem(makeCaptureActionItem(
                    title: "Rename…",
                    action: #selector(renameCapturePreset(_:)),
                    representedObject: preset.id
                ))
                presetMenu.addItem(makeCaptureActionItem(
                    title: "Delete",
                    action: #selector(deleteCapturePreset(_:)),
                    representedObject: preset.id
                ))
                presetItem.submenu = presetMenu
                submenu.addItem(presetItem)
            }
        }

        item.submenu = submenu
        return item
    }

    private func makeMenuSectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeActionItem(title: String, action: Selector, representedObject: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        return item
    }

    private func makeCaptureActionItem(title: String, action: Selector, representedObject: UUID) -> NSMenuItem {
        makeActionItem(title: title, action: action, representedObject: representedObject)
    }

    private func makeCaptureMenuItem(
        title: String,
        action: Selector,
        symbol: String,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = enabled
        if !modifiers.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        item.image = CaptureActionSymbol.image(for: symbol)
        return item
    }

    @objc func screenshotRegion(_ sender: Any) {
        beginRegionSelection(mode: .screenshot)
    }

    @objc func recordRegion(_ sender: Any) {
        beginRegionSelection(mode: .record)
    }

    func beginRegionScreenshot() {
        beginRegionSelection(mode: .screenshot)
    }

    func beginRegionRecording() {
        beginRegionSelection(mode: .record)
    }

    private enum RegionSelectionMode {
        case screenshot
        case record
    }

    private func beginRegionSelection(mode: RegionSelectionMode) {
        popoverController?.close()
        Task { await ensureScreenCaptureRegisteredOrPrompt() }
        RegionSelectorController.shared.beginSelection(
            intent: mode == .screenshot ? .screenshot : .record,
            initialRegion: mode == .screenshot ? LastScreenshotRegionStore.shared.region : nil,
            persistRegionOnDismiss: mode == .screenshot,
            onSaveRegion: { [weak self] region, done in
                self?.promptToSaveCapturePreset(region: region)
                done()
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .cancelled:
                    return
                case .screenshot(let region):
                    Task { await self.finishSelectedRegionScreenshot(region) }
                case .record(let region):
                    Task { await self.finishSelectedRegionRecording(region) }
                }
            }
        )
    }

    private func promptToSaveCapturePreset(region: CaptureRegion) {
        let alert = NSAlert()
        alert.messageText = "Save Capture Preset"
        alert.informativeText = region.displayDescription
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Demo Area"
        field.stringValue = suggestedCapturePresetName(for: region)
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        CapturePresetStore.shared.save(CapturePreset(name: name, region: region))
        showTransientAlert(message: "Saved capture preset \"\(name)\"")
    }

    private func suggestedCapturePresetName(for region: CaptureRegion) -> String {
        let existing = CapturePresetStore.shared.presets.map(\.name)
        let base = "\(Int(region.width))×\(Int(region.height))"
        guard existing.contains(base) else { return base }

        var counter = 2
        while existing.contains("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    private func capturePreset(id: UUID) -> CapturePreset? {
        CapturePresetStore.shared.presets.first { $0.id == id }
    }

    @objc private func showCaptureRegion(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let preset = capturePreset(id: id) else { return }
        RegionOverlayController.shared.show(region: preset.region, label: preset.name)
    }

    @objc private func screenshotCapturePreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let preset = capturePreset(id: id) else { return }
        Task { await screenshotPreset(preset) }
    }

    @objc private func recordCapturePreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let preset = capturePreset(id: id) else { return }
        Task { await recordPreset(preset) }
    }

    @objc private func renameCapturePreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let preset = capturePreset(id: id) else { return }
        promptToRenameCapturePreset(preset)
    }

    @objc private func deleteCapturePreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        CapturePresetStore.shared.delete(id: id)
    }

    @objc func captureWindow(_ sender: Any) {
        beginWindowCapture()
    }

    @objc func recordWindow(_ sender: Any) {
        beginWindowRecording()
    }

    func beginWindowCapture() {
        popoverController?.close()
        Task { await ensureScreenCaptureRegisteredOrPrompt() }
        WindowPickerOverlayController.shared.pickWindow(mode: .capture) { [weak self] window in
            guard let self, let window else { return }
            let name = WindowPickerController.suggestedName(for: window)
            Task { await self.captureWindowScreenshot(window: window, name: name) }
        }
    }

    func beginWindowRecording() {
        popoverController?.close()
        guard !ScreenCaptureService.shared.isRecording else {
            presentError(ScreenCaptureError.alreadyRecording)
            return
        }

        Task { await ensureScreenCaptureRegisteredOrPrompt() }
        WindowPickerOverlayController.shared.pickWindow(mode: .record) { [weak self] window in
            guard let self, let window else { return }
            let name = WindowPickerController.suggestedName(for: window)
            Task { await self.startWindowRecording(window: window, name: name) }
        }
    }

    private func captureWindowScreenshot(window: SCWindow, name: String) async {
        do {
            let url = try await ScreenCaptureService.shared.captureScreenshot(window: window, name: name)
            presentCaptureSuccess(message: "Screenshot saved.", url: url)
        } catch {
            presentError(error)
        }
    }

    private func startWindowRecording(window: SCWindow, name: String) async {
        do {
            try await ScreenCaptureService.shared.startRecording(window: window, name: name)
            rebuildMenu()
        } catch {
            presentError(error)
        }
    }

    @objc private func stopRecording(_ sender: Any) {
        Task { await stopActiveRecording() }
    }

    func stopRecordingFromShortcut() {
        Task { await stopActiveRecording() }
    }

    private func screenshotPreset(_ preset: CapturePreset) async {
        do {
            let url = try await ScreenCaptureService.shared.captureScreenshot(for: preset)
            presentCaptureSuccess(message: "Screenshot saved.", url: url)
        } catch {
            presentError(error)
        }
    }

    private func finishSelectedRegionScreenshot(_ region: CaptureRegion) async {
        let name = suggestedCapturePresetName(for: region)
        do {
            let url = try await ScreenCaptureService.shared.captureScreenshot(for: region, name: name)
            presentCaptureSuccess(message: "Screenshot saved.", url: url)
        } catch {
            presentError(error)
        }
    }

    private func recordPreset(_ preset: CapturePreset) async {
        guard !ScreenCaptureService.shared.isRecording else {
            presentError(ScreenCaptureError.alreadyRecording)
            return
        }

        do {
            try await ScreenCaptureService.shared.startRecording(for: preset)
            RecordingDimOverlayController.shared.show(region: preset.region)
            rebuildMenu()
        } catch {
            presentError(error)
        }
    }

    private func finishSelectedRegionRecording(_ region: CaptureRegion) async {
        guard !ScreenCaptureService.shared.isRecording else {
            presentError(ScreenCaptureError.alreadyRecording)
            return
        }

        let name = suggestedCapturePresetName(for: region)
        do {
            try await ScreenCaptureService.shared.startRecording(region: region, name: name)
            RecordingDimOverlayController.shared.show(region: region)
            rebuildMenu()
        } catch {
            presentError(error)
        }
    }

    private func stopActiveRecording() async {
        let result: Result<URL, Error>
        do {
            let url = try await ScreenCaptureService.shared.stopRecording()
            result = .success(url)
        } catch {
            result = .failure(error)
        }
        RecordingDimOverlayController.shared.dismiss()
        // Always refresh so the recording indicator goes away even when the
        // writer reports failure or stopCapture throws.
        rebuildMenu()
        switch result {
        case .success(let url):
            presentCaptureSuccess(message: "Recording saved.", url: url)
        case .failure(let error):
            presentError(error)
        }
    }

    private func promptToRenameCapturePreset(_ preset: CapturePreset) {
        let alert = NSAlert()
        alert.messageText = "Rename Capture Preset"
        alert.informativeText = preset.region.displayDescription
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = preset.name
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var updated = preset
        updated.name = name
        CapturePresetStore.shared.update(updated)
    }

    @objc func saveFrontmostWidth(_ sender: Any) {
        saveFrontmostWidthFromShortcut()
    }

    func saveFrontmostWidthFromShortcut() {
        do {
            let width = try WindowResizer.frontmostWindowWidth(targetPID: capturedTargetPID)
            promptToSave(width: width)
        } catch WindowResizerError.accessibilityNotGranted {
            handleAccessibilityNeeded { [weak self] in
                self?.saveFrontmostWidthFromShortcut()
            }
        } catch {
            presentError(error)
        }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        applyPreset(id: id)
    }

    func applyPreset(at index: Int) {
        guard let preset = PresetStore.shared.preset(at: index) else { return }
        applyPreset(id: preset.id)
    }

    private func applyPreset(id: UUID) {
        guard let preset = PresetStore.shared.presets.first(where: { $0.id == id }) else { return }
        popoverController?.close()

        do {
            try WindowResizer.applyWidth(preset.width, targetPID: capturedTargetPID)
            showTransientAlert(message: "Applied \"\(preset.name)\" (\(Int(preset.width)) px)")
        } catch WindowResizerError.accessibilityNotGranted {
            handleAccessibilityNeeded { [weak self] in
                self?.applyPreset(id: id)
            }
        } catch {
            presentError(error)
        }
    }

    /// Ensure ClipStack is registered with TCC for Screen Recording. If the
    /// permission has never been requested for this code identity (e.g. right
    /// after a `tccutil reset ScreenCapture`, or on a freshly-installed
    /// build), `CGRequestScreenCaptureAccess()` is what actually registers
    /// the app with TCC and triggers the system prompt — `SCShareableContent`
    /// alone can silently fail without ever surfacing a prompt or adding a
    /// row in System Settings → Screen & System Audio Recording. Calling
    /// this when the user initiates a capture guarantees the prompt fires
    /// and ClipStack appears in the list.
    @MainActor
    private func ensureScreenCaptureRegisteredOrPrompt() async {
        await PermissionManager.refreshPermissionStatus()
        if PermissionManager.hasScreenCaptureAccess { return }
        _ = await PermissionManager.registerScreenCaptureAccess()
    }

    /// Show the system Accessibility prompt (so the user can grant or
    /// re-grant), and retry the original action when access is detected.
    /// This avoids the in-app permissions window for the common "I already
    /// granted this but the new build isn't trusted yet" case.
    private func handleAccessibilityNeeded(retry: @escaping () -> Void) {
        PermissionManager.requestAccessibilityAccess()

        if PermissionManager.hasAccessibilityAccess {
            retry()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText =
            "ClipStack needs Accessibility access to resize windows. Enable ClipStack under System Settings → Privacy & Security → Accessibility, then click Retry.\n\nIf ClipStack is already listed and enabled, toggle it off and back on to refresh the entry."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            PermissionManager.openSettings(for: .accessibility)
        case .alertSecondButtonReturn:
            if PermissionManager.hasAccessibilityAccess {
                retry()
            } else {
                handleAccessibilityNeeded(retry: retry)
            }
        default:
            break
        }
    }

    @objc private func renamePreset(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? UUID,
            let preset = PresetStore.shared.presets.first(where: { $0.id == id })
        else { return }

        promptToRename(preset)
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        PresetStore.shared.delete(id: id)
    }

    @objc private func openManagePresets(_ sender: NSMenuItem) {
        if manageWindowController == nil {
            manageWindowController = ManagePresetsWindowController()
        }
        manageWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openManageCapturePresets(_ sender: NSMenuItem) {
        if manageCaptureWindowController == nil {
            manageCaptureWindowController = ManageCapturePresetsWindowController()
        }
        manageCaptureWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func permissionsSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let summary: String
        if PermissionManager.hasAllPermissions {
            summary = "Ready"
        } else if PermissionManager.screenCaptureNeedsRelaunch {
            summary = "Relaunch Required"
        } else {
            summary = "Setup Required"
        }

        let statusItem = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        submenu.addItem(statusItem)

        if !PermissionManager.hasAllPermissions {
            for kind in PermissionManager.missingPermissions {
                let detail = NSMenuItem(
                    title: "  \(kind.title): \(PermissionManager.statusSummary(for: kind))",
                    action: nil,
                    keyEquivalent: ""
                )
                detail.isEnabled = false
                submenu.addItem(detail)
            }
            submenu.addItem(.separator())
        }

        let setupItem = NSMenuItem(
            title: PermissionManager.hasAllPermissions ? "View Permissions…" : "Allow Permissions…",
            action: #selector(openPermissions(_:)),
            keyEquivalent: ""
        )
        setupItem.target = self
        submenu.addItem(setupItem)

        item.submenu = submenu
        return item
    }

    @objc private func openPermissions(_ sender: Any?) {
        if permissionsWindowController == nil {
            permissionsWindowController = PermissionsWindowController()
        }
        permissionsWindowController?.refreshStatus()
        permissionsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc private func openSettings(_ sender: Any?) {
        popoverController?.close()
        SettingsWindowController.shared.open()
    }

    @objc private func clearClipboardHistory(_ sender: Any?) {
        popoverController?.close()
        ClipboardStore.shared.clearAll()
    }

    private func promptToSave(width: Double) {
        let alert = NSAlert()
        alert.messageText = "Save Window Width"
        alert.informativeText = "Name this width preset. ClipStack will only change width, not height."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Recording"
        field.stringValue = suggestedPresetName(for: Int(width))
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        PresetStore.shared.save(WidthPreset(name: name, width: width))
        showTransientAlert(message: "Saved \"\(name)\" at \(Int(width)) px")
    }

    private func promptToRename(_ preset: WidthPreset) {
        let alert = NSAlert()
        alert.messageText = "Rename Preset"
        alert.informativeText = "Current width: \(Int(preset.width)) px"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = preset.name
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var updated = preset
        updated.name = name
        PresetStore.shared.update(updated)
    }

    private func suggestedPresetName(for width: Int) -> String {
        let existing = PresetStore.shared.presets.map(\.name)
        let base = "\(width) px"
        guard existing.contains(base) else { return base }

        var counter = 2
        while existing.contains("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    private func presentError(_ error: Error) {
        if case ScreenCaptureError.permissionDenied = error {
            openPermissions(nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "ClipStack Couldn't Complete That Action"
        alert.informativeText = error.localizedDescription
        if let recovery = (error as? LocalizedError)?.recoverySuggestion {
            alert.informativeText += "\n\n\(recovery)"
        }
        alert.alertStyle = .warning

        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentCaptureSuccess(message: String, url: URL) {
        CaptureToastController.shared.show(for: url)
    }

    private func showTransientAlert(message: String) {
        guard let button = statusItem?.button else { return }
        button.toolTip = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusItem?.button?.toolTip = "ClipStack"
        }
    }
}
