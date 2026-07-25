import Foundation
import ConnDomain

enum Phase2ConnIntegrationTestCases {
    private static let baseDate = Date(timeIntervalSince1970: 1_840_000_000)
    private static let codexHarness = HarnessID(rawValue: "openai")
    private static let syntheticHarness = HarnessID(rawValue: "synthetic")
    private static let codexIntegration = IntegrationID(rawValue: "builtin-codex")
    private static let syntheticIntegration = IntegrationID(rawValue: "test-monitor")
    private static let sharedUpstreamID = UpstreamSessionID(rawValue: "same-upstream-id")
    private static let codexSessionID = ConnSessionID(
        integrationID: codexIntegration,
        upstreamID: sharedUpstreamID
    )
    private static let syntheticSessionID = ConnSessionID(
        integrationID: syntheticIntegration,
        upstreamID: sharedUpstreamID
    )
    private static let generation = IntegrationConnectionGeneration(
        instanceID: UUID(uuidString: "22000000-0000-4000-8000-000000000001")!,
        ordinal: 2
    )

    static func run(into suite: inout TestSuite) async throws {
        identityIsIntegrationScoped(into: &suite)
        optionalRunsAndUnknownActivitiesStayBounded(into: &suite)
        completeAndPartialInventoriesHaveDifferentAuthority(into: &suite)
        orderingAndGenerationLossFailConservatively(into: &suite)
        malformedNeutralStateIsRejected(into: &suite)
        actionAvailabilityNeedsLocalCapabilityAndAuthority(into: &suite)
        try actionPayloadsRejectLossyBounds(into: &suite)
        try sessionCreationPreservesSelectedModel(into: &suite)
        try checkpointValidationRejectsUnsafeState(into: &suite)
        try await atomicFeedDeliversPostWatermarkUpdateExactlyOnce(into: &suite)
        try await syntheticIntegrationProvesMonitorOnlySeam(into: &suite)
    }

    private static func sessionCreationPreservesSelectedModel(
        into suite: inout TestSuite
    ) throws {
        let selectedModelID = ConnSessionModelID(rawValue: "model-option-1")
        let low = ConnReasoningEffortOption(
            id: .init(rawValue: "low"),
            displayName: "Low"
        )
        let high = ConnReasoningEffortOption(
            id: .init(rawValue: "high"),
            displayName: "High"
        )
        let model = ConnSessionModelOption(
            id: selectedModelID,
            displayName: "Model One",
            isDefault: true,
            reasoningEfforts: [low, high],
            defaultReasoningEffortID: high.id
        )
        suite.check(
            model.reasoningEfforts.map(\.id) == [low.id, high.id],
            "Each model preserves only its own advertised reasoning choices"
        )
        suite.check(
            model.defaultReasoningEffortID == high.id,
            "Each model preserves its advertised default reasoning choice"
        )
        let selection = ConnSessionModelSelection(
            modelID: selectedModelID,
            reasoningEffortID: low.id
        )
        let action = ConnAction.createSession(
            integrationID: codexIntegration,
            workspacePath: try ConnWorkspacePath("/tmp/project"),
            initialPrompt: try ConnActionText("Start here"),
            modelSelection: selection
        )
        if case let .createSession(_, _, _, modelSelection) = action {
            suite.check(
                modelSelection == selection,
                "Session creation preserves the provider-neutral model and reasoning selection"
            )
        } else {
            suite.check(false, "Session creation remains a create action")
        }

        let followUp = ConnAction.followUp(
            sessionID: codexSessionID,
            text: try ConnActionText("Continue"),
            modelSelection: selection
        )
        if case let .followUp(_, _, modelSelection) = followUp {
            suite.check(
                modelSelection == selection,
                "Follow-up preserves the optional provider-neutral model and reasoning override"
            )
        } else {
            suite.check(false, "Follow-up remains a follow-up action")
        }
    }

    private static func identityIsIntegrationScoped(into suite: inout TestSuite) {
        suite.check(
            codexSessionID != syntheticSessionID,
            "identical upstream IDs remain distinct across Integrations"
        )
        let sessions = [
            codexSessionID: session(id: codexSessionID, title: "Codex"),
            syntheticSessionID: session(id: syntheticSessionID, title: "Synthetic"),
        ]
        suite.check(sessions.count == 2, "composite Session identity prevents collisions")
        suite.check(
            Set(sessions.keys.map(\.integrationID)) == [codexIntegration, syntheticIntegration],
            "simultaneous Harness Sessions retain Integration attribution"
        )
    }

