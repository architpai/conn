import Foundation
import ConnAppServerAdapter
import ConnDomain

public enum AppServerControlPrecondition: Equatable, Sendable {
    case idle
    case activeTurn(AppServerTurnID)
    case serverRequest(AppServerScopedRequestID, turnID: AppServerTurnID?)
}

/// Immutable authority captured at the user's click. Runtime generation and
/// selection generation prevent a replacement session or selection from
/// inheriting an earlier action, while the upstream IDs prevent retargeting.
public struct AppServerControlCommitIdentity: Equatable, Sendable {
    public let domain: AppServerDomainCommitIdentity
    public let runtimeGeneration: UUID
    public let selectionGeneration: UInt64
    public let threadID: AppServerThreadID
    public let precondition: AppServerControlPrecondition

    public init(
        domain: AppServerDomainCommitIdentity,
        runtimeGeneration: UUID,
        selectionGeneration: UInt64,
        threadID: AppServerThreadID,
        precondition: AppServerControlPrecondition
    ) {
        self.domain = domain
        self.runtimeGeneration = runtimeGeneration
        self.selectionGeneration = selectionGeneration
        self.threadID = threadID
        self.precondition = precondition
    }
}

/// Runtime-only structured answers. In particular, secret values are never
/// Codable and must not be copied into action outcomes, notices, or traces.
public struct AppServerQuestionAnswers: Equatable, Sendable {
    public let valuesByQuestionID: [String: [String]]

    public init(valuesByQuestionID: [String: [String]]) {
        self.valuesByQuestionID = valuesByQuestionID
    }
}

/// Runtime-only composer state. It intentionally has no Codable conformance so
/// typed draft text cannot enter projection or checkpoint persistence.
public struct AppServerControlDraft: Equatable, Sendable {
    public private(set) var text: String
    public private(set) var revision: UInt64

    public init(text: String = "", revision: UInt64 = 0) {
        self.text = text
        self.revision = revision
    }

    public mutating func update(_ text: String) {
        self.text = text
        revision &+= 1
    }

    /// Clears only the exact revision acknowledged by App Server. All failure,
    /// timeout, stale, and superseded-edit paths preserve the user's text.
    public mutating func apply(_ result: AppServerControlExecutionResult) {
        guard result.outcome == .accepted,
              result.draftRevision == revision else { return }
        text = ""
        revision &+= 1
    }
}

/// Runtime-only New Chat fields. Working directory and prompt never enter a
/// checkpoint, trace, notice, or result. Both clear only after the exact
/// thread/start + first turn/start transaction is acknowledged.
public struct AppServerNewThreadDraft: Equatable, Sendable {
    public private(set) var workingDirectory: String
    public private(set) var initialPrompt: String
    public private(set) var selectedModelID: String?
    public private(set) var revision: UInt64

    public init(
        workingDirectory: String = "",
        initialPrompt: String = "",
        selectedModelID: String? = nil,
        revision: UInt64 = 0
    ) {
        self.workingDirectory = workingDirectory
        self.initialPrompt = initialPrompt
        self.selectedModelID = selectedModelID
        self.revision = revision
    }

    public mutating func updateWorkingDirectory(_ value: String) {
        workingDirectory = value
        revision &+= 1
    }

    public mutating func updateInitialPrompt(_ value: String) {
        initialPrompt = value
        revision &+= 1
    }

    public mutating func updateSelectedModelID(_ value: String?) {
        selectedModelID = value
        revision &+= 1
    }

    public mutating func apply(_ result: AppServerNewThreadExecutionResult) {
        guard result.outcome == .accepted, result.draftRevision == revision else { return }
        workingDirectory = ""
        initialPrompt = ""
        selectedModelID = nil
        revision &+= 1
    }
}

/// Runtime-only picker row returned by the current managed App Server. Conn may
/// remember only the user's selected bounded ID; catalog metadata stays out of
/// checkpoints and preferences and is revalidated against each live catalog.
public struct AppServerNewThreadModelOption: Equatable, Identifiable, Sendable {
    public let id: String
    public let model: String
    public let displayName: String
    public let detail: String
    public let isDefault: Bool

    public init(
        id: String,
        model: String,
        displayName: String,
        detail: String,
        isDefault: Bool
    ) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.detail = detail
        self.isDefault = isDefault
    }
}

