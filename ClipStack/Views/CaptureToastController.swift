import AppKit
import AVFoundation
import CoreImage
import QuartzCore

private func viewUsesDarkAppearance(_ view: NSView) -> Bool {
    let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
    return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

@MainActor
final class CaptureToastController {
    static let shared = CaptureToastController()

    private static let margin: CGFloat = 16
    private static let maxWidth: CGFloat = 200
    private static let maxHeight: CGFloat = 150
    private static let cornerRadius: CGFloat = 8
    // Extra padding around the thumbnail inside the window so the drop
    // shadow has room to render without being clipped at the window edge.
    private static let shadowPadding: CGFloat = 24
    private static let displayDuration: TimeInterval = 4
    private static let slideInDuration: TimeInterval = 0.35
    private static let slideOutDuration: TimeInterval = 0.3

    private var window: ToastWindow?
    private var dismissWorkItem: DispatchWorkItem?
    private var currentSourceURL: URL?
    private var restingFrame: NSRect?
    private var mouseMoveMonitor: Any?

    private init() {}

    func show(for url: URL) {
        dismiss(animated: false)

        guard let preview = previewImage(for: url) else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let supportsFraming = Self.isFrameableImage(url)

        let thumbnailSize = Self.thumbnailSize(for: preview.size)
        let windowSize = NSSize(
            width: thumbnailSize.width + Self.shadowPadding * 2,
            height: thumbnailSize.height + Self.shadowPadding * 2
        )
        let visible = screen.visibleFrame
        let finalOrigin = NSPoint(
            x: visible.maxX - thumbnailSize.width - Self.margin - Self.shadowPadding,
            y: visible.minY + Self.margin - Self.shadowPadding
        )
        let offscreenOrigin = NSPoint(
            x: visible.maxX + Self.margin,
            y: finalOrigin.y
        )

        let toast = ToastWindow(
            contentRect: NSRect(origin: offscreenOrigin, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = false
        toast.isMovable = false
        toast.isMovableByWindowBackground = false
        toast.hidesOnDeactivate = false
        // Mouse events must reach the toast so we can detect hover and
        // route clicks to the framing button.
        toast.ignoresMouseEvents = false
        toast.acceptsMouseMovedEvents = true
        toast.isReleasedWhenClosed = false
        toast.animationBehavior = .none
        toast.appearance = NSApp.effectiveAppearance
        toast.level = .popUpMenu
        toast.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        currentSourceURL = url

        let previewView = CapturePreviewView(
            image: preview,
            sourceURL: url,
            thumbnailSize: thumbnailSize,
            shadowPadding: Self.shadowPadding,
            cornerRadius: Self.cornerRadius,
            showsFrameButton: supportsFraming
        )
        previewView.onHoverChanged = { [weak self] isHovering in
            self?.handleHoverChanged(isHovering)
        }
        previewView.onFrameButtonClicked = { [weak self] button in
            self?.presentWallpaperMenu(from: button)
        }
        previewView.onCopyButtonClicked = { [weak self] in
            self?.copyCurrentCaptureToClipboard()
        }
        previewView.onCloseButtonClicked = { [weak self] in
            self?.dismiss(animated: true)
        }
        previewView.onDragWillBegin = { [weak self] in
            self?.handleDragWillBegin()
        }
        previewView.onDragEnded = { [weak self] endPoint, operation in
            self?.handleDragEnded(at: endPoint, operation: operation)
        }
        toast.contentView = previewView
        toast.alphaValue = 1
        toast.orderFrontRegardless()

        window = toast
        restingFrame = NSRect(origin: finalOrigin, size: windowSize)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            toast.animator().setFrame(NSRect(origin: finalOrigin, size: windowSize), display: true)
        }

        scheduleDismiss()
        installMouseMoveMonitor(for: previewView)
    }

    private func installMouseMoveMonitor(for previewView: CapturePreviewView) {
        removeMouseMoveMonitor()
        // LSUIElement apps are usually inactive while the toast is up, so rely
        // on a global mouse-moved monitor to keep cursor rects in sync.
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window != nil else { return }
                previewView.syncHoverFromCursorPosition()
            }
        }
    }

    private func removeMouseMoveMonitor() {
        if let mouseMoveMonitor {
            NSEvent.removeMonitor(mouseMoveMonitor)
            self.mouseMoveMonitor = nil
        }
    }

    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss(animated: true)
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: workItem)
    }

    private func handleDragWillBegin() {
        // Hide the toast window so only the AppKit drag image follows the
        // cursor. Cancel auto-dismiss while the drag is in flight.
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        window?.alphaValue = 0
    }

    private func handleDragEnded(at screenPoint: NSPoint, operation: NSDragOperation) {
        guard let toast = window, let resting = restingFrame else { return }

        if !operation.isEmpty {
            // The drop was accepted by some destination (Trash, Finder,
            // an app icon, etc.). When the operation is `.delete` (drop on
            // Trash), macOS expects the source to actually move the file
            // to the Trash itself — it doesn't do that automatically for
            // pasteboard file URLs originated from a third-party app.
            if operation.contains(.delete), let url = currentSourceURL {
                Self.moveFileToTrash(at: url)
            }
            window = nil
            currentSourceURL = nil
            restingFrame = nil
            removeMouseMoveMonitor()
            toast.orderOut(nil)
            return
        }

        // User released into empty space. If they flung the thumbnail far
        // enough to the right (or actually past the screen edge), treat it
        // as a swipe-to-dismiss. Otherwise restore the toast in place.
        let rightDismissThreshold = resting.maxX + 60
        if screenPoint.x >= rightDismissThreshold {
            window = nil
            currentSourceURL = nil
            restingFrame = nil
            removeMouseMoveMonitor()
            toast.orderOut(nil)
            return
        }

        // Restore the toast at its resting frame with a quick fade-in.
        toast.setFrame(resting, display: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            toast.animator().alphaValue = 1
        }
        (toast.contentView as? CapturePreviewView)?.resetHoverState()
        scheduleDismiss()
    }

    private static func moveFileToTrash(at url: URL) {
        // NSWorkspace.recycle gives the standard Trash chime/animation that
        // users expect when dropping onto the Dock's Trash.
        NSWorkspace.shared.recycle([url]) { _, error in
            if let error {
                NSLog("CaptureToast: failed to move \(url.path) to Trash: \(error)")
            }
        }
    }

    private func handleHoverChanged(_ isHovering: Bool) {
        if isHovering {
            // Pause auto-dismiss while the user is interacting with the toast.
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
        } else {
            scheduleDismiss()
        }
    }

    private func presentWallpaperMenu(from button: NSButton) {
        // Keep the toast on screen while the menu is open.
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Frame with Wallpaper", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for frame in WallpaperFrameLibrary.all {
            let item = NSMenuItem(
                title: frame.name,
                action: #selector(handleWallpaperSelection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = frame.id
            item.image = swatchImage(for: frame)
            menu.addItem(item)
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )

        // Menu was dismissed; restart auto-dismiss unless we're already
        // re-hovered (the tracking area will manage that).
        scheduleDismiss()
    }

    private func swatchImage(for frame: WallpaperFrame) -> NSImage {
        let size = NSSize(width: 22, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        let swatch = frame.makeImage(size: size)
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        swatch.draw(in: rect)
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        return image
    }

    private func copyCurrentCaptureToClipboard() {
        guard let url = currentSourceURL else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp"]

        var wroteSomething = false
        if imageExts.contains(ext), let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
            wroteSomething = true
        }
        // Also write the file URL so paste targets that want the file (e.g.
        // Finder, mail) get the original on-disk asset including video.
        pasteboard.writeObjects([url as NSURL])
        wroteSomething = true

        _ = wroteSomething
    }

    @objc private func handleWallpaperSelection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let frame = WallpaperFrameLibrary.all.first(where: { $0.id == id }),
              let sourceURL = currentSourceURL
        else { return }

        // Dismiss the existing toast immediately so we can replace it with
        // the framed result once it lands.
        let previousURL = sourceURL
        dismiss(animated: true)

        Task.detached(priority: .userInitiated) {
            do {
                let newURL = try ImageFramer.frameImage(at: previousURL, with: frame)
                await MainActor.run {
                    CaptureToastController.shared.show(for: newURL)
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't frame screenshot"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    private func previewImage(for url: URL) -> NSImage? {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "tif", "tiff", "heic":
            return NSImage(contentsOf: url)
        case "mov", "mp4", "m4v":
            return videoThumbnail(for: url)
        default:
            return NSImage(contentsOf: url)
        }
    }

    private func videoThumbnail(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.maxWidth * 2, height: Self.maxHeight * 2)

        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private static func isFrameableImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "tif", "tiff", "heic"].contains(url.pathExtension.lowercased())
    }

    private static func thumbnailSize(for imageSize: NSSize) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: maxWidth, height: maxHeight)
        }

        let scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1)
        return NSSize(
            width: max(1, (imageSize.width * scale).rounded()),
            height: max(1, (imageSize.height * scale).rounded())
        )
    }

    private func dismiss(animated: Bool) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        removeMouseMoveMonitor()

        guard let toast = window else { return }
        window = nil
        currentSourceURL = nil
        restingFrame = nil

        let visible = toast.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? toast.frame
        let exitOrigin = NSPoint(
            x: visible.maxX + Self.margin,
            y: toast.frame.origin.y
        )

        guard animated else {
            toast.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.slideOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            toast.animator().setFrame(
                NSRect(origin: exitOrigin, size: toast.frame.size),
                display: true
            )
        }, completionHandler: {
            Task { @MainActor in
                toast.orderOut(nil)
            }
        })
    }
}

