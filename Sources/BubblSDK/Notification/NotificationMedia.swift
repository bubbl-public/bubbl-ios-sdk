#if os(iOS)
import AVFoundation
import AVKit
import SwiftUI
import WebKit
#if !COCOAPODS
import BubblCore
#endif

/// The media at the top of the card. Images show as they are; video and YouTube show their
/// picture with a Play button and then play right there in the card (nothing plays, and no sound
/// starts, until the person asks); audio's cover picture only (its player is a row in the card);
/// other kinds (a PDF, a file) open outside.
@available(iOS 17, *)
struct MediaHeader: View {
    @ObservedObject var model: NotificationModel
    let media: BubblNotification.Media
    @State private var playing = false

    var body: some View {
        switch media.kind {
        case .image:
            picture(height: Look.mediaMaxHeight)
                .onAppear { if media.url != nil { model.mediaViewed() } }
        case .video:
            if playing, let url = media.url.flatMap(URL.init(string:)) {
                InlineVideo(model: model, url: url).aspectRatio(16 / 9, contentMode: .fit)
            } else {
                videoPicture(button: media.url == nil ? nil : Words.play)
            }
        case .youtube:
            if let id = media.url.flatMap(YouTube.videoId) {
                if playing {
                    YouTubePlayer(videoId: id)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .onAppear { model.mediaViewed() }
                } else {
                    videoPicture(button: Words.play)
                }
            } else {
                openable
            }
        case .audio:
            picture(height: Look.mediaMaxHeight)
        case .application, .text, .file:
            openable
        }
    }

    /// Media the card can't show: its picture, and a button that opens it outside.
    private var openable: some View {
        picture(height: Look.mediaMaxHeight).overlay {
            if let url = media.url, LinkPolicy.canOpen(url) {
                OverlayButton(title: Words.open) { model.openMedia(url) }
            }
        }
    }

    private func videoPicture(button: String?) -> some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { picture(height: nil) }
            .overlay {
                if let button { OverlayButton(title: button) { playing = true } }
            }
            .clipped()
    }

    private func picture(height: CGFloat?) -> some View {
        Look.outline
            .frame(height: height)
            .overlay {
                if let url = media.pictureUrl.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                }
            }
            .clipped()
            .accessibilityElement()
            .accessibilityLabel(Words.mediaDescription(model.notification.headline))
            .accessibilityAddTraits(.isImage)
    }
}

/// A video file, played in the card with the system's controls.
@available(iOS 17, *)
struct InlineVideo: View {
    @ObservedObject var model: NotificationModel
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                guard player == nil else { return }
                Playback.prepareSession()
                let created = AVPlayer(url: url)
                player = created
                created.play()
                model.mediaViewed()
            }
            .onDisappear { player?.pause() }
            .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
                guard let item = player?.currentItem, (note.object as? AVPlayerItem) === item else { return }
                model.mediaCompleted(seconds: item.duration.seconds)
            }
    }
}

/// A YouTube video in YouTube's privacy-enhanced embedded player, in a web view kept to that one
/// page: no script bridge to the app, nothing kept between runs, and any link in it (Watch on
/// YouTube, the channel) opens outside rather than in the card. Its fullscreen button works. The
/// page is loaded with the app's own https origin as its address: YouTube refuses an embed that
/// doesn't say where it is (error 153).
@available(iOS 17, *)
struct YouTubePlayer: UIViewRepresentable {
    let videoId: String

    private static var origin: String {
        "https://" + (Bundle.main.bundleIdentifier ?? "tech.bubbl.sdk").lowercased()
    }

