import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplayFound
    case invalidRegion
    case invalidWindow
    case noWindowsAvailable
    case captureFailed(String)
    case alreadyRecording
    case notRecording
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "ClipStack needs Screen Recording access. Enable it in System Settings → Privacy & Security → Screen Recording."
        case .noDisplayFound:
            "No display was found for the saved capture region."
        case .invalidRegion:
            "The capture region is too small or invalid."
        case .invalidWindow:
            "That window can't be captured. It may have closed or be too small."
        case .noWindowsAvailable:
            "No on-screen windows are available to capture."
        case .captureFailed(let detail):
            "The screenshot could not be captured. \(detail)"
        case .alreadyRecording:
            "A recording is already in progress."
        case .notRecording:
            "No recording is in progress."
        case .writerFailed:
            "The screen recording could not be saved."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            "Open Permissions from the ClipStack menu and click Allow Permissions."
        default:
            nil
        }
    }
}

@MainActor
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()

    private(set) var isRecording = false
    private(set) var activePresetName: String?

    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var sessionStarted = false

    private init() {}

    static var hasScreenCaptureAccess: Bool {
        PermissionManager.hasScreenCaptureAccess
    }

    func captureScreenshot(for preset: CapturePreset) async throws -> URL {
        let image = try await captureImage(for: preset.region)
        return try saveScreenshot(image, name: preset.name)
    }

    func captureScreenshot(for region: CaptureRegion, name: String) async throws -> URL {
        let image = try await captureImage(for: region)
        return try saveScreenshot(image, name: name)
    }

    func captureScreenshot(window: SCWindow, name: String) async throws -> URL {
        let image = try await captureImage(for: window)
        return try saveScreenshot(image, name: name)
    }

    func startRecording(for preset: CapturePreset) async throws {
        try await startRecording(region: preset.region, name: preset.name)
    }

    func startRecording(region: CaptureRegion, name: String) async throws {
        guard !isRecording else { throw ScreenCaptureError.alreadyRecording }
        guard region.width >= 10, region.height >= 10 else { throw ScreenCaptureError.invalidRegion }

        let content = try await shareableContent()
        guard let display = display(for: region, in: content) else {
            throw ScreenCaptureError.noDisplayFound
        }

        let scale = screenScale(for: region) ?? 2.0
        let sourceRect = ScreenCoordinates.sourceRect(forCocoaRegion: region.cocoaRect, onQuartzDisplayFrame: display.frame)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(region.width * scale)
        configuration.height = Int(region.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        try await beginRecording(filter: filter, configuration: configuration, name: name)
    }

    func availableWindows() async throws -> [SCWindow] {
        let content = try await shareableContent()
        return content.windows
            .filter { $0.isOnScreen }
            .filter { $0.frame.width >= 40 && $0.frame.height >= 40 }
            .filter { ($0.owningApplication?.applicationName.isEmpty == false) }
            .sorted { lhs, rhs in
                let lhsApp = lhs.owningApplication?.applicationName ?? ""
                let rhsApp = rhs.owningApplication?.applicationName ?? ""
                if lhsApp == rhsApp {
                    return (lhs.title ?? "") < (rhs.title ?? "")
                }
                return lhsApp.localizedCaseInsensitiveCompare(rhsApp) == .orderedAscending
            }
    }

    func startRecording(window: SCWindow, name: String) async throws {
        guard !isRecording else { throw ScreenCaptureError.alreadyRecording }
        guard window.frame.width >= 40, window.frame.height >= 40 else { throw ScreenCaptureError.invalidWindow }

        let scale = screenScale(forWindow: window) ?? 2.0

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        // Window may resize during recording; keep output dimensions fixed by
        // fitting content into the initial size.
        configuration.scalesToFit = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        try await beginRecording(filter: filter, configuration: configuration, name: name)
    }

    private func beginRecording(filter: SCContentFilter, configuration: SCStreamConfiguration, name: String) async throws {
        let url = makeOutputURL(extension: "mov", prefix: "ClipStack Recording", name: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ScreenCaptureError.writerFailed }
        writer.add(input)

        let output = RecordingStreamOutput { [weak self] sampleBuffer in
            Task { @MainActor in
                self?.appendSampleBuffer(sampleBuffer, to: input, writer: writer)
            }
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)

        outputURL = url
        assetWriter = writer
        videoInput = input
        streamOutput = output
        self.stream = stream
        activePresetName = name
        sessionStarted = false
        isRecording = true

        do {
            try await stream.startCapture()
        } catch {
            resetRecordingState()
            try? FileManager.default.removeItem(at: url)
            throw Self.mapCaptureError(error, context: "Screen recording could not start.")
        }
    }

    func stopRecording() async throws -> URL {
        guard isRecording, let stream, let writer = assetWriter, let url = outputURL else {
            throw ScreenCaptureError.notRecording
        }

        // Capture state before we tear it down so we can still report.
        let hadSamples = sessionStarted

        var stopCaptureError: Error?
        do {
            try await stream.stopCapture()
        } catch {
            stopCaptureError = error
        }

        if hadSamples {
            videoInput?.markAsFinished()
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
        } else {
            // Writer was never started because no frames arrived. Cancel
            // explicitly so AVAssetWriter releases its resources cleanly.
            writer.cancelWriting()
        }

        resetRecordingState()

        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let hasUsableFile = fileExists && fileSize > 0

        if writer.status == .completed, hasUsableFile {
            return url
        }

        // The writer reports failure but a partial MOV exists on disk and is
        // playable in most cases. Surface it to the user instead of throwing
        // away their recording silently.
        if hasUsableFile {
            return url
        }

        if !fileExists || fileSize == 0 {
            try? FileManager.default.removeItem(at: url)
        }

        if let stopCaptureError {
            throw Self.mapCaptureError(stopCaptureError, context: "Stopping the recording failed.")
        }

        let detail = writer.error.map { ($0 as NSError).localizedDescription }
            ?? (hadSamples ? "The recorder finished in an unexpected state." : "No frames were captured before stopping.")
        throw ScreenCaptureError.captureFailed(detail)
    }

    private func resetRecordingState() {
        stream = nil
        streamOutput = nil
        assetWriter = nil
        videoInput = nil
        outputURL = nil
        activePresetName = nil
        sessionStarted = false
        isRecording = false
    }

    private func captureImage(for window: SCWindow) async throws -> CGImage {
        guard window.frame.width >= 40, window.frame.height >= 40 else { throw ScreenCaptureError.invalidWindow }

        let scale = screenScale(forWindow: window) ?? 2.0

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = true
        configuration.scalesToFit = true

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw Self.mapCaptureError(error, context: "Window screenshot capture failed.")
        }
    }

    private func captureImage(for region: CaptureRegion) async throws -> CGImage {
        guard region.width >= 10, region.height >= 10 else { throw ScreenCaptureError.invalidRegion }

        let content = try await shareableContent()
        guard let display = display(for: region, in: content) else {
            throw ScreenCaptureError.noDisplayFound
        }

        let scale = screenScale(for: region) ?? 2.0
        let sourceRect = ScreenCoordinates.sourceRect(forCocoaRegion: region.cocoaRect, onQuartzDisplayFrame: display.frame)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(region.width * scale)
        configuration.height = Int(region.height * scale)
        configuration.showsCursor = true
        configuration.scalesToFit = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw Self.mapCaptureError(error, context: "Screenshot capture failed.")
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            PermissionManager.markScreenCaptureAccessGranted()
            return content
        } catch {
            throw Self.mapCaptureError(error, context: "ScreenCaptureKit could not access displays.")
        }
    }

    private static func mapCaptureError(_ error: Error, context: String) -> ScreenCaptureError {
        if let captureError = error as? ScreenCaptureError {
            return captureError
        }

        if isPermissionRelated(error), !PermissionManager.hasScreenCaptureAccess {
            return .permissionDenied
        }

        let detail = (error as NSError).localizedDescription
        return .captureFailed("\(context) \(detail)")
    }

    private static func isPermissionRelated(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.userDeclined.rawValue {
            return true
        }

        let message = nsError.localizedDescription.lowercased()
        return message.contains("not authorized")
            || message.contains("permission")
            || message.contains("declined")
            || message.contains("denied")
    }

    private func display(for region: CaptureRegion, in content: SCShareableContent) -> SCDisplay? {
        let quartzRect = ScreenCoordinates.cocoaToQuartz(region.cocoaRect)
        let center = CGPoint(x: quartzRect.midX, y: quartzRect.midY)

        if let match = content.displays.first(where: { $0.frame.contains(center) }) {
            return match
        }

        return content.displays.first(where: { $0.frame.intersects(quartzRect) })
            ?? content.displays.first
    }

    private func screenScale(for region: CaptureRegion) -> CGFloat? {
        let center = CGPoint(x: region.cocoaRect.midX, y: region.cocoaRect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })?.backingScaleFactor
    }

    private func screenScale(forWindow window: SCWindow) -> CGFloat? {
        let cocoaCenter = ScreenCoordinates.quartzToCocoa(CGPoint(x: window.frame.midX, y: window.frame.midY))
        if let exact = ScreenCoordinates.screen(containingCocoaPoint: cocoaCenter) {
            return exact.backingScaleFactor
        }
        return NSScreen.screens.first?.backingScaleFactor
    }

    private func saveScreenshot(_ image: CGImage, name: String) throws -> URL {
        let url = makeOutputURL(extension: "png", prefix: "ClipStack Screenshot", name: name)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.captureFailed("Could not encode PNG data.")
        }
        try data.write(to: url)
        return url
    }

    private func makeOutputURL(extension ext: String, prefix: String, name: String) -> URL {
        let sanitized = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: .now)
        let filename = "\(prefix) - \(sanitized) - \(timestamp).\(ext)"
        guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/\(filename)")
        }
        return directory.appendingPathComponent(filename)
    }

    private func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput, writer: AVAssetWriter) {
        // SCStream emits frames with a status attachment; only `.complete`
        // frames carry usable image data. Idle/blank/suspended frames must be
        // ignored or the writer will reject them.
        guard Self.isCompleteFrame(sampleBuffer) else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // IMPORTANT: AVAssetWriterInput.isReadyForMoreMediaData starts as
        // `false` and only flips to `true` after `writer.startWriting()`. We
        // therefore must start the writer/session before consulting it,
        // otherwise every frame is dropped and the recording ends with zero
        // captured frames.
        if !sessionStarted {
            guard writer.startWriting() else { return }
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: startTime)
            sessionStarted = true
        }

        guard input.isReadyForMoreMediaData else { return }
        _ = input.append(sampleBuffer)
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            // No status attachment — treat as a usable frame so we don't
            // accidentally discard valid output on older SDK behaviour.
            return true
        }
        return status == .complete
    }
}

private final class RecordingStreamOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "com.theorichardson.ClipStack.recording", qos: .userInitiated)
    private let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        handler(sampleBuffer)
    }
}