    private static func optionalRunsAndUnknownActivitiesStayBounded(
        into suite: inout TestSuite
    ) {
        let bounds = ConnDomainBounds(
            maximumTitleUTF8Bytes: 12,
            maximumSummaryUTF8Bytes: 12,
            maximumSessionsPerIntegration: 4,
            maximumRunsPerSession: 2,
            maximumActivitiesPerSession: 2,
            maximumIssuesPerSession: 2,
            maximumBufferedUpdates: 4
        )
        let activities = (1...3).map { index in
            ConnActivity(
                id: ActivityID(rawValue: "activity-\(index)"),
                runID: nil,
                kind: .unknown,
                status: .unknown,
                summary: index == 3 ? "界界界界界\nRAW-PROVIDER-CANARY" : "activity \(index)",
                observedAt: at(TimeInterval(index)),
                bounds: bounds
            )
        }
        let value = ConnSession(
            id: syntheticSessionID,
            title: "Synthetic monitor title",
            status: .working,
            runs: [],
            activities: activities,
            updatedAt: at(3),
            bounds: bounds
        )

        suite.check(value.runs.isEmpty, "Session-scoped Activities do not synthesize Runs")
        suite.check(
            value.activities.map(\.id) == [
                ActivityID(rawValue: "activity-2"),
                ActivityID(rawValue: "activity-3"),
            ],
            "Activity history keeps the bounded newest suffix"
        )
        suite.check(
            value.activities.last?.summary == "界界界界",
            "unknown Activity summary is UTF-8 bounded and single-line"
        )
        suite.check(
            !String(reflecting: value).contains("RAW-PROVIDER-CANARY"),
            "unknown provider values do not survive as domain discriminators or suffixes"
        )
        let leadingNewline = ConnActivity(
            id: ActivityID(rawValue: "leading-newline"),
            kind: .unknown,
            status: .unknown,
            summary: "\nMUST-NOT-BECOME-FIRST-LINE",
            observedAt: at(4),
            bounds: bounds
        )
        suite.check(
            leadingNewline.summary == "",
            "single-line bounding preserves an intentionally empty first line"
        )
    }

    private static func completeAndPartialInventoriesHaveDifferentAuthority(
        into suite: inout TestSuite
    ) {
        let secondID = ConnSessionID(
            integrationID: codexIntegration,
            upstreamID: UpstreamSessionID(rawValue: "second")
        )
        var projection = IntegrationProjection()
        suite.check(
            projection.qualify(with: snapshot(
                authority: .complete,
                sessions: [
                    session(id: codexSessionID, title: "First"),
                    session(id: secondID, title: "Second"),
                ],
                throughSequence: 1
            )) == .qualified,
            "complete inventory qualifies"
        )
        suite.check(projection.sessions.count == 2, "complete inventory installs membership")

        suite.check(
            projection.qualify(with: snapshot(
                authority: .partial,
                sessions: [session(id: codexSessionID, title: "Updated")],
                throughSequence: 2
            )) == .qualified,
            "partial inventory requalifies without claiming completeness"
        )
        suite.check(
            projection.sessionsByID[secondID] != nil,
            "partial inventory cannot remove an omitted Session"
        )
        suite.check(
            !projection.hasCurrentAuthority(for: secondID),
            "an omitted Session retained by partial inventory is not actionable"
        )
        suite.check(
            projection.sessionsByID[codexSessionID]?.title == "Updated",
            "partial inventory may refresh an observed Session"
        )

        _ = projection.qualify(with: snapshot(
            authority: .complete,
            sessions: [session(id: codexSessionID, title: "Final")],
            throughSequence: 3
        ))
        suite.check(
            projection.sessionsByID[secondID] == nil,
            "complete inventory authoritatively removes an omitted Session"
        )
    }