    func makeCoordinator() -> Coordinator { Coordinator(origin: Self.origin) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // The person has just tapped Play: let the player start without a second tap.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        if let html = YouTube.embedHtml(videoId: videoId, origin: Self.origin) {
            web.loadHTMLString(html, baseURL: URL(string: Self.origin))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let origin: String

        init(origin: String) {
            self.origin = origin
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The embed's own frames (the player) load normally.
            if let frame = navigationAction.targetFrame, !frame.isMainFrame { return .allow }
            // The page itself, at the app's origin.
            if let url = navigationAction.request.url, url.absoluteString.hasPrefix(origin) || url.scheme == "about" { return .allow }
            // Anything else leaves the card: opened outside.
            if let url = navigationAction.request.url, LinkPolicy.canOpen(url.absoluteString) {
                _ = await UIApplication.shared.open(url)
            }
            return .cancel
        }
    }
}

/// Audio's player, a row in the card: play/pause, a position to drag, and elapsed / total time.
/// Nothing loads or plays until Play is tapped.
@available(iOS 17, *)
struct AudioRow: View {
    @ObservedObject var model: NotificationModel
    let url: URL
    @StateObject private var playback = Playback()

    var body: some View {
        HStack(spacing: 12) {
            Button {
                playback.toggle(url) { model.mediaViewed() } completed: { model.mediaCompleted(seconds: $0) }
            } label: {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Look.onAccent)
                    .frame(width: 44, height: 44)
                    .background(Look.accent, in: Circle())
                    .opacity(playback.loading ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .disabled(playback.loading)
            .accessibilityLabel(playback.playing ? Words.pause : Words.play)
            .accessibilityIdentifier("bubbl.audio")

            Slider(value: Binding(get: { playback.position }, set: { playback.seek($0) }), in: 0...max(playback.duration, 0.1))
                .tint(Look.accent)
                .disabled(!playback.started)
                .accessibilityLabel(model.notification.headline)

            Text("\(Self.clock(playback.position)) / \(Self.clock(playback.duration))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Look.onSurfaceMuted)
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 14))
        .background(Look.mediaSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onDisappear { playback.stop() }
    }

    /// m:ss.
    static func clock(_ seconds: Double) -> String {
        let whole = seconds.isFinite ? max(Int(seconds), 0) : 0
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// One audio or video playback's state, for the audio row.
@available(iOS 17, *)
@MainActor
final class Playback: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var started = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    /// Plays even with the ring/silent switch on, as a person who taps Play expects, unless the app
    /// has set its own audio session up (then that's left as it is).
    static func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category == .soloAmbient { try? session.setCategory(.playback) }
    }

    func toggle(_ url: URL, viewed: @escaping @MainActor () -> Void, completed: @escaping @MainActor (Double) -> Void) {
        if let player {
            if playing { player.pause() } else { player.play() }
            playing.toggle()
            return
        }
        Self.prepareSession()
        loading = true
        let item = AVPlayerItem(url: url)
        let created = AVPlayer(playerItem: item)
        player = created
        statusObservation = Self.observeStatus(item) { [weak self] status, seconds in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .readyToPlay where !self.started:
                    self.loading = false
                    self.started = true
                    self.duration = seconds.isFinite ? seconds : 0
                    self.player?.play()
                    self.playing = true
                    viewed()
                case .failed:
                    self.loading = false
                    self.stop()
                default:
                    break
                }
            }
        }
        timeObserver = created.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.position = seconds.isFinite ? seconds : 0 }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playing = false
                completed(self.duration)
                self.player?.seek(to: .zero)
                self.position = 0
            }
        }
    }

    /// The item's status as it changes, on whatever thread AVFoundation reports it (so not main-actor
    /// code, which would trap off the main thread).
    nonisolated private static func observeStatus(_ item: AVPlayerItem, _ handler: @escaping @Sendable (AVPlayerItem.Status, Double) -> Void) -> NSKeyValueObservation {
        item.observe(\.status) { item, _ in handler(item.status, item.duration.seconds) }
    }

    func seek(_ seconds: Double) {
        position = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
        timeObserver = nil
        endObserver = nil
        statusObservation = nil
        player = nil
        playing = false
        started = false
    }
}

/// A button over media: Play, or Open.
@available(iOS 17, *)
struct OverlayButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Look.onAccent)
                .padding(.horizontal, 24)
                .frame(minHeight: 48)
                .background(Look.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bubbl.media")
    }
}
#endif
