import Foundation
import ActivityKit
import AppIntents

/// Shared by the app and the widget extension (Dynamic Island / Lock Screen).
struct MediaGridActivity: ActivityAttributes {
    /// Transfer progress (music / media sync, photo backup). Music playback uses the system Now Playing UI instead.
    struct ContentState: Codable, Hashable {
        var label: String = ""
        var done: Int = 0
        var total: Int = 0
        var finished: Bool = false
        var accent: [Double] = [0.10, 0.45, 0.91]   // r, g, b of the app accent colour
    }
    var pcName: String
}

/// Lets intents run in the app process without the widget target knowing about Player.
enum IntentBridge {
    nonisolated(unsafe) static var handler: (@Sendable (String) async -> Void)?
}

struct PlayPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play / Pause"
    func perform() async throws -> some IntentResult {
        await IntentBridge.handler?("toggle")
        return .result()
    }
}

struct NextTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next Song"
    func perform() async throws -> some IntentResult {
        await IntentBridge.handler?("next")
        return .result()
    }
}

struct PreviousTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous Song"
    func perform() async throws -> some IntentResult {
        await IntentBridge.handler?("prev")
        return .result()
    }
}
