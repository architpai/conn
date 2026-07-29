import ConnDomain

public enum ConnTranscriptLane: Equatable, Sendable {
    case leading
    case trailing
}

public enum ConnTranscriptAlignmentPolicy {
    public static func lane(for kind: ConnActivityKind) -> ConnTranscriptLane {
        kind == .userMessage ? .trailing : .leading
    }

    /// Bubble placement communicates speaker direction; paragraph alignment
    /// remains leading so multiline messages retain a stable reading edge.
    public static func contentLane(
        for kind: ConnActivityKind
    ) -> ConnTranscriptLane {
        .leading
    }
}

public enum ConnTranscriptStyle: Equatable, Sendable {
    case incomingBubble
    case outgoingBubble
    case activityCard
}

public enum ConnTranscriptPresentationPolicy {
    public static func style(for kind: ConnActivityKind) -> ConnTranscriptStyle {
        switch kind {
        case .userMessage: .outgoingBubble
        case .agentMessage: .incomingBubble
        case .plan, .reasoning, .command, .fileChange, .toolCall, .subagent,
             .webSearch, .image, .compaction, .unknown:
            .activityCard
        }
    }
}