/// Borderless window used for the capture preview. Opt out of key/main
/// eligibility so the toast never steals focus from the user's frontmost app.
private final class ToastWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CapturePreviewView: NSView, NSDraggingSource {
    var onHoverChanged: ((Bool) -> Void)?
    var onFrameButtonClicked: ((NSButton) -> Void)?
    var onCopyButtonClicked: (() -> Void)?
    var onCloseButtonClicked: (() -> Void)?
    var onDragWillBegin: (() -> Void)?
    var onDragEnded: ((NSPoint, NSDragOperation) -> Void)?

    private let sourceImage: NSImage
    private let sourceURL: URL
    private let thumbnailSize: NSSize
    private let imageContainer = NSView()
    private let hoverOverlay = NSView()
    private let hoverDarkTint = NSView()
    private let frameButton: HoverPillButton?
    private let copyButton: HoverPillButton
    private let closeButton: HoverCircleIconButton
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var copyRevertWorkItem: DispatchWorkItem?
    private var mouseDownLocation: NSPoint?
    private var didStartDrag = false

    init(
        image: NSImage,
        sourceURL: URL,
        thumbnailSize: NSSize,
        shadowPadding: CGFloat,
        cornerRadius: CGFloat,
        showsFrameButton: Bool
    ) {
        self.sourceImage = image
        self.sourceURL = sourceURL
        self.thumbnailSize = thumbnailSize
        if showsFrameButton {
            self.frameButton = Self.makePillButton(title: "Background")
        } else {
            self.frameButton = nil
        }
        self.copyButton = Self.makePillButton(title: "Copy")
        self.closeButton = Self.makeCloseButton()

        let frame = NSRect(
            x: 0,
            y: 0,
            width: thumbnailSize.width + shadowPadding * 2,
            height: thumbnailSize.height + shadowPadding * 2
        )
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Floaty drop shadow lives on a shadow host view so the rounded
        // image mask (masksToBounds) below it doesn't clip the shadow.
        let shadowHost = NSView(frame: NSRect(
            x: shadowPadding,
            y: shadowPadding,
            width: thumbnailSize.width,
            height: thumbnailSize.height
        ))
        shadowHost.wantsLayer = true
        shadowHost.layer?.backgroundColor = NSColor.white.cgColor
        shadowHost.layer?.cornerRadius = cornerRadius
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.28
        shadowHost.layer?.shadowRadius = 18
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -6)
        shadowHost.layer?.masksToBounds = false
        shadowHost.autoresizingMask = []
        addSubview(shadowHost)

