enum WiroFailureCode: Sendable, Equatable, Hashable {
    case authentication
    case apiRejected
    case rateLimited
    case serverUnavailable
    case networkUnavailable
    case requestTimeout
    case cancelled
    case malformedResponse
    case socketConnection
    case socketConnectTimeout
    case realtimeProtocol
    case streamReadyTimeout
    case sessionBusy
}

struct WiroFailure: Error, Equatable, Sendable, CustomStringConvertible {
    let code: WiroFailureCode
    let message: String
    let diagnostics: [String: String]

    var description: String { message }

    init(
        code: WiroFailureCode,
        message: String,
        diagnostics: [String: String] = [:],
    ) {
        self.code = code
        self.message = message
        self.diagnostics = diagnostics
    }

    static let authentication = WiroFailure(
        code: .authentication,
        message: "Wiro authentication failed. "
            + "Check the project credentials.",
    )

    static let apiRejected = WiroFailure(
        code: .apiRejected,
        message: "Wiro rejected the model Run request.",
    )

    static let rateLimited = WiroFailure(
        code: .rateLimited,
        message: "Wiro request limit reached. Try again later.",
    )

    static let serverUnavailable = WiroFailure(
        code: .serverUnavailable,
        message: "Wiro is temporarily unavailable. Try again later.",
    )

    static let networkUnavailable = WiroFailure(
        code: .networkUnavailable,
        message: "Could not reach Wiro. Check the network connection.",
    )

    static let requestTimeout = WiroFailure(
        code: .requestTimeout,
        message: "The Wiro request timed out. Try again.",
    )

    static let cancelled = WiroFailure(
        code: .cancelled,
        message: "The Wiro request was cancelled.",
    )

    static let malformedResponse = WiroFailure(
        code: .malformedResponse,
        message: "Wiro returned an unexpected response.",
    )

    static let socketConnection = WiroFailure(
        code: .socketConnection,
        message: "The Wiro realtime connection failed.",
    )

    static let socketConnectTimeout = WiroFailure(
        code: .socketConnectTimeout,
        message: "The Wiro realtime connection timed out. Try again.",
    )

    static let realtimeProtocol = WiroFailure(
        code: .realtimeProtocol,
        message: "Wiro returned an unexpected realtime event.",
    )

    static let streamReadyTimeout = WiroFailure(
        code: .streamReadyTimeout,
        message: "The Wiro realtime stream did not become ready in time.",
    )

    static let sessionBusy = WiroFailure(
        code: .sessionBusy,
        message: "Another realtime session is already active.",
    )
}