    private static func orderingAndGenerationLossFailConservatively(
        into suite: inout TestSuite
    ) {
        var projection = IntegrationProjection()
        _ = projection.qualify(with: snapshot(
            authority: .complete,
            sessions: [session(id: codexSessionID)],
            throughSequence: 10
        ))
        let next = update(
            sequence: 11,
            .activityUpsert(
                sessionID: codexSessionID,
                activity: ConnActivity(
                    id: ActivityID(rawValue: "next"),
                    kind: .plan,
                    status: .started,
                    summary: "Plan",
                    observedAt: at(11)
                )
            )
        )
        suite.check(projection.apply(next) == .applied, "next ordered update applies")
        suite.check(
            projection.apply(next) == .ignoredDuplicate,
            "an update at or below the watermark is idempotently ignored"
        )

        let oldGeneration = IntegrationConnectionGeneration(
            instanceID: UUID(uuidString: "22000000-0000-4000-8000-000000000002")!,
            ordinal: 1
        )
        suite.check(
            projection.apply(IntegrationUpdate(
                integrationID: codexIntegration,
                cursor: .init(generation: oldGeneration, sequence: 12),
                observedAt: at(12),
                update: .authorityLost
            )) == .ignoredStaleGeneration,
            "an update from another connection generation has no authority"
        )
        suite.check(projection.freshness == .live, "stale generation cannot degrade live state")

        suite.check(
            projection.apply(update(sequence: 13, .authorityLost))
                == .sequenceGap(expected: 12, received: 13),
            "a forward sequence gap is detected"
        )
        suite.check(projection.freshness == .stale, "a forward gap fails the Integration stale")
        suite.check(
            projection.capabilities.actions.isEmpty && !projection.capabilities.canMonitor,
            "authority loss removes runtime capability proof"
        )
        suite.check(
            projection.apply(update(sequence: 12, .authorityLost)) == .requiresRequalification,
            "a stale projection cannot resume by accepting later updates"
        )

        var missingEntityProjection = IntegrationProjection()
        _ = missingEntityProjection.qualify(with: snapshot(
            authority: .complete,
            sessions: [session(id: codexSessionID)],
            throughSequence: 20
        ))
        suite.check(
            missingEntityProjection.apply(update(
                sequence: 21,
                .attentionRemoved(
                    sessionID: codexSessionID,
                    requestID: AttentionRequestID(rawValue: "already-gone")
                )
            )) == .ignoredMissingEntity,
            "missing Attention removal is a consumed semantic no-op"
        )
        suite.check(
            missingEntityProjection.throughSequence == 21,
            "consumed no-op advances the ordered watermark"
        )
        suite.check(
            missingEntityProjection.apply(update(
                sequence: 22,
                .inventoryAuthorityChanged(.partial)
            )) == .applied,
            "the update after a consumed no-op does not create a false sequence gap"
        )
    }

