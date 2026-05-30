import AVFoundation
import SwiftUI

/// Video preview for Downloads detail — uses `AVPlayerLayer` only (no `AVPlayerView`).
/// `AVPlayerView` crashes in non-activating panels when its control chrome loads SF Symbols.
struct DownloadDetailVideoPlayer: View {
    let url: URL

    @StateObject private var model = DownloadVideoPlayerModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            DownloadVideoLayerView(url: url, model: model)

            if model.showsChrome {
                DownloadVideoChrome(model: model)
                    .padding(10)
            }
        }
        .onHover { model.isHovering = $0 }
        .onDisappear { model.stop() }
    }
}

// MARK: - Player model

@MainActor
final class DownloadVideoPlayerModel: ObservableObject {
    @Published var isHovering = false
    @Published var isPlaying = false
    @Published var currentSeconds: Double = 0
    @Published var durationSeconds: Double = 0

    private(set) var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    var showsChrome: Bool {
        isHovering && durationSeconds > 0
    }

    func bind(player: AVPlayer, url: URL) {
        guard self.player !== player else { return }
        stop()

        self.player = player
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.automaticallyWaitsToMinimizeStalling = true

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentSeconds = time.seconds
                if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
                    self.durationSeconds = duration
                }
            }
        }

        player.play()
        isPlaying = true
    }

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        currentSeconds = 0
        durationSeconds = 0
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentSeconds = seconds
    }
}

// MARK: - Layer host

private struct DownloadVideoLayerView: NSViewRepresentable {
    let url: URL
    @ObservedObject var model: DownloadVideoPlayerModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> VideoLayerHostView {
        let view = VideoLayerHostView()
        context.coordinator.attach(host: view)
        return view
    }

    func updateNSView(_ view: VideoLayerHostView, context: Context) {
        context.coordinator.setURL(url)
    }

    static func dismantleNSView(_ view: VideoLayerHostView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        private let model: DownloadVideoPlayerModel
        private weak var host: VideoLayerHostView?
        private var player: AVPlayer?
        private var currentURL: URL?
        private var isPlaybackStarted = false

        init(model: DownloadVideoPlayerModel) {
            self.model = model
        }

        func attach(host: VideoLayerHostView) {
            self.host = host
            host.onLayoutReady = { [weak self] in
                self?.startPlaybackIfReady()
            }
        }

        func setURL(_ url: URL) {
            guard currentURL != url else {
                startPlaybackIfReady()
                return
            }
            currentURL = url
            isPlaybackStarted = false
            model.stop()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            host?.playerLayer.player = nil
            startPlaybackIfReady()
        }

        func teardown() {
            host?.onLayoutReady = nil
            isPlaybackStarted = false
            model.stop()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            host?.playerLayer.player = nil
            host = nil
            currentURL = nil
        }

        private func startPlaybackIfReady() {
            guard let host, let url = currentURL else { return }
            guard host.window != nil else { return }
            guard host.bounds.width > 1, host.bounds.height > 1 else { return }
            guard !isPlaybackStarted else { return }

            let player = AVPlayer()
            self.player = player
            host.playerLayer.player = player
            host.playerLayer.videoGravity = .resizeAspect
            isPlaybackStarted = true
            model.bind(player: player, url: url)
        }
    }
}

@MainActor
final class VideoLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    var onLayoutReady: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        self.layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        notifyLayoutReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyLayoutReady()
    }

    private func notifyLayoutReady() {
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
        onLayoutReady?()
    }
}

// MARK: - Minimal chrome

private struct DownloadVideoChrome: View {
    @ObservedObject var model: DownloadVideoPlayerModel

    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.togglePlayback) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { model.currentSeconds },
                    set: { model.currentSeconds = $0 }
                ),
                in: 0...max(model.durationSeconds, 0.01),
                onEditingChanged: { editing in
                    if !editing {
                        model.seek(to: model.currentSeconds)
                    }
                }
            )
            .controlSize(.mini)

            Text(timeLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
    }

    private var timeLabel: String {
        let current = formatTime(model.currentSeconds)
        let total = formatTime(model.durationSeconds)
        return "\(current) / \(total)"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
