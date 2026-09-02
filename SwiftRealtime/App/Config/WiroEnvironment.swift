import Foundation

enum WiroEnvironment {
    static let apiKeyName = "WIRO_API_KEY"
    static let apiSecretName = "WIRO_API_SECRET"

    struct MissingAPIKey: Error, CustomStringConvertible, Sendable {
        var description: String {
            "Missing required \(WiroEnvironment.apiKeyName). "
                + "Copy Configs/Secrets.xcconfig.example to "
                + "Configs/Secrets.xcconfig and set the key, or pass "
                + "\(WiroEnvironment.apiKeyName) in the scheme "
                + "environment."
        }
    }

    static func fromLaunchEnvironment(
        environment: [String: String] = ProcessInfo.processInfo
            .environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
    ) throws -> WiroCredentials {
        try fromValues(
            apiKey: resolvedValue(
                named: apiKeyName,
                environment: environment,
                infoDictionary: infoDictionary,
            ),
            apiSecret: resolvedValue(
                named: apiSecretName,
                environment: environment,
                infoDictionary: infoDictionary,
            ),
        )
    }

    static func fromValues(
        apiKey: String,
        apiSecret: String? = nil,
    ) throws -> WiroCredentials {
        let normalizedAPIKey = normalized(apiKey)
        guard !normalizedAPIKey.isEmpty else {
            throw MissingAPIKey()
        }

        let normalizedAPISecret = normalized(apiSecret ?? "")
        return WiroCredentials(
            apiKey: normalizedAPIKey,
            apiSecret: normalizedAPISecret.isEmpty
                ? nil
                : normalizedAPISecret,
        )
    }

    private static func resolvedValue(
        named name: String,
        environment: [String: String],
        infoDictionary: [String: Any]?,
    ) -> String {
        let envValue = normalized(environment[name] ?? "")
        if !envValue.isEmpty {
            return envValue
        }

        let plistValue = infoDictionary?[name] as? String ?? ""
        return normalized(plistValue)
    }

    private static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines,
        )
        if isUnresolvedBuildSetting(trimmed) {
            return ""
        }
        return trimmed
    }

    private static func isUnresolvedBuildSetting(
        _ value: String,
    ) -> Bool {
        value.hasPrefix("$(") && value.hasSuffix(")")
    }
}
