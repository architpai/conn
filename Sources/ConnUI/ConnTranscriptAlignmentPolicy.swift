import ConnDomain

public enum ConnTranscriptLane: Equatable, Sendable {
    case leading
    case trailing
}

public enum ConnTranscriptAlignmentPolicy {
    public static func lane(for kind: ConnActivityKind) -> ConnTranscriptLane {
        kind == .userMessage ? .trailing : .leading
    }
}