        imageContainer.frame = shadowHost.bounds
        imageContainer.wantsLayer = true
        imageContainer.layer?.cornerRadius = cornerRadius
        imageContainer.layer?.masksToBounds = true
        imageContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        imageContainer.layer?.borderWidth = 1
        imageContainer.autoresizingMask = [.width, .height]
        shadowHost.addSubview(imageContainer)

        let imageView = NSImageView(frame: imageContainer.bounds)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageContainer.addSubview(imageView)

        // Darkening + blur overlay shown only while hovered. The blur is a
        // pre-rendered copy of the thumbnail (cheap, doesn't reanimate on
        // every frame), with a dark tint stacked on top.
        hoverOverlay.frame = imageContainer.bounds
        hoverOverlay.autoresizingMask = [.width, .height]
        hoverOverlay.wantsLayer = true
        hoverOverlay.alphaValue = 0

        let blurredImageView = NSImageView(frame: hoverOverlay.bounds)
        blurredImageView.image = Self.blurredImage(from: image, radius: 12)
        blurredImageView.imageScaling = .scaleAxesIndependently
        blurredImageView.autoresizingMask = [.width, .height]
        hoverOverlay.addSubview(blurredImageView)

        hoverDarkTint.frame = hoverOverlay.bounds
        hoverDarkTint.wantsLayer = true
        hoverDarkTint.autoresizingMask = [.width, .height]
        hoverOverlay.addSubview(hoverDarkTint)