    private static func malformedNeutralStateIsRejected(into suite: inout TestSuite) {
        var projection = IntegrationProjection()
        let duplicate = session(id: codexSessionID)
        suite.check(
            projection.qualify(with: snapshot(
                authority: .complete,
                sessions: [duplicate, duplicate],
                throughSequence: 1
            )) == .rejected(.duplicateIdentity),
            "duplicate Session identities are rejected before dictionary construction"
        )

        let missingRunActivity = ConnActivity(
            id: ActivityID(rawValue: "orphaned-run-activity"),
            runID: RunID(rawValue: "missing-run"),
            kind: .command,
            status: .started,
            summary: "Unsafe",
            observedAt: at(2)
        )
        let invalidRunSession = ConnSession(
            id: codexSessionID,
            status: .working,
            runs: [],
            activities: [missingRunActivity],
            updatedAt: at(2)
        )
        suite.check(
            projection.qualify(with: snapshot(
                authority: .complete,
                sessions: [invalidRunSession],
                throughSequence: 1
            )) == .rejected(.invalidRunReference),
            "Run attribution requires a Run established by evidence"
        )

        let wrongScope = session(id: syntheticSessionID)
        suite.check(
            projection.qualify(with: snapshot(
                authority: .complete,
                sessions: [wrongScope],
                throughSequence: 1
            )) == .rejected(.wrongIntegrationScope),
            "a Session cannot cross its Integration scope"
        )

        let oneSessionBounds = ConnDomainBounds(maximumSessionsPerIntegration: 1)
        let secondID = ConnSessionID(
            integrationID: codexIntegration,
            upstreamID: UpstreamSessionID(rawValue: "over-bound")
        )
        suite.check(
            projection.qualify(
                with: snapshot(
                    authority: .complete,
                    sessions: [
                        session(id: codexSessionID),
                        session(id: secondID),
                    ],
                    throughSequence: 1
                ),
                bounds: oneSessionBounds
            ) == .rejected(.boundsExceeded),
            "complete inventory is rejected rather than silently truncated"
        )

        var boundedProjection = IntegrationProjection()
        _ = boundedProjection.qualify(
            with: snapshot(
                authority: .complete,
                sessions: [session(id: codexSessionID)],
                throughSequence: 1
            ),
            bounds: oneSessionBounds
        )
        suite.check(
            boundedProjection.apply(
                update(sequence: 2, .sessionUpsert(session(id: secondID))),
                bounds: oneSessionBounds
            ) == .rejected(.boundsExceeded),
            "incremental inventory cannot exceed its Session bound"
        )
        suite.check(
            boundedProjection.freshness == .stale
                && !boundedProjection.hasCurrentAuthority(for: codexSessionID),
            "bounds failure clears every authoritative Session"
        )

        let knownRunID = RunID(rawValue: "known-run")
        let requestID = AttentionRequestID(rawValue: "run-request")
        let sessionWithRun = ConnSession(
            id: codexSessionID,
            status: .working,
            runs: [.init(id: knownRunID, status: .inProgress)],
            updatedAt: at(3)
        )
        let runRequest = AttentionRequest(
            id: requestID,
            sessionID: codexSessionID,
            runID: knownRunID,
            kind: .approval,
            summary: "Approve",
            observedAt: at(3)
        )
        var runProjection = IntegrationProjection()
        suite.check(
            runProjection.qualify(with: .init(
                integration: .init(
                    id: codexIntegration,
                    harnessID: codexHarness,
                    displayName: "Codex"
                ),
                generation: generation,
                throughSequence: 3,
                inventoryAuthority: .complete,
                capabilities: .init(canMonitor: true),
                sessions: [sessionWithRun],
                attentionRequests: [runRequest],
                observedAt: at(3)
            )) == .qualified,
            "Attention may reference an evidence-backed Run"
        )
        suite.check(
            runProjection.apply(update(
                sequence: 4,
                .sessionUpsert(session(id: codexSessionID))
            )) == .applied
                && runProjection.attentionRequests.isEmpty,
            "replacing a Session prunes Attention whose Run no longer exists"
        )

        var completeReplacementProjection = IntegrationProjection()
        _ = completeReplacementProjection.qualify(with: .init(
            integration: .init(
                id: codexIntegration,
                harnessID: codexHarness,
                displayName: "Codex"
            ),
            generation: generation,
            throughSequence: 3,
            inventoryAuthority: .complete,
            capabilities: .init(canMonitor: true),
            sessions: [sessionWithRun],
            attentionRequests: [runRequest],
            observedAt: at(3)
        ))
        suite.check(
            completeReplacementProjection.qualify(with: .init(
                integration: .init(
                    id: codexIntegration,
                    harnessID: codexHarness,
                    displayName: "Codex"
                ),
                generation: generation,
                throughSequence: 4,
                inventoryAuthority: .complete,
                capabilities: .init(canMonitor: true),
                sessions: [session(id: codexSessionID)],
                attentionRequests: [runRequest],
                observedAt: at(4)
            )) == .rejected(.invalidRunReference),
            "complete replacement cannot validate Attention against a removed prior Run"
        )
    }

