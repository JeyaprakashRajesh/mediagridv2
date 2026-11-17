import Foundation
import ActivityKit
import AppIntents

/// Shared by the app and the widget extension (Dynamic Island / Lock Screen).
struct MediaGridActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var mode: String = "music"      // "music" | "sync"
        var title: String = ""
        var subtitle: String = ""
        var playing: Bool = false
        var start: Date = .now          // track start (for live progress)
        var end: Date = .now            // track end
        var progress: Double = 0        // used while paused
        var syncDone: Int = 0
        var syncTotal: Int = 0
        var syncLabel: String = ""
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
