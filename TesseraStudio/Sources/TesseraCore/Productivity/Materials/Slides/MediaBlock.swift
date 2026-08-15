import Foundation

// MARK: - MediaKind

/// Which AVFoundation asset class a `.media` block renders. AVPlayer
/// plays both the same way; the kind only picks the player chrome
/// (waveform vs video frame) - see ``MediaBlock``'s header for why no
/// AVFoundation type appears in this file at all.
public enum MediaKind: String, Codable, Sendable, Hashable, CaseIterable {
    case audio
    case video
}

// MARK: - MediaBlock

/// An audio/video object on an Impress canvas (studio-expansion-plan.md
/// 1.4). Deliberately NOT a wrapper around any AVFoundation type -
/// AVAsset/AVPlayerItem aren't simply Codable/Sendable, and this is a
/// plain data-model description of a media reference for `Block.media`/
/// `attributes["media"]` to persist. The actual AVFoundation playback
/// session is a view-layer concern built from this spec at render time,
/// never stored alongside it.
public struct MediaBlock: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var kind: MediaKind
    /// Where the asset lives, as a string path/URL - matches `.image`'s
    /// `attributes["source"]` convention (`Block.swift`'s `.image` case,
    /// `SlideStore`, `LOBridgeDeckIO`) rather than a `URL` field: no
    /// persisted model type in this codebase stores `URL` directly:
    /// `URL` construction from a stored string is a call-site concern.
    public var sourceURL: String
    /// Playback length, when known ahead of decode (e.g. carried over
    /// from an ODP/PPTX import). `nil` means "ask AVFoundation" - never
    /// derived or guessed here.
    public var durationSeconds: Double?
    /// Still-frame thumbnail for `.video`, same string-path convention
    /// as `sourceURL`. Meaningless for `.audio`; left `nil` there.
    public var posterImageURL: String?
    public var autoplay: Bool
    public var loop: Bool

    public init(
        id: UUID = UUID(),
        kind: MediaKind,
        sourceURL: String,
        durationSeconds: Double? = nil,
        posterImageURL: String? = nil,
        autoplay: Bool = false,
        loop: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.sourceURL = sourceURL
        self.durationSeconds = durationSeconds
        self.posterImageURL = posterImageURL
        self.autoplay = autoplay
        self.loop = loop
    }
}