    private static func actionAvailabilityNeedsLocalCapabilityAndAuthority(
        into suite: inout TestSuite
    ) {
        let controllable = IntegrationCapabilities(
            canMonitor: true,
            actions: [.followUp, .steer, .interrupt, .answer]
        )
        let monitorOnly = IntegrationCapabilities(canMonitor: true)
        let activeRun = RunID(rawValue: "run")
        let request = AttentionRequestID(rawValue: "request")

        let codexInput = SessionActionAvailabilityInput(
            sessionID: codexSessionID,
            freshness: .live,
            capabilities: controllable,
            hasCurrentAuthority: true,
            activeRunID: activeRun,
            attentionRequestIDs: [request]
        )
        suite.check(
            codexInput.capabilities.supports(.followUp)
                && codexInput.hasCurrentAuthority
                && codexInput.activeRunID == activeRun,
            "availability input preserves local capability and exact authority evidence"
        )
        let syntheticInput = SessionActionAvailabilityInput(
            sessionID: syntheticSessionID,
            freshness: .live,
            capabilities: monitorOnly,
            hasCurrentAuthority: true,
            activeRunID: activeRun,
            attentionRequestIDs: [request]
        )
        suite.check(
            !syntheticInput.capabilities.supports(.followUp)
                && syntheticInput.sessionID.integrationID == syntheticIntegration,
            "monitor-only Integration input cannot carry another Integration's controls"
        )
        let rehydratedInput = SessionActionAvailabilityInput(
            sessionID: codexSessionID,
            freshness: .rehydrated,
            capabilities: controllable,
            hasCurrentAuthority: false,
            activeRunID: activeRun,
            attentionRequestIDs: [request]
        )
        suite.check(
            rehydratedInput.freshness == .rehydrated
                && !rehydratedInput.hasCurrentAuthority,
            "rehydrated availability input carries no current authority"
        )
    }

    private static func actionPayloadsRejectLossyBounds(
        into suite: inout TestSuite
    ) throws {
        let bounds = ConnDomainBounds(
            maximumIdentifierUTF8Bytes: 8,
            maximumWorkspacePathUTF8Bytes: 8,
            maximumActionTextUTF8Bytes: 4,
            maximumStructuredQuestions: 1,
            maximumAnswersPerQuestion: 1,
            maximumStructuredAnswerUTF8Bytes: 4
        )
        let validActionText = try ConnActionText("界", bounds: bounds)
        suite.check(
            validActionText.value == "界",
            "bounded action text preserves valid UTF-8 input exactly"
        )
        do {
            _ = try ConnActionText("12345", bounds: bounds)
            suite.check(false, "oversize prompt is rejected")
        } catch {
            suite.check(
                error as? ConnActionPayloadError == .exceedsUTF8Limit(4),
                "prompt bounds reject rather than silently truncate"
            )
        }
        do {
            _ = try ConnWorkspacePath("/too/long", bounds: bounds)
            suite.check(false, "oversize Workspace path is rejected")
        } catch {
            suite.check(
                error as? ConnActionPayloadError == .exceedsUTF8Limit(8),
                "Workspace action input has an explicit byte bound"
            )
        }
        do {
            _ = try ConnStructuredAnswers(
                valuesByQuestionID: ["q": ["one", "two"]],
                bounds: bounds
            )
            suite.check(false, "too many structured answers are rejected")
        } catch {
            suite.check(
                error as? ConnActionPayloadError == .tooManyAnswers,
                "structured-answer cardinality is bounded"
            )
        }
        let validAnswers = try ConnStructuredAnswers(
            valuesByQuestionID: ["q": ["界"]],
            bounds: bounds
        )
        suite.check(
            validAnswers.valuesByQuestionID["q"] == ["界"],
            "valid structured answers remain exact and runtime-only"
        )
    }

