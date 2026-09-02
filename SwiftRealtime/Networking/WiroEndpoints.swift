/// Official Wiro HTTP and WebSocket bases verified 2026-08-21.
enum WiroEndpoints {
    static let restBaseURL = "https://api.wiro.ai/v1"
    static let webSocketURL = "wss://socket.wiro.ai/v1"
    static let taskCancelPath = "/Task/Cancel"
    static let taskKillPath = "/Task/Kill"

    static func runPath(
        owner: String,
        model: String,
    ) -> String {
        "/Run/\(owner)/\(model)"
    }
}