public struct AppServerNewThreadModelCatalog: Equatable, Sendable {
    public let connection: AppServerConnectionIdentity
    public let options: [AppServerNewThreadModelOption]

    public init(
        connection: AppServerConnectionIdentity,
        options: [AppServerNewThreadModelOption]
    ) {
        self.connection = connection
        self.options = options
    }

    public var defaultOptionID: String? {
        options.first(where: \.isDefault)?.id ?? options.first?.id
    }
}

/// Runtime-only model authority returned by `thread/resume`. This deliberately
/// stays outside the persisted thread projection: it describes the live App
/// Server session that Conn is currently attached to.
public struct AppServerThreadModelSelection: Equatable, Sendable {
    public let model: String
    public let reasoningEffort: String?

    public init(model: String, reasoningEffort: String?) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public enum AppServerThreadModelLabelPolicy {
    public static func label(
        selection: AppServerThreadModelSelection?,
        options: [AppServerNewThreadModelOption]
    ) -> String {
        guard let selection else { return "Loading model…" }
        let modelName = options.first(where: { $0.model == selection.model })?.displayName
            ?? selection.model
        guard let effort = selection.reasoningEffort else { return modelName }
        return "\(modelName) · \(reasoningLabel(effort))"
    }

    private static func reasoningLabel(_ rawValue: String) -> String {
        let label = switch rawValue.lowercased() {
        case "xhigh": "Extra high"
        case "xlow": "Extra low"
        default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "\(label) reasoning"
    }
}

public enum AppServerThreadModelQualificationPolicy {
    public static func shouldRequestForExpandedPresentation(
        selectedThreadID: AppServerThreadID?,
        knownSelections: [AppServerThreadID: AppServerThreadModelSelection]
    ) -> Bool {
        guard let selectedThreadID else { return false }
        return knownSelections[selectedThreadID] == nil
    }
}

/// Resolves the required New Chat selection without silently replacing a
/// still-available in-progress choice. A remembered explicit choice wins over
/// the server default when a fresh catalog is loaded.
public enum AppServerNewThreadModelSelectionPolicy {
    public struct Resolution: Equatable, Sendable {
        public let selectedID: String?
        public let preferredModelIsUnavailable: Bool

        public init(selectedID: String?, preferredModelIsUnavailable: Bool) {
            self.selectedID = selectedID
            self.preferredModelIsUnavailable = preferredModelIsUnavailable
        }
    }

    public static func resolve(
        options: [AppServerNewThreadModelOption],
        currentSelectionID: String?,
        preferredSelectionID: String?
    ) -> Resolution {
        let availableIDs = Set(options.map(\.id))
        if let currentSelectionID, availableIDs.contains(currentSelectionID) {
            return .init(selectedID: currentSelectionID, preferredModelIsUnavailable: false)
        }
        if let preferredSelectionID, availableIDs.contains(preferredSelectionID) {
            return .init(selectedID: preferredSelectionID, preferredModelIsUnavailable: false)
        }
        let fallbackID = options.first(where: \.isDefault)?.id ?? options.first?.id
        return .init(
            selectedID: fallbackID,
            preferredModelIsUnavailable: preferredSelectionID != nil
        )
    }
}

public enum AppServerNewChatWorkspacePolicy {
    public static func resolveDefaultWorkspace(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard NSString(string: trimmed).isAbsolutePath else { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}

public enum AppServerNewThreadModelCatalogOutcome: Equatable, Sendable {
    case available
    case connectionInvalidated
    case unavailable
    case invalidResponse
}

public struct AppServerNewThreadModelCatalogResult: Equatable, Sendable {
    public let outcome: AppServerNewThreadModelCatalogOutcome
    public let catalog: AppServerNewThreadModelCatalog?

    public init(
        outcome: AppServerNewThreadModelCatalogOutcome,
        catalog: AppServerNewThreadModelCatalog? = nil
    ) {
        self.outcome = outcome
        self.catalog = catalog
    }
}

public struct AppServerNewThreadIntent: Equatable, Sendable {
    public let workingDirectory: String
    public let initialPrompt: String
    public let modelID: String
    public let model: String
    public let draftRevision: UInt64

    public init(
        workingDirectory: String,
        initialPrompt: String,
        modelID: String,
        model: String,
        draftRevision: UInt64
    ) {
        self.workingDirectory = workingDirectory
        self.initialPrompt = initialPrompt
        self.modelID = modelID
        self.model = model
        self.draftRevision = draftRevision
    }
}

public enum AppServerNewThreadExecutionStage: Equatable, Sendable {
    case threadStart
    case initialTurn
}

public struct AppServerNewThreadExecutionResult: Equatable, Sendable {
    public let outcome: AppServerControlOutcome
    public let stage: AppServerNewThreadExecutionStage
    public let createdThreadID: AppServerThreadID?
    public let acceptedTurnID: AppServerTurnID?
    public let draftRevision: UInt64

    public init(
        outcome: AppServerControlOutcome,
        stage: AppServerNewThreadExecutionStage,
        createdThreadID: AppServerThreadID? = nil,
        acceptedTurnID: AppServerTurnID? = nil,
        draftRevision: UInt64
    ) {
        self.outcome = outcome
        self.stage = stage
        self.createdThreadID = createdThreadID
        self.acceptedTurnID = acceptedTurnID
        self.draftRevision = draftRevision
    }
}

public enum AppServerControlIntent: Equatable, Sendable {
    case followUp(
        threadID: AppServerThreadID,
        text: String,
        model: String? = nil,
        draftRevision: UInt64
    )
    case steer(
        threadID: AppServerThreadID,
        expectedTurnID: AppServerTurnID,
        text: String,
        draftRevision: UInt64
    )
    case decide(
        request: AppServerScopedRequestID,
        threadID: AppServerThreadID,
        turnID: AppServerTurnID?,
        choice: AppServerApprovalChoice
    )
    case answer(
        request: AppServerScopedRequestID,
        threadID: AppServerThreadID,
        turnID: AppServerTurnID?,
        answers: AppServerQuestionAnswers
    )
    case interrupt(
        threadID: AppServerThreadID,
        expectedTurnID: AppServerTurnID
    )
}

public enum AppServerControlOutcome: Equatable, Sendable {
    case accepted
    case resolvedElsewhere
    case stalePrecondition
    case duplicateSuppressed
    case acknowledgementUncertain
    case acknowledgementTimedOut
    case connectionInvalidated
    case rejected
    case terminalStateUnconfirmed
}

public enum AppServerControlResponseEncodingError: Error, Equatable, Sendable {
    case unsupportedRequest
    case unsupportedChoice
    case missingQuestionAnswer(String)
    case unknownQuestionAnswer(String)
    case emptyQuestionAnswer(String)
}

/// Pure stable-schema response encoder. Callers still need capability,
/// ownership, connection-generation, and exact-request gates before sending.
public enum AppServerControlResponseEncoder {
    public static func approvalResult(
        for request: AppServerProjectedRequest,
        choice: AppServerApprovalChoice
    ) throws -> JSONValue {
        switch request.facts {
        case let .commandApproval(facts):
            guard facts.availableChoices.contains(choice) else {
                throw AppServerControlResponseEncodingError.unsupportedChoice
            }
            return .object(["decision": .string(try decisionValue(choice))])

        case let .fileChangeApproval(facts):
            guard facts.availableChoices.contains(choice) else {
                throw AppServerControlResponseEncodingError.unsupportedChoice
            }
            return .object(["decision": .string(try decisionValue(choice))])

        case let .permissionsApproval(facts):
            guard facts.availableChoices.contains(choice) else {
                throw AppServerControlResponseEncodingError.unsupportedChoice
            }
            guard !containsUnknownPermissionKind(facts.requestedPermissions) else {
                throw AppServerControlResponseEncodingError.unsupportedRequest
            }
            switch choice {
            case .approve:
                return permissionResult(
                    profile: facts.requestedPermissions,
                    scope: "turn"
                )
            case .approveForSession:
                return permissionResult(
                    profile: facts.requestedPermissions,
                    scope: "session"
                )
            case .deny, .cancel:
                return .object([
                    "permissions": .object([:]),
                    "scope": .string("turn"),
                ])
            }

        case .structuredQuestions, .unsupported:
            throw AppServerControlResponseEncodingError.unsupportedRequest
        }
    }

    public static func questionResult(
        for request: AppServerProjectedRequest,
        answers: AppServerQuestionAnswers
    ) throws -> JSONValue {
        guard case let .structuredQuestions(facts) = request.facts else {
            throw AppServerControlResponseEncodingError.unsupportedRequest
        }
        let questionIDs = Set(facts.questions.map(\.id))
        for suppliedID in answers.valuesByQuestionID.keys where !questionIDs.contains(suppliedID) {
            throw AppServerControlResponseEncodingError.unknownQuestionAnswer(suppliedID)
        }

        var encoded: [String: JSONValue] = [:]
        for question in facts.questions {
            guard let values = answers.valuesByQuestionID[question.id] else {
                throw AppServerControlResponseEncodingError.missingQuestionAnswer(question.id)
            }
            guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
                throw AppServerControlResponseEncodingError.emptyQuestionAnswer(question.id)
            }
            encoded[question.id] = .object([
                "answers": .array(values.map(JSONValue.string)),
            ])
        }
        return .object(["answers": .object(encoded)])
    }

    private static func decisionValue(
        _ choice: AppServerApprovalChoice
    ) throws -> String {
        switch choice {
        case .approve: "accept"
        case .approveForSession: "acceptForSession"
        case .deny: "decline"
        case .cancel: "cancel"
        }
    }

    private static func permissionResult(
        profile: AppServerRequestedPermissionProfile,
        scope: String
    ) -> JSONValue {
        .object([
            "permissions": permissionProfile(profile),
            "scope": .string(scope),
        ])
    }

    private static func containsUnknownPermissionKind(
        _ profile: AppServerRequestedPermissionProfile
    ) -> Bool {
        (profile.fileSystem?.entries ?? []).contains { entry in
            guard case let .special(special) = entry.path else { return false }
            if case .unknown = special { return true }
            return false
        }
    }

    private static func permissionProfile(
        _ profile: AppServerRequestedPermissionProfile
    ) -> JSONValue {
        var result: [String: JSONValue] = [:]
        if let fileSystem = profile.fileSystem {
            var encoded: [String: JSONValue] = [:]
            if let entries = fileSystem.entries {
                encoded["entries"] = .array(entries.map(permissionEntry))
            }
            if let depth = fileSystem.globScanMaximumDepth {
                encoded["globScanMaxDepth"] = .integer(Int64(depth))
            }
            if let paths = fileSystem.readPaths {
                encoded["read"] = .array(paths.map(JSONValue.string))
            }
            if let paths = fileSystem.writePaths {
                encoded["write"] = .array(paths.map(JSONValue.string))
            }
            result["fileSystem"] = .object(encoded)
        }
        if let network = profile.network {
            var encoded: [String: JSONValue] = [:]
            if let enabled = network.enabled { encoded["enabled"] = .bool(enabled) }
            result["network"] = .object(encoded)
        }
        return .object(result)
    }

    private static func permissionEntry(
        _ entry: AppServerFileSystemPermissionEntry
    ) -> JSONValue {
        .object([
            "access": .string(entry.access.rawValue),
            "path": permissionPath(entry.path),
        ])
    }

    private static func permissionPath(_ path: AppServerFileSystemPath) -> JSONValue {
        switch path {
        case let .path(value):
            .object(["type": .string("path"), "path": .string(value)])
        case let .globPattern(value):
            .object(["type": .string("glob_pattern"), "pattern": .string(value)])
        case let .special(value):
            .object(["type": .string("special"), "value": specialPath(value)])
        }
    }

    private static func specialPath(
        _ path: AppServerFileSystemSpecialPath
    ) -> JSONValue {
        var value: [String: JSONValue]
        switch path {
        case .root: value = ["kind": .string("root")]
        case .minimal: value = ["kind": .string("minimal")]
        case let .projectRoots(subpath):
            value = ["kind": .string("project_roots")]
            if let subpath { value["subpath"] = .string(subpath) }
        case .temporaryDirectory: value = ["kind": .string("tmpdir")]
        case .slashTemporaryDirectory: value = ["kind": .string("slash_tmp")]
        case let .unknown(path, subpath):
            value = ["kind": .string("unknown"), "path": .string(path)]
            if let subpath { value["subpath"] = .string(subpath) }
        }
        return .object(value)
    }
}