    private static func checkpointValidationRejectsUnsafeState(
        into suite: inout TestSuite
    ) throws {
        let descriptor = IntegrationDescriptor(
            id: codexIntegration,
            harnessID: codexHarness,
            displayName: "Codex"
        )
        let persisted = PersistedIntegrationProjection(
            descriptor: descriptor,
            inventoryAuthority: .complete,
            sessions: [session(id: codexSessionID)],
            checkpointedAt: at(20)
        )
        let valid = ConnProjectionCheckpoint(integrations: [persisted])
        try valid.validate()
        suite.check(true, "valid neutral checkpoint passes structural validation")

        let encoded = try JSONEncoder().encode(valid)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        suite.check(
            !encodedText.contains(generation.instanceID.uuidString)
                && !encodedText.contains("responseToken")
                && !encodedText.contains("capabilities"),
            "checkpoint schema cannot persist generation, response authority, or capability proof"
        )

        do {
            try ConnProjectionCheckpoint(
                schemaVersion: 99,
                integrations: [persisted]
            ).validate()
            suite.check(false, "unsupported checkpoint schema is rejected")
        } catch {
            suite.check(
                error as? ConnProjectionCheckpointError
                    == .unsupportedSchemaVersion(99),
                "unsupported checkpoint schema reports its version"
            )
        }

        do {
            try ConnProjectionCheckpoint(integrations: [persisted, persisted]).validate()
            suite.check(false, "duplicate Integration checkpoint is rejected")
        } catch {
            suite.check(
                error as? ConnProjectionCheckpointError
                    == .duplicateIntegration(codexIntegration),
                "duplicate Integration identity cannot merge restored authority"
            )
        }

        let wrongSession = session(id: syntheticSessionID)
        do {
            try ConnProjectionCheckpoint(integrations: [
                .init(
                    descriptor: descriptor,
                    inventoryAuthority: .partial,
                    sessions: [wrongSession],
                    checkpointedAt: at(20)
                ),
            ]).validate()
            suite.check(false, "wrongly scoped Session checkpoint is rejected")
        } catch {
            suite.check(
                error as? ConnProjectionCheckpointError == .wrongIntegrationScope,
                "checkpoint enforces composite Session scope"
            )
        }

        let duplicateActivity = ConnActivity(
            id: ActivityID(rawValue: "duplicate"),
            kind: .plan,
            status: .completed,
            observedAt: at(21)
        )
        let invalidNestedIdentity = ConnSession(
            id: codexSessionID,
            status: .idle,
            activities: [duplicateActivity, duplicateActivity],
            updatedAt: at(21)
        )
        do {
            try ConnProjectionCheckpoint(integrations: [
                .init(
                    descriptor: descriptor,
                    inventoryAuthority: .complete,
                    sessions: [invalidNestedIdentity],
                    checkpointedAt: at(21)
                ),
            ]).validate()
            suite.check(false, "duplicate nested checkpoint identity is rejected")
        } catch {
            suite.check(
                error as? ConnProjectionCheckpointError == .duplicateNestedIdentity,
                "checkpoint validates nested Activity identity"
            )
        }
    }

    private static func atomicFeedDeliversPostWatermarkUpdateExactlyOnce(
        into suite: inout TestSuite
    ) async throws {
        let integration = SyntheticMonitorIntegration(
            descriptor: .init(
                id: syntheticIntegration,
                harnessID: syntheticHarness,
                displayName: "Synthetic"
            ),
            generation: generation,
            session: session(id: syntheticSessionID)
        )
        let feed = try await integration.establishFeed()
        suite.check(feed.snapshot.throughSequence == 1, "snapshot publishes its exact watermark")

        var iterator = feed.updates.makeAsyncIterator()
        let racedUpdate = await iterator.next()
        suite.check(racedUpdate?.cursor.sequence == 2, "post-watermark race is already buffered")

        var projection = IntegrationProjection()
        suite.check(
            projection.qualify(with: feed.snapshot) == .qualified,
            "watermarked snapshot qualifies before buffered updates"
        )
        if let racedUpdate {
            suite.check(projection.apply(racedUpdate) == .applied, "buffered update applies once")
            suite.check(
                projection.apply(racedUpdate) == .ignoredDuplicate,
                "re-delivery at the watermark is not applied twice"
            )
        }
        let racedActivities = projection.sessions.first?.activities.filter {
            $0.id == ActivityID(rawValue: "raced")
        }
        suite.check(
            racedActivities?.count == 1,
            "the update racing feed creation appears exactly once"
        )
    }