        imageContainer.addSubview(hoverOverlay)
        updateHoverOverlayAppearance()

        copyButton.target = self
        copyButton.action = #selector(handleCopyButton)
        imageContainer.addSubview(copyButton)

        if let button = frameButton {
            button.target = self
            button.action = #selector(handleFrameButton)
            imageContainer.addSubview(button)
        }

        closeButton.target = self
        closeButton.action = #selector(handleCloseButton)
        imageContainer.addSubview(closeButton)

        layoutButtons()
        layoutCloseButton()
        [frameButton, copyButton].compactMap { $0 }.forEach { $0.refreshAppearance() }
        closeButton.refreshAppearance()
    }

    private func animateButtonLayout() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            layoutButtons(animated: true)
        }
    }

    private func layoutButtons(animated: Bool = false) {
        let buttonHeight: CGFloat = 26
        let horizontalPadding: CGFloat = 14
        let spacing: CGFloat = 6

        let visibleButtons: [HoverPillButton] = [frameButton, copyButton].compactMap { $0 }
        let totalHeight = CGFloat(visibleButtons.count) * buttonHeight + CGFloat(max(0, visibleButtons.count - 1)) * spacing
        var y = (imageContainer.bounds.height + totalHeight) / 2 - buttonHeight

        for button in visibleButtons {
            let titleSize = NSAttributedString(
                string: button.pillTitle,
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
            ).size()
            let width = (titleSize.width + horizontalPadding * 2).rounded(.up)
            let newFrame = NSRect(
                x: ((imageContainer.bounds.width - width) / 2).rounded(),
                y: y,
                width: width,
                height: buttonHeight
            )
            if animated {
                button.animator().frame = newFrame
            } else {
                button.frame = newFrame
            }
            button.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            button.layer?.cornerRadius = buttonHeight / 2
            y -= (buttonHeight + spacing)
        }
        window?.invalidateCursorRects(for: self)
    }

    private func layoutCloseButton() {
        let size: CGFloat = 22
        let inset: CGFloat = 4
        closeButton.frame = NSRect(
            x: imageContainer.bounds.width - size - inset,
            y: imageContainer.bounds.height - size - inset,
            width: size,
            height: size
        )
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        closeButton.layer?.cornerRadius = size / 2
    }

    private static func makePillButton(title: String) -> HoverPillButton {
        let button = HoverPillButton()
        button.isBordered = false
        button.bezelStyle = .smallSquare
        button.setPillTitle(title)
        button.wantsLayer = true
        button.alphaValue = 0
        return button
    }

    private static func makeCloseButton() -> HoverCircleIconButton {
        let button = HoverCircleIconButton(symbolName: "xmark")
        button.isBordered = false
        button.bezelStyle = .smallSquare
        button.wantsLayer = true
        return button
    }

    private static func blurredImage(from image: NSImage, radius: CGFloat) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let ciInput = CIImage(data: tiff),
              let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciInput.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(output, from: ciInput.extent) else { return nil }
        return NSImage(cgImage: cg, size: image.size)
    }

    private func updateHoverOverlayAppearance() {
        let isDark = viewUsesDarkAppearance(self)
        hoverDarkTint.layer?.backgroundColor = (
            isDark
                ? NSColor.white.withAlphaComponent(0.16)
                : NSColor.black.withAlphaComponent(0.32)
        ).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverOverlayAppearance()
        for button in [frameButton, copyButton].compactMap({ $0 }) {
            button.refreshAppearance()
        }
        closeButton.refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            imageContainer.removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: imageContainer.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        imageContainer.addTrackingArea(area)
        trackingArea = area
        syncHoverFromCursorPosition()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The toast typically slides in directly under the cursor (the user
        // just hit the capture shortcut). In that case AppKit never delivers
        // a mouseEntered event because the cursor never crossed the tracking
        // boundary, so we have to seed the hover state ourselves.
        syncHoverFromCursorPosition()
    }

    fileprivate func syncHoverFromCursorPosition() {
        guard let window = imageContainer.window else { return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInContainer = imageContainer.convert(mouseInWindow, from: nil)
        let inside = imageContainer.bounds.contains(mouseInContainer)
        updateHover(inside)
        syncButtonHover(at: mouseInContainer)
        refreshCursor(at: mouseInContainer)
    }

    override func mouseMoved(with event: NSEvent) {
        let mouseInContainer = imageContainer.convert(event.locationInWindow, from: nil)
        syncButtonHover(at: mouseInContainer)
        refreshCursor(at: mouseInContainer)
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        let closeRect = convert(closeButton.frame, from: imageContainer)
        addCursorRect(closeRect, cursor: .pointingHand)

        guard isHovering else { return }

        let containerRect = convert(imageContainer.bounds, from: imageContainer)
        addCursorRect(containerRect, cursor: .openHand)

        for button in [frameButton, copyButton].compactMap({ $0 }) {
            let buttonRect = convert(button.frame, from: imageContainer)
            addCursorRect(buttonRect, cursor: .pointingHand)
        }
    }

    private func refreshCursor(at pointInContainer: NSPoint) {
        window?.invalidateCursorRects(for: self)
        cursor(at: pointInContainer).set()
    }

    private func cursor(at pointInContainer: NSPoint) -> NSCursor {
        guard imageContainer.bounds.contains(pointInContainer) else {
            return .arrow
        }
        if closeButton.frame.contains(pointInContainer) {
            return .pointingHand
        }
        guard isHovering else { return .arrow }
        if [frameButton, copyButton].compactMap({ $0 }).contains(where: { $0.frame.contains(pointInContainer) }) {
            return .pointingHand
        }
        return .openHand
    }

    private func syncButtonHover(at pointInContainer: NSPoint) {
        closeButton.syncPointerHover(isPointerInside: closeButton.frame.contains(pointInContainer))
        let pillButtons: [HoverPillButton] = [frameButton, copyButton].compactMap { $0 }
        for button in pillButtons {
            button.syncPointerHover(isPointerInside: isHovering && button.frame.contains(pointInContainer))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(true)
        let mouseInContainer = imageContainer.convert(event.locationInWindow, from: nil)
        syncButtonHover(at: mouseInContainer)
        refreshCursor(at: mouseInContainer)
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(false)
        refreshCursor(at: imageContainer.convert(event.locationInWindow, from: nil))
    }

    private func updateHover(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        setHoverVisible(hovering)
        onHoverChanged?(hovering)
        window?.invalidateCursorRects(for: self)
    }

    private func setHoverVisible(_ visible: Bool) {
        let buttons: [HoverPillButton] = [frameButton, copyButton].compactMap { $0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            hoverOverlay.animator().alphaValue = visible ? 1 : 0
            for button in buttons {
                button.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Buttons handle their own mouseDown via the responder chain because
        // hit-testing routes the event to them directly. Anything that
        // reaches the view itself is a candidate to start a drag.
        mouseDownLocation = event.locationInWindow
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let start = mouseDownLocation else { return }
        let current = event.locationInWindow
        let dx = current.x - start.x
        let dy = current.y - start.y
        // Threshold so an idle wobble during a click doesn't kick off a drag.
        guard dx * dx + dy * dy > 16 else { return }

        didStartDrag = true
        NSCursor.closedHand.set()
        startDragSession(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        didStartDrag = false
    }

    private func startDragSession(with event: NSEvent) {
        onDragWillBegin?()

        let dragSize = thumbnailSize
        let dragImage = sourceImage

        let item = NSDraggingItem(pasteboardWriter: sourceURL as NSURL)
        // Place the drag image where the thumbnail visually sits inside the
        // toast window so the drag begins from under the cursor.
        item.draggingFrame = imageContainer.frame
        item.imageComponentsProvider = {
            let component = NSDraggingImageComponent(key: .icon)
            component.contents = dragImage
            component.frame = NSRect(origin: .zero, size: dragSize)
            return [component]
        }

        let session = beginDraggingSession(with: [item], event: event, source: self)
        // We hide the toast as soon as the drag starts and handle the
        // "release in empty space" case ourselves, so we don't want AppKit's
        // default slide-back animation.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            // Allow Trash (.delete), Finder/apps (.copy/.link/.move/.generic).
            return [.copy, .link, .generic, .move, .delete]
        case .withinApplication:
            return []
        @unknown default:
            return [.copy, .generic]
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?(screenPoint, operation)
        mouseDownLocation = nil
        didStartDrag = false
    }

    func resetHoverState() {
        isHovering = false
        let buttons: [HoverPillButton] = [frameButton, copyButton].compactMap { $0 }
        hoverOverlay.alphaValue = 0
        for button in buttons {
            button.alphaValue = 0
        }
        syncHoverFromCursorPosition()
    }

    @objc private func handleFrameButton() {
        guard let button = frameButton else { return }
        onFrameButtonClicked?(button)
    }

    @objc private func handleCloseButton() {
        onCloseButtonClicked?()
    }

    @objc private func handleCopyButton() {
        onCopyButtonClicked?()

        copyRevertWorkItem?.cancel()
        copyButton.setPillTitle("Copied!", animated: true)
        animateButtonLayout()

        let revert = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copyButton.setPillTitle("Copy", animated: true)
            self.animateButtonLayout()
        }
        copyRevertWorkItem = revert
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: revert)
    }
}

/// Pill-shaped button with hover and pressed states, and a cross-fade
/// animation when its title changes. Cursor styling is handled by the parent
/// preview view so the thumbnail can use a drag cursor separately.
private final class HoverPillButton: NSButton {
    private let titleLayer = CATextLayer()
    private var trackingArea: NSTrackingArea?
    private var baseBackgroundColor: NSColor = NSColor.white.withAlphaComponent(0.92)
    private var hoverBackgroundColor: NSColor = NSColor.white.withAlphaComponent(1.0)
    private var pressedBackgroundColor: NSColor = NSColor.white.withAlphaComponent(0.70)
    private var isHovering = false {
        didSet { applyBackground() }
    }
    private var isPressed = false {
        didSet { applyBackground() }
    }

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func commonInit() {
        wantsLayer = true

        // Use a CATextLayer so we can cross-fade title changes without the
        // default uncrossfaded snap that NSButton's title property gives us.
        titleLayer.alignmentMode = .center
        titleLayer.foregroundColor = NSColor.labelColor.cgColor
        titleLayer.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLayer.fontSize = 12
        titleLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(titleLayer)
        title = ""
        attributedTitle = NSAttributedString()
        refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        let isDark = viewUsesDarkAppearance(self)
        if isDark {
            baseBackgroundColor = NSColor(white: 0.13, alpha: 0.94)
            hoverBackgroundColor = NSColor(white: 0.20, alpha: 1.0)
            pressedBackgroundColor = NSColor(white: 0.09, alpha: 0.82)
            titleLayer.foregroundColor = NSColor(white: 0.96, alpha: 1.0).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            layer?.shadowOpacity = 0.45
        } else {
            baseBackgroundColor = NSColor.white.withAlphaComponent(0.92)
            hoverBackgroundColor = NSColor.white.withAlphaComponent(1.0)
            pressedBackgroundColor = NSColor.white.withAlphaComponent(0.70)
            titleLayer.foregroundColor = NSColor(white: 0.10, alpha: 0.92).cgColor
            layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
            layer?.shadowOpacity = 0.18
        }
        layer?.borderWidth = 0.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.masksToBounds = false
        applyBackground()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        // NSButton installs an arrow cursor rect by default; leave cursor
        // styling to CapturePreviewView so the thumbnail can use open hand.
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    func syncPointerHover(isPointerInside: Bool) {
        isHovering = isPointerInside
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 16
        titleLayer.frame = NSRect(
            x: 0,
            y: (bounds.height - height) / 2,
            width: bounds.width,
            height: height
        )
        layer?.cornerRadius = bounds.height / 2
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
        isHovering = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    private func applyBackground() {
        let color: NSColor
        if isPressed {
            color = pressedBackgroundColor
        } else if isHovering {
            color = hoverBackgroundColor
        } else {
            color = baseBackgroundColor
        }
        layer?.backgroundColor = color.cgColor
    }

    func setPillTitle(_ newTitle: String, animated: Bool = false) {
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            titleLayer.add(fade, forKey: "titleFade")
        }
        titleLayer.string = newTitle
    }

    var pillTitle: String {
        (titleLayer.string as? String) ?? ""
    }
}

/// Circular icon button matching `HoverPillButton` chrome (always visible on the toast).
private final class HoverCircleIconButton: NSButton {
    private let iconView = NSImageView()
    private let symbolName: String
    private var trackingArea: NSTrackingArea?
    private var baseBackgroundColor: NSColor = NSColor.white.withAlphaComponent(0.92)
    private var hoverBackgroundColor: NSColor = NSColor.white.withAlphaComponent(1.0)
    private var pressedBackgroundColor: NSColor = NSColor.white.withAlphaComponent(0.70)
    private var isHovering = false {
        didSet { applyBackground() }
    }
    private var isPressed = false {
        didSet { applyBackground() }
    }

    override var wantsUpdateLayer: Bool { true }

    init(symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func commonInit() {
        wantsLayer = true
        title = ""
        attributedTitle = NSAttributedString()

        iconView.imageScaling = .scaleProportionallyDown
        iconView.autoresizingMask = [.width, .height]
        addSubview(iconView)
        refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        let isDark = viewUsesDarkAppearance(self)
        if isDark {
            baseBackgroundColor = NSColor(white: 0.13, alpha: 0.94)
            hoverBackgroundColor = NSColor(white: 0.20, alpha: 1.0)
            pressedBackgroundColor = NSColor(white: 0.09, alpha: 0.82)
            layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            layer?.shadowOpacity = 0.45
        } else {
            baseBackgroundColor = NSColor.white.withAlphaComponent(0.92)
            hoverBackgroundColor = NSColor.white.withAlphaComponent(1.0)
            pressedBackgroundColor = NSColor.white.withAlphaComponent(0.70)
            layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
            layer?.shadowOpacity = 0.18
        }
        layer?.borderWidth = 0.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.masksToBounds = false

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let tint = isDark ? NSColor(white: 0.96, alpha: 1.0) : NSColor(white: 0.10, alpha: 0.92)
        iconView.contentTintColor = tint
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Close"
        )?.withSymbolConfiguration(symbolConfig)

        applyBackground()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {}

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    func syncPointerHover(isPointerInside: Bool) {
        isHovering = isPointerInside
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 5
        iconView.frame = bounds.insetBy(dx: inset, dy: inset)
        layer?.cornerRadius = bounds.height / 2
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
        isHovering = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    private func applyBackground() {
        let color: NSColor
        if isPressed {
            color = pressedBackgroundColor
        } else if isHovering {
            color = hoverBackgroundColor
        } else {
            color = baseBackgroundColor
        }
        layer?.backgroundColor = color.cgColor
    }
}
