import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase9ThreadControlRuntimeTestCases {
    private static let observedAt = Date(timeIntervalSince1970: 1_850_100_000)
    private static let threadID = AppServerThreadID(rawValue: "phase9-runtime-thread")
    private static let turnID = AppServerTurnID(rawValue: "phase9-runtime-turn")
    private static let testModelID = "phase92-model-id"
    private static let testModel = "gpt-phase92"

    static func run(into suite: inout TestSuite) async throws {
        await routesAcknowledgedCompletionToCapturedThreadAfterSelectionChange(into: &suite)
        await appliesOnlyAnExplicitCataloguedFollowUpModelOverride(into: &suite)
        await invalidatesCapturedIdentityOnReconnect(into: &suite)
        await preservesDraftRevisionWhenAcknowledgementExpires(into: &suite)
        await coolsDownTimedOutDraftUntilBoundedReconciliation(into: &suite)
        await keepsCooldownWhenReconcileDoesNotConfirmTheExactThread(into: &suite)
        try await closesTimedOutDraftCooldownFromProjectionFacts(into: &suite)
        await suppressesDuplicateIntentWhileOriginalIsPending(into: &suite)
        await loadsBoundedPaginatedModelCatalog(into: &suite)
        await rejectsAmbiguousOrCyclicModelCatalogs(into: &suite)
        await rejectsUncataloguedModelWithoutConsequentialSend(into: &suite)
        await revokesCatalogAuthorityWhenRefreshFails(into: &suite)
        await revokesCatalogAuthorityDuringCreationPreflight(into: &suite)
        await discardsModelCatalogWhenConnectionChangesDuringLoad(into: &suite)
        await keepsNewestConcurrentModelCatalogAuthoritative(into: &suite)
        await createsOneClickEphemeralThreadWithServerDefaultModel(into: &suite)
        await startsFirstTurnOnExactAcknowledgedEmptyThread(into: &suite)
        await reservesEmptyThreadLeaseAcrossConcurrentDrafts(into: &suite)
        await locksEmptyThreadLeaseAfterMalformedAcknowledgement(into: &suite)
        await failsClosedWhenEmptyThreadUncertaintyLedgerOverflows(into: &suite)
        await invalidatesLateOneClickNewChatAfterReconnect(into: &suite)
        await createsThreadAndInitialTurnAsOneBoundedIntent(into: &suite)
        await blocksUnchangedNewThreadAfterUncertainAcknowledgement(into: &suite)
        await refusesMalformedThreadStartWithoutSendingATurn(into: &suite)
        try await routesSubscribedExternalApprovalOnlyWhenPolicyAdopted(into: &suite)
        try await reconcilesOnlyTheExactRequestResolvedElsewhere(into: &suite)
        await reconcilesStaleExpectedTurnWithoutRetry(into: &suite)
        await confirmsInterruptTerminalStateThroughThreadRead(into: &suite)
        try await routesInputsAndPrunesResolvedQuestionAnswers(into: &suite)
    }

    private static func routesSubscribedExternalApprovalOnlyWhenPolicyAdopted(
        into suite: inout TestSuite
    ) async throws {
        let conservativeState = await makeCoordinator(
            generation: 30,
            status: .active([]),
            activeTurn: turnID
        )
        try await openApproval(
            .integer(3_001),
            sequence: 1,
            coordinator: conservativeState.coordinator,
            identity: conservativeState.identity
        )
        let conservativeConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(30)
        )
        let conservativeRuntime = AppServerThreadControlRuntime()
        await conservativeRuntime.attach(
            connection: conservativeConnection,
            wireIdentity: wireIdentity(30),
            domainConnection: conservativeState.identity,
            coordinator: conservativeState.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        let conservativeRequest = AppServerScopedRequestID(
            connection: conservativeState.identity,
            requestID: .integer(3_001)
        )
        let blocked = await conservativeRuntime.execute(
            .decide(
                request: conservativeRequest,
                threadID: threadID,
                turnID: turnID,
                choice: .approveForSession
            ),
            selectionGeneration: 0
        )
        suite.checkEqual(blocked.outcome, .resolvedElsewhere, "conservative routing still refuses a Codex-originated approval")
        suite.checkEqual(await conservativeConnection.respondedRequestIDs(), [], "conservative routing sends no external approval response")

        let subscribedState = await makeCoordinator(
            generation: 31,
            status: .active([]),
            activeTurn: turnID
        )
        try await openApproval(
            .integer(3_101),
            sequence: 1,
            coordinator: subscribedState.coordinator,
            identity: subscribedState.identity
        )
        let subscribedRequest = AppServerScopedRequestID(
            connection: subscribedState.identity,
            requestID: .integer(3_101)
        )
        let resolve = AppServerProjectionInput.delta(.init(
            cursor: cursor(subscribedState.identity, sequence: 2),
            observedAt: observedAt.addingTimeInterval(2),
            delta: .requestResolved(threadID: threadID, requestID: .integer(3_101))
        ))
        let subscribedConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(31),
            respondActions: [.applyThenFail(
                coordinator: subscribedState.coordinator,
                input: resolve,
                error: .unknownServerRequest(.integer(3_101))
            )]
        )
        let subscribedRuntime = AppServerThreadControlRuntime(configuration: .init(
            routingPolicy: .allSubscribedConnectionsQualified
        ))
        await subscribedRuntime.attach(
            connection: subscribedConnection,
            wireIdentity: wireIdentity(31),
            domainConnection: subscribedState.identity,
            coordinator: subscribedState.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        let availability = await subscribedRuntime.availability()
        let projectedRequest = await subscribedState.coordinator.snapshot().attentionRequests[0]
        suite.check(availability.mayRespond(to: projectedRequest), "adopted subscribed routing authorizes the exact current-connection request")

        let resolved = await subscribedRuntime.execute(
            .decide(
                request: subscribedRequest,
                threadID: threadID,
                turnID: turnID,
                choice: .approveForSession
            ),
            selectionGeneration: 0
        )
        suite.checkEqual(resolved.outcome, .resolvedElsewhere, "a racing origin-client resolution is reconciled after Conn responds")
        suite.checkEqual(await subscribedConnection.respondedRequestIDs(), [.integer(3_101)], "subscribed routing sends exactly one response for the exact wire request")

        let questionState = await makeCoordinator(generation: 32, status: .active([]))
        try await openQuestion(
            .integer(3_201),
            sequence: 1,
            coordinator: questionState.coordinator,
            identity: questionState.identity
        )
        let questionConnection = Phase9ScriptedControlConnection(identity: wireIdentity(32))
        let questionRuntime = AppServerThreadControlRuntime(configuration: .init(
            routingPolicy: .allSubscribedConnectionsQualified
        ))
        await questionRuntime.attach(
            connection: questionConnection,
            wireIdentity: wireIdentity(32),
            domainConnection: questionState.identity,
            coordinator: questionState.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        let questionRequest = AppServerScopedRequestID(
            connection: questionState.identity,
            requestID: .integer(3_201)
        )
        let question = await questionState.coordinator.snapshot().attentionRequests[0]
        let questionAvailability = await questionRuntime.availability()
        suite.check(!questionAvailability.mayRespond(to: question), "approval routing opt-in does not authorize an external structured question")
        let blockedQuestion = await questionRuntime.execute(
            .answer(
                request: questionRequest,
                threadID: threadID,
                turnID: nil,
                answers: .init(valuesByQuestionID: ["secret": ["answer"]])
            ),
            selectionGeneration: 0
        )
        suite.checkEqual(blockedQuestion.outcome, .resolvedElsewhere, "external question stays bound to its originating Codex client")
        suite.checkEqual(await questionConnection.respondedRequestIDs(), [], "approval opt-in sends no external question response")

        let reconnectState = await makeCoordinator(
            generation: 33,
            status: .active([]),
            activeTurn: turnID
        )
        try await openApproval(
            .integer(3_301),
            sequence: 1,
            coordinator: reconnectState.coordinator,
            identity: reconnectState.identity
        )
        let identityGate = Phase9RuntimeGate()
        let reconnectConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(33),
            controlIdentityGate: identityGate
        )
        let reconnectRuntime = AppServerThreadControlRuntime(configuration: .init(
            routingPolicy: .allSubscribedConnectionsQualified
        ))
        await reconnectRuntime.attach(
            connection: reconnectConnection,
            wireIdentity: wireIdentity(33),
            domainConnection: reconnectState.identity,
            coordinator: reconnectState.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        let reconnectRequest = AppServerScopedRequestID(
            connection: reconnectState.identity,
            requestID: .integer(3_301)
        )
        let response = Task {
            await reconnectRuntime.execute(
                .decide(
                    request: reconnectRequest,
                    threadID: threadID,
                    turnID: turnID,
                    choice: .approve
                ),
                selectionGeneration: 0
            )
        }
        await identityGate.waitUntilEntered()
        await reconnectRuntime.detach(ifWireIdentityMatches: wireIdentity(33))
        await identityGate.release()
        suite.checkEqual((await response.value).outcome, .connectionInvalidated, "reconnect revokes approval authority at the final wire-identity check")
        suite.checkEqual(await reconnectConnection.respondedRequestIDs(), [], "revoked approval authority sends no late response")
    }

    private static func loadsBoundedPaginatedModelCatalog(into suite: inout TestSuite) async {
        let defaultRow = modelRow(
            id: "default-id",
            model: "gpt-default",
            displayName: "Default Model",
            isDefault: true
        )
        let duplicateRow = modelRow(
            id: "duplicate-id",
            model: "gpt-default",
            displayName: "Duplicate Model"
        )
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(28),
            requestActions: [
                .success(method: "model/list", result: modelListPage(
                    rows: [modelRow(hidden: true), defaultRow],
                    nextCursor: .string("page-two")
                )),
                .success(method: "model/list", result: modelListPage(
                    rows: [duplicateRow, modelRow(id: "other-id", model: "gpt-other", displayName: "Other Model")]
                )),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 28, status: .idle)
        let result = await harness.runtime.loadNewThreadModelCatalog()

        suite.checkEqual(result.outcome, .available, "bounded paginated model catalog becomes available")
        suite.checkEqual(result.catalog?.options.map(\.model), ["gpt-default", "gpt-other"], "hidden models are excluded and exact wire-model duplicates are removed")
        suite.checkEqual(result.catalog?.defaultOptionID, "default-id", "the visible server default is selected")
        let calls = await connection.requestCalls()
        suite.checkEqual(calls.map(\.method), ["model/list", "model/list"], "catalog pagination performs only stable reads")
        suite.checkEqual(calls.first?.params, .object([
            "includeHidden": .bool(false),
            "limit": .integer(100),
        ]), "first model page requests only visible bounded rows")
        suite.checkEqual(calls.last?.params, .object([
            "includeHidden": .bool(false),
            "limit": .integer(100),
            "cursor": .string("page-two"),
        ]), "next model page uses only the exact returned cursor")
    }

    private static func rejectsAmbiguousOrCyclicModelCatalogs(
        into suite: inout TestSuite
    ) async {
        let duplicateConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(34),
            requestActions: [.success(method: "model/list", result: modelListPage(rows: [
                modelRow(id: "duplicate", model: "gpt-one"),
                modelRow(id: "duplicate", model: "gpt-two"),
            ]))]
        )
        let duplicateHarness = await makeHarness(
            connection: duplicateConnection,
            generation: 34,
            status: .idle
        )
        suite.checkEqual(
            (await duplicateHarness.runtime.loadNewThreadModelCatalog()).outcome,
            .invalidResponse,
            "duplicate picker IDs reject an ambiguous catalog"
        )

        let cyclicConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(35),
            requestActions: [
                .success(method: "model/list", result: modelListPage(
                    rows: [modelRow(id: "first", model: "gpt-first")],
                    nextCursor: .string("repeat")
                )),
                .success(method: "model/list", result: modelListPage(
                    rows: [modelRow(id: "second", model: "gpt-second")],
                    nextCursor: .string("repeat")
                )),
            ]
        )
        let cyclicHarness = await makeHarness(
            connection: cyclicConnection,
            generation: 35,
            status: .idle
        )
        suite.checkEqual(
            (await cyclicHarness.runtime.loadNewThreadModelCatalog()).outcome,
            .invalidResponse,
            "repeated pagination cursor rejects a cyclic catalog"
        )
    }

    private static func rejectsUncataloguedModelWithoutConsequentialSend(
        into suite: inout TestSuite
    ) async {
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(29),
            requestActions: [.success(method: "model/list", result: modelListResult())]
        )
        let harness = await makeHarness(connection: connection, generation: 29, status: .idle)
        _ = await harness.runtime.loadNewThreadModelCatalog()
        let result = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Do not send a tampered model",
            modelID: testModelID,
            model: "tampered-wire-model",
            draftRevision: 908
        ))
        suite.checkEqual(result.outcome, .stalePrecondition, "model ID and wire model must exactly match the current catalog")
        suite.checkEqual(await connection.requestMethods(), ["model/list"], "uncatalogued model causes zero consequential sends")
    }

    private static func revokesCatalogAuthorityWhenRefreshFails(
        into suite: inout TestSuite
    ) async {
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(30),
            requestActions: [
                .success(method: "model/list", result: modelListResult()),
                .success(method: "model/list", result: .object(["data": .string("invalid")])),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 30, status: .idle)
        suite.checkEqual((await harness.runtime.loadNewThreadModelCatalog()).outcome, .available, "initial catalog is usable")
        suite.checkEqual((await harness.runtime.loadNewThreadModelCatalog()).outcome, .invalidResponse, "invalid refresh is reported honestly")
        let result = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Old authority must be gone",
            modelID: testModelID,
            model: testModel,
            draftRevision: 909
        ))
        suite.checkEqual(result.outcome, .stalePrecondition, "failed refresh revokes earlier same-connection catalog authority")
        suite.checkEqual(await connection.requestMethods(), ["model/list", "model/list"], "revoked catalog cannot reach thread/start")
    }

    private static func revokesCatalogAuthorityDuringCreationPreflight(
        into suite: inout TestSuite
    ) async {
        let gate = Phase9RuntimeGate()
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(36),
            requestActions: [
                .success(method: "model/list", result: modelListResult()),
                .success(method: "model/list", result: .object(["data": .string("invalid")])),
            ]
        )
        let harness = await makeHarness(
            connection: connection,
            generation: 36,
            status: .idle,
            newThreadPreCommitProbe: { await gate.enterAndWait() }
        )
        _ = await harness.runtime.loadNewThreadModelCatalog()
        let creation = Task { await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Do not outlive catalog authority",
            modelID: testModelID,
            model: testModel,
            draftRevision: 911
        )) }
        await gate.waitUntilEntered()
        suite.checkEqual(
            (await harness.runtime.loadNewThreadModelCatalog()).outcome,
            .invalidResponse,
            "concurrent refresh revokes the captured catalog during creation preflight"
        )
        await gate.release()
        suite.checkEqual((await creation.value).outcome, .stalePrecondition, "creation revalidates catalog authority after actor reentrancy")
        suite.checkEqual(await connection.requestMethods(), ["model/list", "model/list"], "revoked preflight sends no thread/start")
    }

    private static func discardsModelCatalogWhenConnectionChangesDuringLoad(
        into suite: inout TestSuite
    ) async {
        let gate = Phase9RuntimeGate()
        let oldConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(31),
            requestActions: [.blocked(method: "model/list", gate: gate, result: modelListResult())]
        )
        let harness = await makeHarness(connection: oldConnection, generation: 31, status: .idle)
        let loading = Task { await harness.runtime.loadNewThreadModelCatalog() }
        await gate.waitUntilEntered()
        let replacement = await makeCoordinator(generation: 32, status: .idle)
        await harness.runtime.attach(
            connection: Phase9ScriptedControlConnection(identity: wireIdentity(32)),
            wireIdentity: wireIdentity(32),
            domainConnection: replacement.identity,
            coordinator: replacement.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        await gate.release()
        suite.checkEqual((await loading.value).outcome, .connectionInvalidated, "catalog response is discarded after reconnect")
    }

    private static func keepsNewestConcurrentModelCatalogAuthoritative(
        into suite: inout TestSuite
    ) async {
        let gate = Phase9RuntimeGate()
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(33),
            requestActions: [
                .blocked(
                    method: "model/list",
                    gate: gate,
                    result: modelListResult(id: "old-id", model: "gpt-old")
                ),
                .success(
                    method: "model/list",
                    result: modelListResult(id: "new-id", model: "gpt-new")
                ),
                .success(
                    method: "thread/start",
                    result: threadStartResult(.init(rawValue: "newest-catalog-thread"))
                ),
                .success(
                    method: "turn/start",
                    result: turnStartResult(.init(rawValue: "newest-catalog-turn"))
                ),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 33, status: .idle)
        let oldLoad = Task { await harness.runtime.loadNewThreadModelCatalog() }
        await gate.waitUntilEntered()
        let newLoad = await harness.runtime.loadNewThreadModelCatalog()
        await gate.release()
        suite.checkEqual(newLoad.catalog?.options.first?.model, "gpt-new", "newest concurrent catalog wins")
        suite.checkEqual((await oldLoad.value).outcome, .connectionInvalidated, "late older catalog cannot overwrite newer authority")
        let result = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Use only newest catalog",
            modelID: "new-id",
            model: "gpt-new",
            draftRevision: 910
        ))
        suite.checkEqual(result.outcome, .accepted, "newest catalog remains authoritative after older load returns")
    }

    private static func createsThreadAndInitialTurnAsOneBoundedIntent(
        into suite: inout TestSuite
    ) async {
        let createdThread = AppServerThreadID(rawValue: "phase92-created-thread")
        let createdTurn = AppServerTurnID(rawValue: "phase92-created-turn")
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(21),
            requestActions: [
                .success(method: "model/list", result: modelListResult()),
                .success(method: "thread/start", result: threadStartResult(createdThread)),
                .success(method: "turn/start", result: turnStartResult(createdTurn)),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 21, status: .idle)
        _ = await harness.runtime.loadNewThreadModelCatalog()
        let result = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Start safely",
            modelID: testModelID,
            model: testModel,
            draftRevision: 901
        ))

        suite.checkEqual(
            result,
            .init(
                outcome: .accepted,
                stage: .initialTurn,
                createdThreadID: createdThread,
                acceptedTurnID: createdTurn,
                draftRevision: 901
            ),
            "New Chat succeeds only after exact thread and first-turn acknowledgements"
        )
        let calls = await connection.requestCalls()
        suite.checkEqual(calls.map(\.method), ["model/list", "thread/start", "turn/start"], "New Chat reads models, then sends the two reviewed methods once in order")
        suite.checkEqual(
            calls[1].params,
            .object([
                "cwd": .string("/tmp"),
                "ephemeral": .bool(true),
                "model": .string(testModel),
            ]),
            "thread/start binds the explicit directory and selected wire model ephemerally"
        )
        suite.checkEqual(
            calls.last?.params,
            .object([
                "threadId": .string(createdThread.rawValue),
                "input": .array([.object([
                    "type": .string("text"),
                    "text": .string("Start safely"),
                ])]),
            ]),
            "the first turn targets only the exact returned thread with bounded text input"
        )
        let availability = await harness.runtime.availability()
        suite.check(
            availability.responseAuthoritativeTurns.contains(createdTurn),
            "only the acknowledged first turn grants Conn response authority"
        )
    }

    private static func createsOneClickEphemeralThreadWithServerDefaultModel(
        into suite: inout TestSuite
    ) async {
        let createdThread = AppServerThreadID(rawValue: "phase115-empty-thread")
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(115),
            requestActions: [
                .success(method: "thread/start", result: threadStartResult(createdThread)),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 115, status: .idle)
        let result = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "",
            modelID: "",
            model: "",
            draftRevision: 1_150
        ))

        suite.checkEqual(
            result,
            .init(
                outcome: .accepted,
                stage: .threadStart,
                createdThreadID: createdThread,
                draftRevision: 1_150
            ),
            "one-click New Chat accepts the exact empty ephemeral thread"
        )
        let calls = await connection.requestCalls()
        suite.checkEqual(
            calls.map(\.method),
            ["thread/start"],
            "one-click New Chat neither loads models nor starts a turn"
        )
        suite.checkEqual(
            calls.first?.params,
            .object([
                "cwd": .string("/tmp"),
                "ephemeral": .bool(true),
            ]),
            "one-click New Chat uses the configured workspace and server-default model"
        )
    }

    private static func invalidatesLateOneClickNewChatAfterReconnect(
        into suite: inout TestSuite
    ) async {
        let gate = Phase9RuntimeGate()
        let createdThread = AppServerThreadID(rawValue: "phase115-late-empty-thread")
        let oldConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(117),
            requestActions: [
                .blocked(
                    method: "thread/start",
                    gate: gate,
                    result: threadStartResult(createdThread)
                ),
            ]
        )
        let harness = await makeHarness(connection: oldConnection, generation: 117, status: .idle)
        let intent = AppServerNewThreadIntent(
            workingDirectory: "/tmp",
            initialPrompt: "",
            modelID: "",
            model: "",
            draftRevision: 1_151
        )
        let creation = Task { await harness.runtime.executeNewThread(intent) }
        await gate.waitUntilEntered()

        let replacementConnection = Phase9ScriptedControlConnection(identity: wireIdentity(118))
        let replacement = await makeCoordinator(generation: 118, status: .idle)
        await harness.runtime.attach(
            connection: replacementConnection,
            wireIdentity: wireIdentity(118),
            domainConnection: replacement.identity,
            coordinator: replacement.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        await gate.release()

        let result = await creation.value
        suite.checkEqual(result.outcome, .connectionInvalidated, "late one-click acknowledgement cannot cross a reconnect")
        suite.checkEqual(result.createdThreadID, createdThread, "late acknowledgement retains the exact old-session thread for honest diagnostics")
        suite.checkEqual(
            (await harness.runtime.executeNewThread(intent)).outcome,
            .acknowledgementUncertain,
            "the unchanged one-click attempt stays blocked after its old-session acknowledgement"
        )
        suite.checkEqual(await oldConnection.requestMethods(), ["thread/start"], "old authority receives one consequential send")
        suite.checkEqual(await replacementConnection.requestMethods(), [], "late acknowledgement is never retargeted to the replacement connection")
    }

    private static func startsFirstTurnOnExactAcknowledgedEmptyThread(
        into suite: inout TestSuite
    ) async {
        let createdThread = AppServerThreadID(rawValue: "phase115-empty-first-turn")
        let createdTurn = AppServerTurnID(rawValue: "phase115-empty-first-turn-result")
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(119),
            requestActions: [
                .success(method: "thread/start", result: threadStartResult(createdThread)),
                .success(method: "turn/start", result: turnStartResult(createdTurn)),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 119, status: .idle)
        let creation = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "",
            modelID: "",
            model: "",
            draftRevision: 1_152
        ))
        suite.checkEqual(creation.outcome, .accepted, "one-click empty thread is acknowledged before composer input")

        let firstTurn = await harness.runtime.execute(
            .followUp(
                threadID: createdThread,
                text: "First composed message",
                draftRevision: 1
            ),
            selectionGeneration: 0
        )
        suite.checkEqual(firstTurn.outcome, .accepted, "composer starts the first turn on the exact acknowledged empty thread")
        suite.checkEqual(firstTurn.acceptedTurnID, createdTurn, "first composer send retains exact accepted turn authority")
        suite.checkEqual(
            await connection.requestMethods(),
            ["thread/start", "turn/start"],
            "empty-thread composer lease creates neither a second thread nor a resume request"
        )
    }

    private static func reservesEmptyThreadLeaseAcrossConcurrentDrafts(
        into suite: inout TestSuite
    ) async {
        let gate = Phase9RuntimeGate()
        let threadID = AppServerThreadID(rawValue: "phase115-reserved-empty-thread")
        let turnID = AppServerTurnID(rawValue: "phase115-reserved-empty-turn")
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(120),
            requestActions: [
                .success(method: "thread/start", result: threadStartResult(threadID)),
                .blocked(method: "turn/start", gate: gate, result: turnStartResult(turnID)),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 120, status: .idle)
        _ = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "",
            modelID: "",
            model: "",
            draftRevision: 1_153
        ))
        let first = Task { await harness.runtime.execute(
            .followUp(threadID: threadID, text: "First", draftRevision: 1),
            selectionGeneration: 0
        ) }
        await gate.waitUntilEntered()
        _ = try? await harness.coordinator.applyAndPersist(.snapshot(.init(
            cursor: cursor(harness.identity, sequence: 1),
            observedAt: observedAt,
            threads: [.init(
                id: threadID,
                sessionID: .init(rawValue: "phase115-reserved-session"),
                title: "Projected while first send is pending",
                source: .appServer,
                status: .idle,
                createdAt: observedAt,
                updatedAt: observedAt,
                turnsAreAuthoritative: true,
                turns: []
            )],
            threadFreshness: .live
        )))
        let second = await harness.runtime.execute(
            .followUp(threadID: threadID, text: "Second", draftRevision: 2),
            selectionGeneration: 0
        )
        await gate.release()

        suite.checkEqual(second.outcome, .duplicateSuppressed, "a different draft cannot bypass an in-flight empty-thread lease through normal projected authority")
        suite.checkEqual((await first.value).outcome, .accepted, "the reserved first composer send retains its lease")
        suite.checkEqual(await connection.requestMethods(), ["thread/start", "turn/start"], "concurrent drafts produce exactly one first-turn send")
    }

    private static func locksEmptyThreadLeaseAfterMalformedAcknowledgement(
        into suite: inout TestSuite
    ) async {
        let threadID = AppServerThreadID(rawValue: "phase115-malformed-empty-thread")
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(121),
            requestActions: [
                .success(method: "thread/start", result: threadStartResult(threadID)),
                .success(method: "turn/start", result: .object([:])),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 121, status: .idle)
        _ = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "",
            modelID: "",
            model: "",
            draftRevision: 1_154
        ))
        let intent = AppServerControlIntent.followUp(
            threadID: threadID,
            text: "Possibly accepted",
            draftRevision: 1
        )
        let malformed = await harness.runtime.execute(intent, selectionGeneration: 0)
        let retry = await harness.runtime.execute(intent, selectionGeneration: 0)

        suite.checkEqual(malformed.outcome, .acknowledgementUncertain, "malformed first-turn acknowledgement fails uncertain")
        suite.checkEqual(retry.outcome, .acknowledgementUncertain, "unchanged first-turn draft remains locked")
        suite.checkEqual(await connection.requestMethods(), ["thread/start", "turn/start"], "malformed acknowledgement can never resend the first turn")
    }

    private static func failsClosedWhenEmptyThreadUncertaintyLedgerOverflows(
        into suite: inout TestSuite
    ) async {
        let connection = Phase9ScriptedControlConnection(identity: wireIdentity(122))
        let harness = await makeHarness(connection: connection, generation: 122, status: .idle)
        for index in 0...64 {
            await harness.runtime.recordUncertainCreatedThreadIntentForTesting(
                threadID: .init(rawValue: "overflow-thread-\(index)"),
                draftRevision: UInt64(index)
            )
        }

        let oldFollowUp = await harness.runtime.execute(
            .followUp(threadID: threadID, text: "Never resend", draftRevision: 1),
            selectionGeneration: 0
        )
        let unrelatedInterrupt = await harness.runtime.execute(
            .interrupt(threadID: threadID, expectedTurnID: turnID),
            selectionGeneration: 0
        )
        suite.checkEqual(oldFollowUp.outcome, .acknowledgementUncertain, "overflow fails every follow-up closed instead of forgetting an old uncertainty")
        suite.checkEqual(unrelatedInterrupt.outcome, .stalePrecondition, "overflow lock does not disable unrelated non-follow-up controls")
        suite.checkEqual(await connection.requestMethods(), [], "overflow rejection sends no consequential request")

        let replacementConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(123),
            requestActions: [
                .success(
                    method: "turn/start",
                    result: turnStartResult(.init(rawValue: "post-overflow-turn"))
                ),
            ]
        )
        let replacement = await makeCoordinator(generation: 123, status: .idle)
        await harness.runtime.attach(
            connection: replacementConnection,
            wireIdentity: wireIdentity(123),
            domainConnection: replacement.identity,
            coordinator: replacement.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        let afterReconnect = await harness.runtime.execute(
            .followUp(threadID: threadID, text: "Fresh session", draftRevision: 1),
            selectionGeneration: 0
        )
        suite.checkEqual(afterReconnect.outcome, .accepted, "new session resets the overflow lock")
        suite.checkEqual(await replacementConnection.requestMethods(), ["turn/start"], "post-reconnect follow-up uses normal current authority")
    }

    private static func blocksUnchangedNewThreadAfterUncertainAcknowledgement(
        into suite: inout TestSuite
    ) async {
        let createdThread = AppServerThreadID(rawValue: "phase92-uncertain-thread")
        let firstConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(22),
            requestActions: [
                .success(method: "model/list", result: modelListResult()),
                .success(method: "thread/start", result: threadStartResult(createdThread)),
                .failure(method: "turn/start", error: .timedOut(.request)),
            ]
        )
        let harness = await makeHarness(connection: firstConnection, generation: 22, status: .idle)
        _ = await harness.runtime.loadNewThreadModelCatalog()
        let intent = AppServerNewThreadIntent(
            workingDirectory: "/tmp",
            initialPrompt: "Possibly accepted",
            modelID: testModelID,
            model: testModel,
            draftRevision: 902
        )
        let timedOut = await harness.runtime.executeNewThread(intent)
        let unchanged = await harness.runtime.executeNewThread(intent)

        suite.checkEqual(timedOut.outcome, .acknowledgementTimedOut, "uncertain initial-turn acknowledgement preserves the attempt")
        suite.checkEqual(timedOut.stage, .initialTurn, "partial failure identifies the exact transaction stage")
        suite.checkEqual(timedOut.createdThreadID, createdThread, "partial failure retains the exact allocated thread")
        suite.checkEqual(unchanged.outcome, .acknowledgementUncertain, "unchanged New Chat is refused after uncertainty")
        suite.checkEqual(
            await firstConnection.requestMethods(),
            ["model/list", "thread/start", "turn/start"],
            "unchanged retry sends neither another thread nor another first turn"
        )

        let editedThread = AppServerThreadID(rawValue: "phase92-edited-thread")
        let editedTurn = AppServerTurnID(rawValue: "phase92-edited-turn")
        let replacementConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(23),
            requestActions: [
                .success(method: "model/list", result: modelListResult()),
                .success(method: "thread/start", result: threadStartResult(editedThread)),
                .success(method: "turn/start", result: turnStartResult(editedTurn)),
            ]
        )
        let replacement = await makeCoordinator(generation: 23, status: .idle)
        await harness.runtime.attach(
            connection: replacementConnection,
            wireIdentity: wireIdentity(23),
            domainConnection: replacement.identity,
            coordinator: replacement.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        _ = await harness.runtime.loadNewThreadModelCatalog()
        let stillBlocked = await harness.runtime.executeNewThread(intent)
        let edited = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Explicitly edited intent",
            modelID: testModelID,
            model: testModel,
            draftRevision: 903
        ))
        suite.checkEqual(stillBlocked.outcome, .acknowledgementUncertain, "reconnect never unlocks the unchanged consequential attempt")
        suite.checkEqual(edited.outcome, .accepted, "an edited draft revision is a distinct explicit New Chat intent")
        suite.checkEqual(await replacementConnection.requestMethods(), ["model/list", "thread/start", "turn/start"], "only the edited intent reaches the replacement connection after catalog load")
    }

    private static func refusesMalformedThreadStartWithoutSendingATurn(
        into suite: inout TestSuite
    ) async {
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(24),
            requestActions: [
                .success(method: "model/list", result: modelListResult()),
                .success(method: "thread/start", result: .object(["thread": .object([:])])),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 24, status: .idle)
        _ = await harness.runtime.loadNewThreadModelCatalog()
        let result = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Do not retarget",
            modelID: testModelID,
            model: testModel,
            draftRevision: 904
        ))
        suite.checkEqual(result.outcome, .acknowledgementUncertain, "malformed thread/start acknowledgement is treated as consequential uncertainty")
        suite.checkEqual(await connection.requestMethods(), ["model/list", "thread/start"], "Conn never sends a first turn without an exact returned thread ID")
        let unchanged = await harness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Do not retarget",
            modelID: testModelID,
            model: testModel,
            draftRevision: 904
        ))
        suite.checkEqual(unchanged.outcome, .acknowledgementUncertain, "malformed thread acknowledgement locks the unchanged draft")
        suite.checkEqual(await connection.requestMethods(), ["model/list", "thread/start"], "malformed acknowledgement is never retried")

        let transportConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(25),
            requestActions: [
                .success(method: "model/list", result: modelListResult()),
                .failure(method: "thread/start", error: .transportFailure(.request)),
            ]
        )
        let transportHarness = await makeHarness(
            connection: transportConnection,
            generation: 25,
            status: .idle
        )
        _ = await transportHarness.runtime.loadNewThreadModelCatalog()
        let transportIntent = AppServerNewThreadIntent(
            workingDirectory: "/tmp",
            initialPrompt: "Transport uncertainty",
            modelID: testModelID,
            model: testModel,
            draftRevision: 905
        )
        let transportFailure = await transportHarness.runtime.executeNewThread(transportIntent)
        let transportRetry = await transportHarness.runtime.executeNewThread(transportIntent)
        suite.checkEqual(transportFailure.outcome, .acknowledgementUncertain, "post-send transport failure is acknowledgement-uncertain")
        suite.checkEqual(transportRetry.outcome, .acknowledgementUncertain, "transport uncertainty locks the unchanged revision")
        suite.checkEqual(await transportConnection.requestMethods(), ["model/list", "thread/start"], "transport uncertainty sends thread/start only once")

        let oversizedConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(26),
            requestActions: [
                .success(method: "model/list", result: modelListResult()),
                .success(
                    method: "thread/start",
                    result: threadStartResult(.init(rawValue: String(repeating: "x", count: 513)))
                ),
            ]
        )
        let oversizedHarness = await makeHarness(
            connection: oversizedConnection,
            generation: 26,
            status: .idle
        )
        _ = await oversizedHarness.runtime.loadNewThreadModelCatalog()
        let oversized = await oversizedHarness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Never echo an oversized ID",
            modelID: testModelID,
            model: testModel,
            draftRevision: 906
        ))
        suite.checkEqual(oversized.outcome, .acknowledgementUncertain, "over-bound returned thread identity is rejected as uncertain")
        suite.checkEqual(await oversizedConnection.requestMethods(), ["model/list", "thread/start"], "over-bound thread identity is never echoed into turn/start")

        let oversizedTurnConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(27),
            requestActions: [
                .success(method: "model/list", result: modelListResult()),
                .success(
                    method: "thread/start",
                    result: threadStartResult(.init(rawValue: "phase92-bounded-thread"))
                ),
                .success(
                    method: "turn/start",
                    result: turnStartResult(.init(rawValue: String(repeating: "t", count: 513)))
                ),
            ]
        )
        let oversizedTurnHarness = await makeHarness(
            connection: oversizedTurnConnection,
            generation: 27,
            status: .idle
        )
        _ = await oversizedTurnHarness.runtime.loadNewThreadModelCatalog()
        let oversizedTurn = await oversizedTurnHarness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Reject oversized turn identity",
            modelID: testModelID,
            model: testModel,
            draftRevision: 907
        ))
        let oversizedTurnRetry = await oversizedTurnHarness.runtime.executeNewThread(.init(
            workingDirectory: "/tmp",
            initialPrompt: "Reject oversized turn identity",
            modelID: testModelID,
            model: testModel,
            draftRevision: 907
        ))
        let oversizedTurnAvailability = await oversizedTurnHarness.runtime.availability()
        suite.checkEqual(oversizedTurn.outcome, .acknowledgementUncertain, "over-bound returned turn identity is acknowledgement-uncertain")
        suite.checkEqual(oversizedTurnRetry.outcome, .acknowledgementUncertain, "over-bound turn identity locks the unchanged revision")
        suite.checkEqual(
            await oversizedTurnConnection.requestMethods(),
            ["model/list", "thread/start", "turn/start"],
            "over-bound turn acknowledgement is never retried"
        )
        suite.check(
            oversizedTurnAvailability.responseAuthoritativeTurns.isEmpty,
            "over-bound turn identity never enters response authority"
        )
    }

    private static func routesAcknowledgedCompletionToCapturedThreadAfterSelectionChange(
        into suite: inout TestSuite
    ) async {
        let gate = Phase9RuntimeGate()
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(1),
            requestActions: [.blocked(
                method: "turn/start",
                gate: gate,
                result: turnStartResult(turnID)
            )]
        )
        let harness = await makeHarness(connection: connection, generation: 1, status: .idle)
        await harness.runtime.updateSelectionGeneration(41)

        let execution = Task {
            await harness.runtime.execute(
                .followUp(threadID: threadID, text: "selection", draftRevision: 401),
                selectionGeneration: 41
            )
        }
        await gate.waitUntilEntered()
        await harness.runtime.updateSelectionGeneration(42)
        await gate.release()
        let result = await execution.value

        suite.checkEqual(
            result,
            .init(outcome: .accepted, acceptedTurnID: turnID, draftRevision: 401),
            "selection change does not suppress a late acknowledgement for its captured thread"
        )
        suite.checkEqual(await connection.requestMethods(), ["turn/start"], "late acknowledgement is never retargeted or retried")
        let followUpCalls = await connection.requestCalls()
        suite.check(
            followUpCalls.first?.params?.objectValue?["model"] == nil,
            "existing-chat follow-up inherits its thread model and sends no override"
        )
    }

    private static func appliesOnlyAnExplicitCataloguedFollowUpModelOverride(
        into suite: inout TestSuite
    ) async {
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(121),
            requestActions: [
                .success(method: "model/list", result: modelListResult()),
                .success(method: "turn/start", result: turnStartResult(turnID)),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 121, status: .idle)
        let catalog = await harness.runtime.loadNewThreadModelCatalog()
        suite.checkEqual(catalog.outcome, .available, "follow-up model picker uses the current catalog authority")

        let result = await harness.runtime.execute(
            .followUp(
                threadID: threadID,
                text: "Use the selected model",
                model: testModel,
                draftRevision: 1_210
            ),
            selectionGeneration: 0
        )
        suite.checkEqual(result.outcome, .accepted, "catalogued model override is accepted for an idle follow-up")
        let calls = await connection.requestCalls()
        suite.checkEqual(
            calls.last?.params?.objectValue?["model"]?.stringValue,
            testModel,
            "explicit picker choice is sent as the turn/start model override"
        )

        let staleConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(122),
            requestActions: [.success(method: "turn/start", result: turnStartResult(turnID))]
        )
        let staleHarness = await makeHarness(
            connection: staleConnection,
            generation: 122,
            status: .idle
        )
        let stale = await staleHarness.runtime.execute(
            .followUp(
                threadID: threadID,
                text: "Do not trust a stale picker",
                model: testModel,
                draftRevision: 1_220
            ),
            selectionGeneration: 0
        )
        suite.checkEqual(stale.outcome, .stalePrecondition, "uncatalogued follow-up model fails closed")
        suite.checkEqual(
            await staleConnection.requestMethods(),
            [],
            "uncatalogued follow-up model sends no consequential turn/start"
        )
    }

    private static func invalidatesCapturedIdentityOnReconnect(
        into suite: inout TestSuite
    ) async {
        let gate = Phase9RuntimeGate()
        let oldConnection = Phase9ScriptedControlConnection(
            identity: wireIdentity(2),
            requestActions: [.blocked(
                method: "turn/start",
                gate: gate,
                result: turnStartResult(turnID)
            )]
        )
        let harness = await makeHarness(connection: oldConnection, generation: 2, status: .idle)
        await harness.runtime.updateSelectionGeneration(51)
        let execution = Task {
            await harness.runtime.execute(
                .followUp(threadID: threadID, text: "reconnect", draftRevision: 501),
                selectionGeneration: 51
            )
        }
        await gate.waitUntilEntered()

        let replacementConnection = Phase9ScriptedControlConnection(identity: wireIdentity(3))
        let replacement = await makeCoordinator(generation: 3, status: .idle)
        await harness.runtime.attach(
            connection: replacementConnection,
            wireIdentity: wireIdentity(3),
            domainConnection: replacement.identity,
            coordinator: replacement.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        await gate.release()
        let result = await execution.value

        suite.checkEqual(
            result,
            .init(outcome: .connectionInvalidated, draftRevision: 501),
            "reconnect invalidates the old in-flight action result"
        )
        suite.checkEqual(await oldConnection.requestMethods(), ["turn/start"], "old generation is never retried")
        suite.checkEqual(await replacementConnection.requestMethods(), [], "old action never retargets the replacement connection")
    }

    private static func preservesDraftRevisionWhenAcknowledgementExpires(
        into suite: inout TestSuite
    ) async {
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(4),
            requestActions: [.failure(
                method: "turn/start",
                error: .timedOut(.request)
            )]
        )
        let configuration = AppServerThreadControlConfiguration(
            requestAcknowledgementTimeout: .milliseconds(17)
        )
        let harness = await makeHarness(
            connection: connection,
            generation: 4,
            status: .idle,
            configuration: configuration
        )
        let result = await harness.runtime.execute(
            .followUp(threadID: threadID, text: "keep this draft", draftRevision: 601),
            selectionGeneration: 0
        )

        suite.checkEqual(
            result,
            .init(outcome: .acknowledgementTimedOut, draftRevision: 601),
            "acknowledgement expiry preserves the exact draft revision in the outcome"
        )
        suite.checkEqual(
            await connection.requestCalls().first?.timeout,
            .milliseconds(17),
            "action send receives its per-request acknowledgement deadline"
        )
    }

    private static func coolsDownTimedOutDraftUntilBoundedReconciliation(
        into suite: inout TestSuite
    ) async {
        let editedTurnID = AppServerTurnID(rawValue: "phase9-edited-turn")
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(9),
            requestActions: [
                .failure(method: "turn/start", error: .timedOut(.request)),
                .success(method: "thread/read", result: threadReadResult([])),
                .success(method: "turn/start", result: turnStartResult(editedTurnID)),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 9, status: .idle)
        let unchanged = AppServerControlIntent.followUp(
            threadID: threadID,
            text: "possibly accepted late",
            draftRevision: 611
        )

        let timedOut = await harness.runtime.execute(unchanged, selectionGeneration: 0)
        let refused = await harness.runtime.execute(unchanged, selectionGeneration: 0)
        let edited = await harness.runtime.execute(
            .followUp(
                threadID: threadID,
                text: "edited after timeout",
                draftRevision: 612
            ),
            selectionGeneration: 0
        )

        suite.checkEqual(timedOut.outcome, .acknowledgementTimedOut, "first send records acknowledgement expiry")
        suite.checkEqual(
            refused,
            .init(outcome: .acknowledgementUncertain, draftRevision: 611),
            "unchanged timed-out draft is refused while one bounded reconciliation closes the duplicate window"
        )
        suite.checkEqual(edited.outcome, .accepted, "an edited draft revision is a new intent and remains sendable")
        suite.checkEqual(
            await connection.requestMethods(),
            ["turn/start", "thread/read", "turn/start"],
            "cooldown reconciles once and never resends the unchanged draft"
        )
    }

    private static func closesTimedOutDraftCooldownFromProjectionFacts(
        into suite: inout TestSuite
    ) async throws {
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(12),
            requestActions: [
                .failure(method: "turn/start", error: .timedOut(.request)),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 12, status: .idle)
        let intent = AppServerControlIntent.followUp(
            threadID: threadID,
            text: "projection catches late acceptance",
            draftRevision: 621
        )
        _ = await harness.runtime.execute(intent, selectionGeneration: 0)
        try await apply(harness.coordinator, .delta(.init(
            cursor: cursor(harness.identity, sequence: 1),
            observedAt: observedAt.addingTimeInterval(1),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .inProgress, startedAt: observedAt)
            )
        )))

        let refused = await harness.runtime.execute(intent, selectionGeneration: 0)
        let ordinaryPreflight = await harness.runtime.execute(intent, selectionGeneration: 0)

        suite.checkEqual(refused.outcome, .acknowledgementUncertain, "projected turn facts refuse the first unchanged resend and close its cooldown")
        suite.checkEqual(ordinaryPreflight.outcome, .stalePrecondition, "after projection confirmation, ordinary active-turn preflight governs later attempts")
        suite.checkEqual(await connection.requestMethods(), ["turn/start"], "projection confirmation needs no reconcile read and never duplicates turn/start")
    }

    private static func keepsCooldownWhenReconcileDoesNotConfirmTheExactThread(
        into suite: inout TestSuite
    ) async {
        let acceptedTurn = AppServerTurnID(rawValue: "phase9-after-confirmed-read")
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(15),
            requestActions: [
                .failure(method: "turn/start", error: .timedOut(.request)),
                .success(
                    method: "thread/read",
                    result: threadReadResult(
                        [],
                        threadID: .init(rawValue: "wrong-thread")
                    )
                ),
                .success(method: "thread/read", result: threadReadResult([])),
                .success(method: "turn/start", result: turnStartResult(acceptedTurn)),
            ]
        )
        let harness = await makeHarness(connection: connection, generation: 15, status: .idle)
        let intent = AppServerControlIntent.followUp(
            threadID: threadID,
            text: "wait for exact reconcile",
            draftRevision: 631
        )
        _ = await harness.runtime.execute(intent, selectionGeneration: 0)

        let wrongThread = await harness.runtime.execute(intent, selectionGeneration: 0)
        let exactThread = await harness.runtime.execute(intent, selectionGeneration: 0)
        let accepted = await harness.runtime.execute(intent, selectionGeneration: 0)

        suite.checkEqual(wrongThread.outcome, .acknowledgementUncertain, "wrong-thread read cannot close the cooldown")
        suite.checkEqual(exactThread.outcome, .acknowledgementUncertain, "exact structurally valid thread/read closes the cooldown but still refuses that click")
        suite.checkEqual(accepted.outcome, .accepted, "ordinary preflight resumes only after exact reconciliation")
        suite.checkEqual(
            await connection.requestMethods(),
            ["turn/start", "thread/read", "thread/read", "turn/start"],
            "malformed or wrong-thread reconciliation never resends the unchanged draft"
        )
    }

    private static func suppressesDuplicateIntentWhileOriginalIsPending(
        into suite: inout TestSuite
    ) async {
        let gate = Phase9RuntimeGate()
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(5),
            requestActions: [.blocked(
                method: "turn/start",
                gate: gate,
                result: turnStartResult(turnID)
            )]
        )
        let harness = await makeHarness(connection: connection, generation: 5, status: .idle)
        let intent = AppServerControlIntent.followUp(
            threadID: threadID,
            text: "only once",
            draftRevision: 701
        )
        let first = Task { await harness.runtime.execute(intent, selectionGeneration: 0) }
        await gate.waitUntilEntered()
        let duplicate = await harness.runtime.execute(intent, selectionGeneration: 0)
        await gate.release()
        let accepted = await first.value

        suite.checkEqual(
            duplicate,
            .init(outcome: .duplicateSuppressed, draftRevision: 701),
            "duplicate intent is suppressed while its exact key is pending"
        )
        suite.checkEqual(accepted.outcome, .accepted, "the original intent still receives its acknowledgement")
        suite.checkEqual(await connection.requestMethods(), ["turn/start"], "duplicate suppression permits one send")
    }

    private static func reconcilesOnlyTheExactRequestResolvedElsewhere(
        into suite: inout TestSuite
    ) async throws {
        let coordinatorState = await makeCoordinator(generation: 6, status: .idle)
        let exactRequestID = AppServerRequestID.integer(801)
        let otherRequestID = AppServerRequestID.integer(802)
        let resolveExact = AppServerProjectionInput.delta(.init(
            cursor: cursor(coordinatorState.identity, sequence: 4),
            observedAt: observedAt.addingTimeInterval(4),
            delta: .requestResolved(threadID: threadID, requestID: exactRequestID)
        ))
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(6),
            requestActions: [.success(method: "turn/start", result: turnStartResult(turnID))],
            respondActions: [.applyThenFail(
                coordinator: coordinatorState.coordinator,
                input: resolveExact,
                error: .unknownServerRequest(.integer(801))
            )]
        )
        let runtime = AppServerThreadControlRuntime()
        await runtime.attach(
            connection: connection,
            wireIdentity: wireIdentity(6),
            domainConnection: coordinatorState.identity,
            coordinator: coordinatorState.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        let started = await runtime.execute(
            .followUp(threadID: threadID, text: "originate", draftRevision: 801),
            selectionGeneration: 0
        )
        suite.checkEqual(started.outcome, .accepted, "fixture establishes Conn-originated response authority")

        try await apply(coordinatorState.coordinator, .delta(.init(
            cursor: cursor(coordinatorState.identity, sequence: 1),
            observedAt: observedAt.addingTimeInterval(1),
            delta: .turnUpsert(
                threadID: threadID,
                turn: .init(id: turnID, status: .inProgress, startedAt: observedAt)
            )
        )))
        try await openApproval(
            exactRequestID,
            sequence: 2,
            coordinator: coordinatorState.coordinator,
            identity: coordinatorState.identity
        )
        try await openApproval(
            otherRequestID,
            sequence: 3,
            coordinator: coordinatorState.coordinator,
            identity: coordinatorState.identity
        )

        let scoped = AppServerScopedRequestID(
            connection: coordinatorState.identity,
            requestID: exactRequestID
        )
        let result = await runtime.execute(
            .decide(
                request: scoped,
                threadID: threadID,
                turnID: turnID,
                choice: .deny
            ),
            selectionGeneration: 0
        )
        let remaining = await coordinatorState.coordinator.snapshot().attentionRequests

        suite.checkEqual(result.outcome, .resolvedElsewhere, "unknown exact request reconciles as resolved elsewhere")
        suite.check(
            remaining.contains { $0.id.requestID == otherRequestID }
                && !remaining.contains { $0.id.requestID == exactRequestID },
            "resolved-elsewhere reconciliation is correlated to the exact request and preserves peers"
        )
        suite.checkEqual(await connection.respondedRequestIDs(), [.integer(801)], "one response uses the exact wire request ID")
    }

    private static func reconcilesStaleExpectedTurnWithoutRetry(
        into suite: inout TestSuite
    ) async {
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(7),
            requestActions: [
                .failure(method: "turn/steer", error: .server(method: "turn/steer", code: -32_601)),
                .success(method: "thread/read", result: threadReadResult([
                    (AppServerTurnID(rawValue: "replacement-turn"), "inProgress"),
                ])),
            ]
        )
        let harness = await makeHarness(
            connection: connection,
            generation: 7,
            status: .active([]),
            activeTurn: turnID
        )
        let result = await harness.runtime.execute(
            .steer(
                threadID: threadID,
                expectedTurnID: turnID,
                text: "stale steer",
                draftRevision: 901
            ),
            selectionGeneration: 0
        )

        suite.checkEqual(
            result,
            .init(outcome: .stalePrecondition, draftRevision: 901),
            "stale expectedTurnId reconciles through authoritative thread/read"
        )
        suite.checkEqual(
            await connection.requestMethods(),
            ["turn/steer", "thread/read"],
            "stale steer performs one send and one reconcile read with no blind retry"
        )
    }

    private static func confirmsInterruptTerminalStateThroughThreadRead(
        into suite: inout TestSuite
    ) async {
        let connection = Phase9ScriptedControlConnection(
            identity: wireIdentity(8),
            requestActions: [
                .success(method: "turn/interrupt", result: .object([:])),
                .success(method: "thread/read", result: threadReadResult([(turnID, "interrupted")])),
            ]
        )
        let harness = await makeHarness(
            connection: connection,
            generation: 8,
            status: .active([]),
            activeTurn: turnID
        )
        let result = await harness.runtime.execute(
            .interrupt(threadID: threadID, expectedTurnID: turnID),
            selectionGeneration: 0
        )

        suite.checkEqual(
            result,
            .init(outcome: .accepted, acceptedTurnID: turnID),
            "interrupt is accepted only after thread/read confirms a terminal turn"
        )
        suite.checkEqual(
            await connection.requestMethods(),
            ["turn/interrupt", "thread/read"],
            "interrupt acknowledgement is followed by authoritative terminal confirmation"
        )
        let calls = await connection.requestCalls()
        suite.checkEqual(calls.first?.timeout, .seconds(10), "interrupt send uses action acknowledgement timeout")
        suite.checkEqual(calls.last?.timeout, .seconds(5), "interrupt thread/read uses bounded reconciliation timeout")
    }

    private static func routesInputsAndPrunesResolvedQuestionAnswers(
        into suite: inout TestSuite
    ) async throws {
        let firstRequest = AppServerScopedRequestID(
            connection: domainIdentity(10),
            requestID: .string("secret-first")
        )
        let secondRequest = AppServerScopedRequestID(
            connection: domainIdentity(10),
            requestID: .string("secret-second")
        )
        let firstThread = AppServerThreadID(rawValue: "phase9-first-thread")
        let secondThread = AppServerThreadID(rawValue: "phase9-second-thread")
        var state = AppServerThreadControlPresentationState()
        state.updateDraft("send from first", threadID: firstThread.rawValue)
        state.updateQuestionAnswer("first secret", request: firstRequest, questionID: "q1")
        state.updateQuestionAnswer("second secret", request: secondRequest, questionID: "q2")

        state.applyCompletion(
            intent: .interrupt(threadID: secondThread, expectedTurnID: turnID),
            result: .init(outcome: .accepted, acceptedTurnID: turnID),
            error: nil,
            notice: "Stop acknowledged."
        )
        suite.checkEqual(
            state.questionAnswer(request: firstRequest, questionID: "q1"),
            "first secret",
            "accepted interrupt preserves half-typed answers for another request"
        )

        state.applyCompletion(
            intent: .followUp(
                threadID: firstThread,
                text: "send from first",
                draftRevision: state.draft(for: firstThread.rawValue).revision
            ),
            result: .init(
                outcome: .accepted,
                acceptedTurnID: AppServerTurnID(rawValue: "late-first-turn"),
                draftRevision: state.draft(for: firstThread.rawValue).revision
            ),
            error: nil,
            notice: "App Server acknowledged the action."
        )
        suite.checkEqual(state.draft(for: firstThread.rawValue).text, "", "late acceptance clears only its captured exact draft revision")
        suite.checkEqual(
            state.outcome(for: firstThread.rawValue)?.notice,
            "App Server acknowledged the action.",
            "completion copy is retained on its captured thread for a later revisit"
        )

        state.applyCompletion(
            intent: .answer(
                request: firstRequest,
                threadID: firstThread,
                turnID: nil,
                answers: .init(valuesByQuestionID: ["q1": ["first secret"]])
            ),
            result: .init(outcome: .accepted),
            error: nil,
            notice: "Answer acknowledged."
        )
        suite.checkEqual(state.questionAnswer(request: firstRequest, questionID: "q1"), "", "accepted answer clears its own scoped request")
        suite.checkEqual(state.questionAnswer(request: secondRequest, questionID: "q2"), "second secret", "answer completion preserves peer request values")

        let resolutionState = await makeCoordinator(generation: 13, status: .idle)
        let resolvedRequestID = AppServerRequestID.string("resolved-secret")
        try await openQuestion(
            resolvedRequestID,
            sequence: 1,
            coordinator: resolutionState.coordinator,
            identity: resolutionState.identity
        )
        let resolvedRequest = AppServerScopedRequestID(
            connection: resolutionState.identity,
            requestID: resolvedRequestID
        )
        state.reconcile(with: await resolutionState.coordinator.snapshot())
        state.updateQuestionAnswer("resolved secret", request: resolvedRequest, questionID: "secret")
        try await apply(resolutionState.coordinator, .delta(.init(
            cursor: cursor(resolutionState.identity, sequence: 2),
            observedAt: observedAt.addingTimeInterval(2),
            delta: .requestResolved(threadID: threadID, requestID: resolvedRequestID)
        )))
        let afterResolution = await resolutionState.coordinator.snapshot()
        state.reconcile(with: afterResolution)
        suite.check(afterResolution.threads.contains { $0.id == threadID }, "resolution fixture retains the owning thread")
        suite.checkEqual(state.questionAnswer(request: resolvedRequest, questionID: "secret"), "", "projection request resolution prunes its typed secret while the thread remains")

        let removedRequestID = AppServerRequestID.string("removed-thread-secret")
        try await openQuestion(
            removedRequestID,
            sequence: 3,
            coordinator: resolutionState.coordinator,
            identity: resolutionState.identity
        )
        let removedRequest = AppServerScopedRequestID(
            connection: resolutionState.identity,
            requestID: removedRequestID
        )
        state.reconcile(with: await resolutionState.coordinator.snapshot())
        state.updateQuestionAnswer("removed secret", request: removedRequest, questionID: "secret")
        try await apply(resolutionState.coordinator, .delta(.init(
            cursor: cursor(resolutionState.identity, sequence: 4),
            observedAt: observedAt.addingTimeInterval(4),
            delta: .threadRemoved(threadID)
        )))
        let afterRemoval = await resolutionState.coordinator.snapshot()
        state.reconcile(with: afterRemoval)
        suite.check(!afterRemoval.threads.contains { $0.id == threadID }, "thread-removal fixture removes the owning thread")
        suite.checkEqual(state.questionAnswer(request: removedRequest, questionID: "secret"), "", "thread removal prunes its remaining typed secret values")

        let generationFourteen = await makeCoordinator(generation: 14, status: .idle)
        let generationRequestID = AppServerRequestID.string("generation-secret")
        try await openQuestion(
            generationRequestID,
            sequence: 1,
            coordinator: generationFourteen.coordinator,
            identity: generationFourteen.identity
        )
        let generationRequest = AppServerScopedRequestID(
            connection: generationFourteen.identity,
            requestID: .string("generation-secret")
        )
        state.updateQuestionAnswer("generation secret", request: generationRequest, questionID: "secret")
        let generationSnapshot = await generationFourteen.coordinator.snapshot()
        suite.check(generationSnapshot.attentionRequests.contains { $0.id == generationRequest }, "generation fixture keeps the exact request live")
        state.reconcile(with: generationSnapshot)
        suite.checkEqual(state.questionAnswer(request: generationRequest, questionID: "secret"), "", "connection generation change prunes secrets even when the same scoped request is live")
    }

    private struct Harness {
        let runtime: AppServerThreadControlRuntime
        let coordinator: AppServerDomainCoordinator
        let identity: AppServerConnectionIdentity
    }

    private struct CoordinatorState {
        let coordinator: AppServerDomainCoordinator
        let identity: AppServerConnectionIdentity
    }

    private static func makeHarness(
        connection: Phase9ScriptedControlConnection,
        generation: UInt64,
        status: AppServerThreadStatus,
        activeTurn: AppServerTurnID? = nil,
        configuration: AppServerThreadControlConfiguration = .init(),
        newThreadPreCommitProbe: (@Sendable () async -> Void)? = nil
    ) async -> Harness {
        let state = await makeCoordinator(
            generation: generation,
            status: status,
            activeTurn: activeTurn
        )
        let runtime: AppServerThreadControlRuntime
        if let newThreadPreCommitProbe {
            runtime = AppServerThreadControlRuntime(
                configuration: configuration,
                newThreadPreCommitProbe: newThreadPreCommitProbe
            )
        } else {
            runtime = AppServerThreadControlRuntime(configuration: configuration)
        }
        await runtime.attach(
            connection: connection,
            wireIdentity: wireIdentity(generation),
            domainConnection: state.identity,
            coordinator: state.coordinator,
            serverVersion: .v0_144_6,
            mode: .stable
        )
        return .init(runtime: runtime, coordinator: state.coordinator, identity: state.identity)
    }

    private static func makeCoordinator(
        generation: UInt64,
        status: AppServerThreadStatus,
        activeTurn: AppServerTurnID? = nil
    ) async -> CoordinatorState {
        let identity = domainIdentity(generation)
        let store = AppServerProjectionStore()
        let coordinator = AppServerDomainCoordinator(domain: store)
        _ = try? await coordinator.applyAndPersist(.connectionActivated(
            identity: identity,
            source: .managedDaemon,
            featureSupport: .init(features: [
                .monitor, .createThread, .followUp, .steer, .stopTurn, .resolveApproval, .answer,
            ])
        ))
        let turns = activeTurn.map {
            [AppServerTurnInput(id: $0, status: .inProgress, startedAt: observedAt)]
        } ?? []
        _ = try? await coordinator.applyAndPersist(.snapshot(.init(
            cursor: cursor(identity, sequence: 0),
            observedAt: observedAt,
            threads: [.init(
                id: threadID,
                sessionID: .init(rawValue: "phase9-runtime-session"),
                title: "Phase 9 runtime",
                source: .appServer,
                status: status,
                createdAt: observedAt,
                updatedAt: observedAt,
                turnsAreAuthoritative: true,
                turns: turns
            )],
            threadFreshness: .live
        )))
        return .init(coordinator: coordinator, identity: identity)
    }

    private static func openApproval(
        _ requestID: AppServerRequestID,
        sequence: UInt64,
        coordinator: AppServerDomainCoordinator,
        identity: AppServerConnectionIdentity
    ) async throws {
        try await apply(coordinator, .delta(.init(
            cursor: cursor(identity, sequence: sequence),
            observedAt: observedAt.addingTimeInterval(TimeInterval(sequence)),
            delta: .requestOpened(.init(
                requestID: requestID,
                threadID: threadID,
                turnID: turnID,
                itemID: .init(rawValue: "item-\(sequence)"),
                kind: .commandApproval,
                facts: .commandApproval(.init(
                    command: "true",
                    workingDirectory: "/tmp",
                    reason: "runtime test"
                )),
                startedAt: observedAt
            ))
        )))
    }

    private static func openQuestion(
        _ requestID: AppServerRequestID,
        sequence: UInt64,
        coordinator: AppServerDomainCoordinator,
        identity: AppServerConnectionIdentity
    ) async throws {
        try await apply(coordinator, .delta(.init(
            cursor: cursor(identity, sequence: sequence),
            observedAt: observedAt.addingTimeInterval(TimeInterval(sequence)),
            delta: .requestOpened(.init(
                requestID: requestID,
                threadID: threadID,
                turnID: nil,
                itemID: .init(rawValue: "question-\(sequence)"),
                kind: .structuredQuestion,
                facts: .structuredQuestions(.init(
                    questions: [.init(
                        id: "secret",
                        header: "Secret",
                        prompt: "Enter secret",
                        options: nil,
                        permitsOther: true,
                        isSecret: true
                    )],
                    autoResolutionMilliseconds: nil
                )),
                startedAt: observedAt
            ))
        )))
    }

    private static func apply(
        _ coordinator: AppServerDomainCoordinator,
        _ input: AppServerProjectionInput
    ) async throws {
        let result = try await coordinator.applyAndPersist(input)
        guard result == .applied else { throw Phase9RuntimeTestError.projection(result) }
    }

    private static func cursor(
        _ identity: AppServerConnectionIdentity,
        sequence: UInt64
    ) -> AppServerObservationCursor {
        .init(connection: identity, sequence: sequence)
    }

    private static func domainIdentity(_ generation: UInt64) -> AppServerConnectionIdentity {
        .init(
            instanceID: UUID(uuidString: "91000000-0000-4000-8000-\(String(format: "%012llu", generation))")!,
            generation: generation
        )
    }

    private static func wireIdentity(_ generation: UInt64) -> ConnAppServerConnectionIdentity {
        .init(
            instanceID: UUID(uuidString: "92000000-0000-4000-8000-\(String(format: "%012llu", generation))")!,
            generation: generation
        )
    }

    private static func turnStartResult(_ turnID: AppServerTurnID) -> JSONValue {
        .object(["turn": .object(["id": .string(turnID.rawValue)])])
    }

    private static func threadStartResult(_ threadID: AppServerThreadID) -> JSONValue {
        .object(["thread": .object(["id": .string(threadID.rawValue)])])
    }

    private static func modelListResult(
        id: String = testModelID,
        model: String = testModel,
        displayName: String = "Phase 9.2 Model",
        hidden: Bool = false,
        isDefault: Bool = true,
        nextCursor: JSONValue = .null
    ) -> JSONValue {
        modelListPage(
            rows: [modelRow(
                id: id,
                model: model,
                displayName: displayName,
                hidden: hidden,
                isDefault: isDefault
            )],
            nextCursor: nextCursor
        )
    }

    private static func modelRow(
        id: String = testModelID,
        model: String = testModel,
        displayName: String = "Phase 9.2 Model",
        hidden: Bool = false,
        isDefault: Bool = false
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "model": .string(model),
            "displayName": .string(displayName),
            "description": .string("A test-only model row."),
            "hidden": .bool(hidden),
            "isDefault": .bool(isDefault),
            "defaultReasoningEffort": .string("medium"),
            "supportedReasoningEfforts": .array([]),
        ])
    }

    private static func modelListPage(
        rows: [JSONValue],
        nextCursor: JSONValue = .null
    ) -> JSONValue {
        .object([
            "data": .array(rows),
            "nextCursor": nextCursor,
        ])
    }

    private static func threadReadResult(
        _ turns: [(AppServerTurnID, String)],
        threadID projectedThreadID: AppServerThreadID = threadID
    ) -> JSONValue {
        .object(["thread": .object([
            "id": .string(projectedThreadID.rawValue),
            "status": .string(turns.contains { $0.1 == "inProgress" } ? "inProgress" : "idle"),
            "turns": .array(turns.map { turnID, status in
                .object([
                    "id": .string(turnID.rawValue),
                    "status": .string(status),
                ])
            }),
        ])])
    }
}

