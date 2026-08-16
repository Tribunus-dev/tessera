import SwiftUI
import AVKit
import AVFoundation
import TesseraCore

// MARK: - MediaPlaybackView
//
// Minimal AVKit playback surface for a slide's ``MediaBlock`` (P1 1.4
// write path, wired P2-0 item 2). Presentation-layer only, per
// `MediaBlock`'s own doc comment ("Deliberately NOT a wrapper around
// any AVFoundation type... the actual AVFoundation playback session is
// a view-layer concern built from this spec at render time, never
// stored alongside it") - this view is exactly that view-layer
// concern; it does not change `MediaBlock`'s shape or import
// AVFoundation into `TesseraCore`.
//
// `.video` gets the full `VideoPlayer` chrome (native transport
// controls, fullscreen). `.audio` has no picture to show, so it gets a
// compact play/pause control instead of an empty video surface -
// `VideoPlayer` on an audio-only asset would render a blank rect with
// full playback chrome, which reads as broken, not minimal.
public struct MediaPlaybackView: View {
    public let media: MediaBlock

    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var loopObserver: NSObjectProtocol?

    public init(media: MediaBlock) {
        self.media = media
    }

    public var body: some View {
        Group {
            switch media.kind {
            case .video:
                videoPlayer
            case .audio:
                audioPlayer
            }
        }
        .onAppear { configurePlayer() }
        .onChange(of: media.sourceURL) { _, _ in configurePlayer() }
        .onDisappear { teardownPlayer() }
    }

    // MARK: - Video

    @ViewBuilder
    private var videoPlayer: some View {
        if let player {
            VideoPlayer(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else {
            unavailablePlaceholder
        }
    }

    // MARK: - Audio

    private var audioPlayer: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(player == nil)
            .accessibilityLabel(isPlaying ? "Pause audio" : "Play audio")

            VStack(alignment: .leading, spacing: 2) {
                Text("Audio").font(.caption).foregroundStyle(.secondary)
                if let duration = media.durationSeconds {
                    Text(Self.formattedDuration(duration))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            Spacer()
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var unavailablePlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary.opacity(0.4))
            .overlay {
                Label("Media unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .accessibilityLabel("Media unavailable")
    }

    // MARK: - Player lifecycle

    private func configurePlayer() {
        teardownPlayer()
        guard let url = Self.resolveURL(media.sourceURL) else {
            player = nil
            return
        }
        let newPlayer = AVPlayer(url: url)
        if media.loop {
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: newPlayer.currentItem,
                queue: .main
            ) { _ in
                newPlayer.seek(to: .zero)
                newPlayer.play()
            }
        }
        player = newPlayer
        isPlaying = false
        if media.autoplay {
            newPlayer.play()
            isPlaying = true
        }
    }

    private func teardownPlayer() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        player?.pause()
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    // MARK: - Helpers

    /// `sourceURL` is a plain string (see `MediaBlock`'s header
    /// comment: no persisted model in this codebase stores `URL`
    /// directly) - resolves as a local file path first, falling back
    /// to a general URL parse for `http(s)://` sources.
    static func resolveURL(_ sourceURL: String) -> URL? {
        guard !sourceURL.isEmpty else { return nil }
        if sourceURL.hasPrefix("http://") || sourceURL.hasPrefix("https://") {
            return URL(string: sourceURL)
        }
        if FileManager.default.fileExists(atPath: sourceURL) {
            return URL(fileURLWithPath: sourceURL)
        }
        return URL(string: sourceURL)
    }

    static func formattedDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
