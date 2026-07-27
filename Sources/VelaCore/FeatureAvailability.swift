import VelaDomain

public enum AppFeature: String, CaseIterable, Hashable, Codable, Sendable {
    case provisioning
    case textMessaging
    case groups
    case attachments
    case reactions
    case edits
    case disappearingMessages
    case historyTransfer
    case audioCalls
    case videoCalls
    case groupCalls
    case stories
}

public enum FeatureAvailability: Hashable, Codable, Sendable {
    case available
    case developmentOnly
    case unavailable(reason: String)
}

public struct FeatureMatrix: Hashable, Codable, Sendable {
    public var values: [AppFeature: FeatureAvailability]

    public init(values: [AppFeature: FeatureAvailability]) {
        self.values = values
    }

    public subscript(_ feature: AppFeature) -> FeatureAvailability {
        values[feature] ?? .unavailable(reason: "Not declared")
    }

    public static let localDevelopment = FeatureMatrix(values: [
        .provisioning: .developmentOnly,
        .textMessaging: .developmentOnly,
        .groups: .developmentOnly,
        .attachments: .unavailable(reason: "Transfer worker not connected"),
        .reactions: .developmentOnly,
        .edits: .developmentOnly,
        .disappearingMessages: .developmentOnly,
        .historyTransfer: .unavailable(reason: "Signal link-and-sync bridge pending"),
        .audioCalls: .unavailable(reason: "Native RingRTC bridge pending"),
        .videoCalls: .unavailable(reason: "Native RingRTC bridge pending"),
        .groupCalls: .unavailable(reason: "Native RingRTC bridge pending"),
        .stories: .unavailable(reason: "Story synchronization pending"),
    ])
}