private actor Phase9RuntimeGate {
    private var entered = false
    private var released = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        enteredContinuations.forEach { $0.resume() }
        enteredContinuations.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseContinuations.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuations.append($0) }
    }

    func release() {
        released = true
        releaseContinuations.forEach { $0.resume() }
        releaseContinuations.removeAll()
    }
}

private actor Phase9ScriptedControlConnection: AppServerThreadControlConnection {
    struct RequestCall: Equatable, Sendable {
        let method: String
        let params: JSONValue?
        let timeout: Duration?
    }

    enum RequestAction: Sendable {
        case success(method: String, result: JSONValue)
        case failure(method: String, error: ConnAppServerConnectionError)
        case blocked(method: String, gate: Phase9RuntimeGate, result: JSONValue)
    }

    enum RespondAction: Sendable {
        case success
        case applyThenFail(
            coordinator: AppServerDomainCoordinator,
            input: AppServerProjectionInput,
            error: ConnAppServerConnectionError
        )
    }

    private let identity: ConnAppServerConnectionIdentity
    private let controlIdentityGate: Phase9RuntimeGate?
    private var requestActions: [RequestAction]
    private var respondActions: [RespondAction]
    private var calls: [RequestCall] = []
    private var responseIDs: [RequestID] = []
    private var sequence: UInt64 = 0

    init(
        identity: ConnAppServerConnectionIdentity,
        requestActions: [RequestAction] = [],
        respondActions: [RespondAction] = [],
        controlIdentityGate: Phase9RuntimeGate? = nil
    ) {
        self.identity = identity
        self.requestActions = requestActions
        self.respondActions = respondActions
        self.controlIdentityGate = controlIdentityGate
    }

    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope {
        calls.append(.init(method: method, params: params, timeout: timeout))
        guard !requestActions.isEmpty else {
            throw ConnAppServerConnectionError.invalidResponse(method: method)
        }
        let action = requestActions.removeFirst()
        let expectedMethod: String
        switch action {
        case let .success(expected, _), let .failure(expected, _), let .blocked(expected, _, _):
            expectedMethod = expected
        }
        guard method == expectedMethod else {
            throw ConnAppServerConnectionError.invalidResponse(method: method)
        }
        switch action {
        case let .success(_, result):
            return envelope(result)
        case let .failure(_, error):
            throw error
        case let .blocked(_, gate, result):
            await gate.enterAndWait()
            return envelope(result)
        }
    }

    func respond(to requestID: RequestID, result: JSONValue) async throws {
        _ = result
        responseIDs.append(requestID)
        guard !respondActions.isEmpty else {
            throw ConnAppServerConnectionError.unknownServerRequest(requestID)
        }
        switch respondActions.removeFirst() {
        case .success:
            return
        case let .applyThenFail(coordinator, input, error):
            _ = try await coordinator.applyAndPersist(input)
            throw error
        }
    }

    func controlIdentity() async -> ConnAppServerConnectionIdentity? {
        if let controlIdentityGate { await controlIdentityGate.enterAndWait() }
        return identity
    }

    func requestCalls() -> [RequestCall] { calls }
    func requestMethods() -> [String] { calls.map(\.method) }
    func respondedRequestIDs() -> [RequestID] { responseIDs }

    private func envelope(_ result: JSONValue) -> ConnAppServerResponseEnvelope {
        sequence += 1
        return .init(connection: identity, sequence: sequence, result: result)
    }
}

private enum Phase9RuntimeTestError: Error {
    case projection(AppServerProjectionApplyResult)
}