    private static func syntheticIntegrationProvesMonitorOnlySeam(
        into suite: inout TestSuite
    ) async throws {
        let integration = SyntheticMonitorIntegration(
            descriptor: .init(
                id: syntheticIntegration,
                harnessID: syntheticHarness,
                displayName: "Synthetic Monitor"
            ),
            generation: generation,
            session: session(id: syntheticSessionID)
        )
        let feed = try await integration.establishFeed()
        suite.check(
            feed.snapshot.capabilities.canMonitor
                && feed.snapshot.capabilities.actions.isEmpty,
            "test-only non-Codex Integration supports monitoring without controls"
        )
        suite.check(
            feed.snapshot.sessions.first?.runs.isEmpty == true
                && feed.snapshot.sessions.first?.activities.first?.runID == nil,
            "synthetic Integration emits Session-scoped Activity without a Run"
        )
        let outcome = await integration.perform(.followUp(
            sessionID: syntheticSessionID,
            text: try ConnActionText("must not send")
        ))
        suite.check(
            outcome.kind == .unavailable
                && outcome.integrationID == syntheticIntegration
                && outcome.action == .followUp,
            "unsupported action returns an evidence-bearing unavailable outcome"
        )
        let performedActionCount = await integration.performedActionCount
        suite.check(
            performedActionCount == 1,
            "synthetic fixture observes the attempted route without claiming execution"
        )
    }

    private static func snapshot(
        authority: InventoryAuthority,
        sessions: [ConnSession],
        throughSequence: UInt64
    ) -> IntegrationSnapshot {
        .init(
            integration: .init(
                id: codexIntegration,
                harnessID: codexHarness,
                displayName: "Codex"
            ),
            generation: generation,
            throughSequence: throughSequence,
            inventoryAuthority: authority,
            capabilities: .init(canMonitor: true, actions: [.followUp, .interrupt]),
            sessions: sessions,
            observedAt: at(TimeInterval(throughSequence))
        )
    }

    private static func update(
        sequence: UInt64,
        _ update: IntegrationSemanticUpdate
    ) -> IntegrationUpdate {
        .init(
            integrationID: codexIntegration,
            cursor: .init(generation: generation, sequence: sequence),
            observedAt: at(TimeInterval(sequence)),
            update: update
        )
    }

    private static func session(
        id: ConnSessionID,
        title: String? = nil
    ) -> ConnSession {
        .init(
            id: id,
            title: title,
            origin: .external,
            ownership: .harness,
            retention: .unknown,
            status: .working,
            activities: [
                .init(
                    id: ActivityID(rawValue: "seed"),
                    runID: nil,
                    kind: .agentMessage,
                    status: .completed,
                    summary: "Session activity",
                    observedAt: at(1)
                ),
            ],
            updatedAt: at(1)
        )
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        baseDate.addingTimeInterval(seconds)
    }
}

private actor SyntheticMonitorIntegration: ConnIntegration {
    nonisolated let descriptor: IntegrationDescriptor
    private let generation: IntegrationConnectionGeneration
    private let session: ConnSession
    private(set) var performedActionCount = 0

    init(
        descriptor: IntegrationDescriptor,
        generation: IntegrationConnectionGeneration,
        session: ConnSession
    ) {
        self.descriptor = descriptor
        self.generation = generation
        self.session = session
    }

    func establishFeed() async throws(ConnIntegrationError) -> ConnIntegrationFeed {
        let racedActivity = ConnActivity(
            id: ActivityID(rawValue: "raced"),
            runID: nil,
            kind: .unknown,
            status: .started,
            summary: "Synthetic work",
            observedAt: Date(timeIntervalSince1970: 1_840_000_002)
        )
        let racedUpdate = IntegrationUpdate(
            integrationID: descriptor.id,
            cursor: .init(generation: generation, sequence: 2),
            observedAt: racedActivity.observedAt,
            update: .activityUpsert(sessionID: session.id, activity: racedActivity)
        )
        let updates = AsyncStream<IntegrationUpdate>(
            bufferingPolicy: .bufferingOldest(4)
        ) { continuation in
            continuation.yield(racedUpdate)
            continuation.finish()
        }
        return ConnIntegrationFeed(
            snapshot: .init(
                integration: descriptor,
                generation: generation,
                throughSequence: 1,
                inventoryAuthority: .complete,
                capabilities: .init(canMonitor: true),
                sessions: [session],
                observedAt: Date(timeIntervalSince1970: 1_840_000_001)
            ),
            updates: updates
        )
    }

    func perform(_ action: ConnAction) async -> ConnActionOutcome {
        performedActionCount += 1
        return ConnActionOutcome(
            integrationID: descriptor.id,
            action: action.kind,
            kind: .unavailable,
            evidence: "Synthetic Integration is monitor-only"
        )
    }
}
