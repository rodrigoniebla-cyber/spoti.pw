// Siri and Shortcuts actions on Spotify itself: play the DJ, like or unlike the song playing, and
// download or remove the download of the playlist or album playing. Each is carried out by SiriActions.x
// inside Spotify, reached by name through dlsym: this file is also typechecked on its own for the App
// Intents metadata (scripts/build-extension.sh), where the Objective-C side cannot be seen.
//
// The phrases Siri knows them by are at the end, with the speed and pitch presets' (Shared/Player/
// SpeedPitchIntents.swift), since an app has one App Shortcuts provider, and at most ten shortcuts in it.
import AppIntents
import Foundation

// What SiriActions.x's SGSiriRun answers, and what Siri says for it.
enum SGSiriOutcome: Int32 {
    case done = 0
    case nothingPlaying = 1
    case notACollection = 2
    case unavailable = 3
    case already = 4
    case notLoaded = 5
}

enum SGSiriAction {
    static func run(_ action: String) async -> SGSiriOutcome {
        await MainActor.run {
            // RTLD_DEFAULT, which Swift does not import.
            guard let found = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SGSiriRun") else { return .unavailable }
            let call = unsafeBitCast(found, to: (@convention(c) (UnsafePointer<CChar>) -> Int32).self)
            return SGSiriOutcome(rawValue: action.withCString { call($0) }) ?? .unavailable
        }
    }
}

@available(iOS 16.0, *)
struct SGPlayDJIntent: AppIntent {
    static let title: LocalizedStringResource = "Play DJ"
    static let description = IntentDescription("Starts Spotify's DJ, the AI host that picks and talks through your music.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SGSiriAction.run("dj") {
        case .done: return .result(dialog: "Starting your DJ.")
        case .notLoaded: return .result(dialog: "Spotify is still starting up. Try again in a moment.")
        default: return .result(dialog: "Spotify couldn't start the DJ.")
        }
    }
}

@available(iOS 16.0, *)
struct SGLikeSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Song to Liked Songs"
    static let description = IntentDescription("Adds the song playing in Spotify to your Liked Songs.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SGSiriAction.run("like") {
        case .done: return .result(dialog: "Added to your Liked Songs.")
        case .already: return .result(dialog: "It's already in your Liked Songs.")
        case .nothingPlaying: return .result(dialog: "Nothing is playing in Spotify.")
        default: return .result(dialog: "Spotify couldn't add it to your Liked Songs.")
        }
    }
}

@available(iOS 16.0, *)
struct SGUnlikeSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Song from Liked Songs"
    static let description = IntentDescription("Removes the song playing in Spotify from your Liked Songs.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SGSiriAction.run("unlike") {
        case .done: return .result(dialog: "Removed from your Liked Songs.")
        case .already: return .result(dialog: "It isn't in your Liked Songs.")
        case .nothingPlaying: return .result(dialog: "Nothing is playing in Spotify.")
        default: return .result(dialog: "Spotify couldn't remove it from your Liked Songs.")
        }
    }
}

@available(iOS 16.0, *)
struct SGDownloadPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Download Playlist"
    static let description = IntentDescription("Downloads the playlist or album playing in Spotify, so it plays offline.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SGSiriAction.run("download") {
        case .done: return .result(dialog: "Downloading it.")
        case .already: return .result(dialog: "It's already downloaded.")
        case .nothingPlaying: return .result(dialog: "Nothing is playing in Spotify.")
        case .notACollection: return .result(dialog: "What's playing isn't a playlist or album that can be downloaded.")
        default: return .result(dialog: "Spotify couldn't download it.")
        }
    }
}

@available(iOS 16.0, *)
struct SGRemoveDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Playlist Download"
    static let description = IntentDescription("Removes the download of the playlist or album playing in Spotify.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await SGSiriAction.run("undownload") {
        case .done: return .result(dialog: "Removed the download.")
        case .already: return .result(dialog: "It isn't downloaded.")
        case .nothingPlaying: return .result(dialog: "Nothing is playing in Spotify.")
        case .notACollection: return .result(dialog: "What's playing isn't a playlist or album with a download.")
        default: return .result(dialog: "Spotify couldn't remove the download.")
        }
    }
}

// The phrases Siri knows without a shortcut being made. Spotify declares none of its own, and an app has
// only one provider, so this one is it. Seven of the ten an app may have.
@available(iOS 17.0, *)
struct SGAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SGSetSpeedPitchPresetIntent(), phrases: [
            "Set \(.applicationName) preset to \(\.$preset)",
            "Set \(.applicationName) to \(\.$preset)",
            "Use \(\.$preset) in \(.applicationName)",
            "\(\.$preset) in \(.applicationName)",
            "Change \(.applicationName) speed and pitch",
        ], shortTitle: "Speed and Pitch Preset", systemImageName: "slider.horizontal.3")
        AppShortcut(intent: SGResetSpeedPitchIntent(), phrases: [
            "Reset \(.applicationName) speed and pitch",
            "Reset speed and pitch in \(.applicationName)",
            "Set \(.applicationName) back to normal speed",
        ], shortTitle: "Reset Speed and Pitch", systemImageName: "arrow.counterclockwise")
        AppShortcut(intent: SGPlayDJIntent(), phrases: [
            "Play \(.applicationName) DJ",
            "Play my \(.applicationName) DJ",
            "Start the DJ in \(.applicationName)",
            "Play DJ in \(.applicationName)",
        ], shortTitle: "Play DJ", systemImageName: "waveform")
        AppShortcut(intent: SGLikeSongIntent(), phrases: [
            "Like this song in \(.applicationName)",
            "Add this song to my \(.applicationName) liked songs",
            "Save this song in \(.applicationName)",
            "Add this to my liked songs in \(.applicationName)",
        ], shortTitle: "Add to Liked Songs", systemImageName: "heart")
        AppShortcut(intent: SGUnlikeSongIntent(), phrases: [
            "Unlike this song in \(.applicationName)",
            "Remove this song from my \(.applicationName) liked songs",
            "Remove this from my liked songs in \(.applicationName)",
        ], shortTitle: "Remove from Liked Songs", systemImageName: "heart.slash")
        AppShortcut(intent: SGDownloadPlaylistIntent(), phrases: [
            "Download this playlist in \(.applicationName)",
            "Download this album in \(.applicationName)",
            "Download this in \(.applicationName)",
        ], shortTitle: "Download Playlist", systemImageName: "arrow.down.circle")
        AppShortcut(intent: SGRemoveDownloadIntent(), phrases: [
            "Remove this playlist's download in \(.applicationName)",
            "Undownload this playlist in \(.applicationName)",
            "Remove this download in \(.applicationName)",
        ], shortTitle: "Remove Download", systemImageName: "xmark.circle")
    }
}

// For SpeedPitchPresets.m: Siri learns the presets' names again whenever the list changes.
@available(iOS 17.0, *)
@objc(SGSpeedPitchShortcutsBridge)
public final class SGSpeedPitchShortcutsBridge: NSObject {
    @objc public static func presetsChanged() {
        SGAppShortcuts.updateAppShortcutParameters()
    }
}
