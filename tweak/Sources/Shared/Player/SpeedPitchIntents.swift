// Speed and pitch presets for Siri and Shortcuts: "Set Spotify preset to Nightcore", or the Set Speed
// and Pitch Preset action in a shortcut of one's own. The phrases are Shared/Siri/SiriIntents.swift's,
// with the app's other Siri actions. The presets are the user's (SpeedPitchPresets.m
// stores them), read here from the mod's settings; setting one is handed back to the Objective-C side by
// name.
//
// The intents run inside Spotify, whose App Intents metadata has to name them: scripts/build-extension.sh
// extracts it from this file under the tweak's module and scripts/merge-appintents.py adds it to
// Spotify's own. So this file is typechecked on its own there, and reaches SpeedPitchPresets.m through
// dlsym rather than a declaration it could not see.
import AppIntents
import Foundation

private let SGSpeedPitchPresetsKey = "spotifyglass.speedPitchPresets"

@available(iOS 16.0, *)
struct SGSpeedPitchPresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Speed and Pitch Preset"
    static let defaultQuery = SGSpeedPitchPresetQuery()

    // The name, which is what the user saves it under and what Siri hears.
    var id: String
    var speed: Double
    var pitch: Double

    var displayRepresentation: DisplayRepresentation {
        let pitchText = pitch == 0 ? "0 st" : String(format: "%@%.0f st", pitch > 0 ? "+" : "−", abs(pitch))
        return DisplayRepresentation(title: "\(id)", subtitle: "\(String(format: "%.2f×", speed))  \(pitchText)")
    }

    static func all() -> [SGSpeedPitchPresetEntity] {
        let stored = UserDefaults.standard.array(forKey: SGSpeedPitchPresetsKey) as? [[String: Any]] ?? []
        return stored.compactMap { entry in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            let speed = (entry["speed"] as? NSNumber)?.doubleValue ?? 1
            let pitch = (entry["pitch"] as? NSNumber)?.doubleValue ?? 0
            return SGSpeedPitchPresetEntity(id: name, speed: speed, pitch: pitch)
        }
    }
}

@available(iOS 16.0, *)
struct SGSpeedPitchPresetQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SGSpeedPitchPresetEntity] {
        let all = SGSpeedPitchPresetEntity.all()
        return identifiers.compactMap { id in all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }
    }

    // What Siri heard, matched loosely: "nightcore" finds Nightcore, "slowed" finds Slowed first.
    func entities(matching string: String) async throws -> [SGSpeedPitchPresetEntity] {
        let all = SGSpeedPitchPresetEntity.all()
        let exact = all.filter { $0.id.caseInsensitiveCompare(string) == .orderedSame }
        return exact.isEmpty ? all.filter { $0.id.localizedCaseInsensitiveContains(string) } : exact
    }

    func suggestedEntities() async throws -> [SGSpeedPitchPresetEntity] {
        SGSpeedPitchPresetEntity.all()
    }
}

// SpeedPitchPresets.m's SGSpeedPitchApplyPresetNamed and SGSpeedPitchResetFromIntent, found at run time.
private enum SGSpeedPitchApply {
    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        // RTLD_DEFAULT, which Swift does not import.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    static func preset(named name: String) -> Bool {
        guard let found = symbol("SGSpeedPitchApplyPresetNamed") else { return false }
        let apply = unsafeBitCast(found, to: (@convention(c) (UnsafePointer<CChar>) -> Bool).self)
        return name.withCString { apply($0) }
    }

    static func reset() -> Bool {
        guard let found = symbol("SGSpeedPitchResetFromIntent") else { return false }
        return unsafeBitCast(found, to: (@convention(c) () -> Bool).self)()
    }
}

@available(iOS 16.0, *)
struct SGSetSpeedPitchPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Speed and Pitch Preset"
    static let description = IntentDescription("Plays Spotify at the speed and pitch of one of your presets.")
    static let openAppWhenRun = false

    @Parameter(title: "Preset")
    var preset: SGSpeedPitchPresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set speed and pitch to \(\.$preset)")
    }

    init() {}

    init(preset: SGSpeedPitchPresetEntity) {
        self.preset = preset
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = preset.id
        let applied = await MainActor.run { SGSpeedPitchApply.preset(named: name) }
        if !applied {
            return .result(dialog: "Spotify couldn't change its speed or pitch right now. Play something first, then try again.")
        }
        return .result(dialog: "\(name) is on.")
    }
}

// Back to 1× and the original pitch, whether or not a preset by that name is still there.
@available(iOS 16.0, *)
struct SGResetSpeedPitchIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Speed and Pitch"
    static let description = IntentDescription("Plays Spotify at normal speed and its original pitch.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let applied = await MainActor.run { SGSpeedPitchApply.reset() }
        if !applied {
            return .result(dialog: "Spotify couldn't change its speed or pitch right now.")
        }
        return .result(dialog: "Speed and pitch are back to normal.")
    }
}
