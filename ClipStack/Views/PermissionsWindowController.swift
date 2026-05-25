import AppKit

@MainActor
final class PermissionsWindowController: NSWindowController {
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let screenCaptureStatusLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let allowButton = NSButton()
    private let settingsButton = NSButton()
    private let relaunchButton = NSButton()
    private let footerLabel = NSTextField(wrappingLabelWithString: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipStack Setup"
        window.center()
        self.init(window: window)
        configureContent()
        refreshStatus()
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let intro = NSTextField(wrappingLabelWithString:
            "ClipStack needs two macOS permissions. Click Allow Permissions and approve each system prompt."
        )
        intro.font = NSFont.systemFont(ofSize: 13)
        intro.translatesAutoresizingMaskIntoConstraints = false

        accessibilityStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        accessibilityStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        screenCaptureStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        screenCaptureStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        allowButton.title = "Allow Permissions"
        allowButton.bezelStyle = .rounded
        allowButton.keyEquivalent = "\r"
        allowButton.target = self
        allowButton.action = #selector(allowPermissions(_:))
        allowButton.translatesAutoresizingMaskIntoConstraints = false

        settingsButton.title = "Open System Settings"
        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(openSettings(_:))
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        relaunchButton.title = "Quit & Relaunch ClipStack"
        relaunchButton.bezelStyle = .rounded
        relaunchButton.target = self
        relaunchButton.action = #selector(relaunch(_:))
        relaunchButton.translatesAutoresizingMaskIntoConstraints = false
        relaunchButton.isHidden = true

        footerLabel.font = NSFont.systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(intro)
        contentView.addSubview(accessibilityStatusLabel)
        contentView.addSubview(screenCaptureStatusLabel)
        contentView.addSubview(pathLabel)
        contentView.addSubview(allowButton)
        contentView.addSubview(settingsButton)
        contentView.addSubview(relaunchButton)
        contentView.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            intro.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            accessibilityStatusLabel.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 20),
            accessibilityStatusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            accessibilityStatusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            screenCaptureStatusLabel.topAnchor.constraint(equalTo: accessibilityStatusLabel.bottomAnchor, constant: 10),
            screenCaptureStatusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            screenCaptureStatusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            pathLabel.topAnchor.constraint(equalTo: screenCaptureStatusLabel.bottomAnchor, constant: 12),
            pathLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            pathLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            allowButton.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 20),
            allowButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            settingsButton.topAnchor.constraint(equalTo: allowButton.bottomAnchor, constant: 10),
            settingsButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            relaunchButton.topAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: 10),
            relaunchButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            footerLabel.topAnchor.constraint(equalTo: relaunchButton.bottomAnchor, constant: 16),
            footerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            footerLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            footerLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    func refreshStatus() {
        Task {
            await PermissionManager.refreshPermissionStatus()
            applyStatus()
        }
    }

    private func applyStatus() {
        updateStatusLabel(accessibilityStatusLabel, kind: .accessibility)

        switch PermissionManager.screenCapturePermissionState {
        case .granted:
            screenCaptureStatusLabel.stringValue = "✓  \(PermissionKind.screenCapture.title) — \(PermissionKind.screenCapture.purpose)"
            screenCaptureStatusLabel.textColor = .systemGreen
        case .denied:
            screenCaptureStatusLabel.stringValue = "○  \(PermissionKind.screenCapture.title) — \(PermissionKind.screenCapture.purpose)"
            screenCaptureStatusLabel.textColor = .labelColor
        case .needsRelaunch:
            screenCaptureStatusLabel.stringValue =
                "⟳  \(PermissionKind.screenCapture.title) — granted; quit and relaunch to activate"
            screenCaptureStatusLabel.textColor = .systemOrange
        }

        pathLabel.stringValue = "This app: \(PermissionManager.executablePath)"

        let allGranted = PermissionManager.hasAllPermissions
        let needsRelaunch = PermissionManager.screenCaptureNeedsRelaunch

        allowButton.isEnabled = !allGranted && !needsRelaunch
        allowButton.title = allGranted ? "All Permissions Granted" : "Allow Permissions"

        relaunchButton.isHidden = !needsRelaunch

        if allGranted {
            settingsButton.isHidden = true
            footerLabel.stringValue = "ClipStack is ready to use. You can close this window."
        } else if needsRelaunch {
            settingsButton.isHidden = true
            footerLabel.stringValue =
                "Screen Recording was granted while ClipStack was running. macOS only picks up that grant on the next launch. Click Quit & Relaunch."
        } else {
            settingsButton.isHidden = false
            settingsButton.title = "Open System Settings"
            let missing = PermissionManager.missingPermissions.map(\.title).joined(separator: " and ")
            footerLabel.stringValue =
                "If a prompt does not appear, use Open System Settings and enable ClipStack for \(missing)."
        }
    }

    @objc private func relaunch(_ sender: NSButton) {
        PermissionManager.relaunchApp()
    }

    private func updateStatusLabel(_ label: NSTextField, kind: PermissionKind) {
        let granted = PermissionManager.isGranted(kind)
        let symbol = granted ? "✓" : "○"
        label.stringValue = "\(symbol)  \(kind.title) — \(kind.purpose)"
        label.textColor = granted ? .systemGreen : .labelColor
    }

    @objc private func allowPermissions(_ sender: NSButton) {
        allowButton.isEnabled = false
        allowButton.title = "Waiting for approval…"

        Task {
            await PermissionManager.requestAllPermissions()
            applyStatus()
        }
    }

    @objc private func openSettings(_ sender: NSButton) {
        PermissionManager.openSettingsForMissingPermissions()
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshStatus()
            }
        }
    }
}
