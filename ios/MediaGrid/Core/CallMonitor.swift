import CallKit
import UIKit

/// Tells the PC when this iPhone rings / is in a call, so Windows can float a call bubble.
/// iOS does not reveal who is calling, so only the call state is shared.
@MainActor
final class CallMonitor: NSObject, CXCallObserverDelegate {
    static let shared = CallMonitor()
    private let observer = CXCallObserver()
    private var last: [UUID: String] = [:]

    func start() { observer.setDelegate(self, queue: .main) }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        MainActor.assumeIsolated { handle(call) }
    }

    private func handle(_ call: CXCall) {
        let state = call.hasEnded ? "ended" : call.hasConnected ? "active" : call.isOutgoing ? "dialing" : "ringing"
        guard last[call.uuid] != state else { return }
        last[call.uuid] = state
        let body: [String: Any] = ["state": state, "direction": call.isOutgoing ? "outgoing" : "incoming"]
        let bg = UIApplication.shared.beginBackgroundTask(withName: "call-state")
        Task {
            try? await Connection.shared.post("/api/call", json: body)
            UIApplication.shared.endBackgroundTask(bg)
        }
    }
}
