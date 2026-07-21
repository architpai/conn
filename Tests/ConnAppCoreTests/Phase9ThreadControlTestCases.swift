import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase9ThreadControlTestCases {
    private static let observedAt = Date(timeIntervalSince1970: 1_850_000_000)
    private static let connection = AppServerConnectionIdentity(
        instanceID: UUID(uuidString: "90000000-0000-4000-8000-000000000001")!,
        generation: 9
    )

    static func run(into suite: inout TestSuite) async throws {
        try await qualifiesCapabilitiesByExactVersionAndMode(into: &suite)
        try await decodesAndPresentsBoundedRequestFacts(into: &suite)
        try await encodesExactApprovalAndQuestionResponses(into: &suite)
        try await refusesTransformedPermissionSubpaths(into: &suite)
        try await presentsExactPermissionEntriesAndRefusesUnknownKinds(into: &suite)
        try await keepsOverBoundResponseFactsVisibleButUnsupported(into: &suite)
        preservesDraftUnlessExactRevisionIsAcknowledged(into: &suite)
        preservesNewThreadDraftUntilBothStagesAreAcknowledged(into: &suite)
    }

    private static func preservesNewThreadDraftUntilBothStagesAreAcknowledged(
        into suite: inout TestSuite
    ) {
        var draft = AppServerNewThreadDraft(
            workingDirectory: "/tmp",
            initialPrompt: "runtime-only initial prompt",
            selectedModelID: "runtime-only-model",
            revision: 21
        )
        draft.apply(.init(
            outcome: .acknowledgementTimedOut,
            stage: .initialTurn,
            createdThreadID: .init(rawValue: "allocated"),
            draftRevision: 21
        ))
        suite.checkEqual(draft.initialPrompt, "runtime-only initial prompt", "partial New Chat preserves the initial prompt")
        suite.checkEqual(draft.selectedModelID, "runtime-only-model", "partial New Chat preserves the explicit model choice")
        draft.apply(.init(
            outcome: .accepted,
            stage: .initialTurn,
            createdThreadID: .init(rawValue: "created"),
            acceptedTurnID: .init(rawValue: "turn"),
            draftRevision: 20
        ))
        suite.checkEqual(draft.workingDirectory, "/tmp", "superseded New Chat acknowledgement cannot clear its directory")
        draft.apply(.init(
            outcome: .accepted,
            stage: .initialTurn,
            createdThreadID: .init(rawValue: "created"),
            acceptedTurnID: .init(rawValue: "turn"),
            draftRevision: 21
        ))
        suite.checkEqual(draft.workingDirectory, "", "exact two-stage acknowledgement clears the working directory")
        suite.checkEqual(draft.initialPrompt, "", "exact two-stage acknowledgement clears the initial prompt")
        suite.checkEqual(draft.selectedModelID, nil, "exact two-stage acknowledgement clears the model choice")
        suite.checkEqual(draft.revision, 22, "successful clear advances the New Chat draft revision")
    }

    private static func preservesDraftUnlessExactRevisionIsAcknowledged(
        into suite: inout TestSuite
    ) {
        var draft = AppServerControlDraft(text: "runtime-only secret draft", revision: 11)
        draft.apply(.init(outcome: .acknowledgementTimedOut, draftRevision: 11))
        suite.checkEqual(draft.text, "runtime-only secret draft", "deadline expiry preserves draft text")
        draft.apply(.init(outcome: .accepted, draftRevision: 10))
        suite.checkEqual(draft.text, "runtime-only secret draft", "superseded acknowledgement cannot clear a newer draft")
        draft.apply(.init(outcome: .accepted, draftRevision: 11))
        suite.checkEqual(draft.text, "", "exact acknowledged draft revision clears once")
        suite.checkEqual(draft.revision, 12, "clearing advances the runtime-only revision")
    }

    private static func qualifiesCapabilitiesByExactVersionAndMode(
        into suite: inout TestSuite
    ) async throws {
        let clientMethods = ["thread/start", "turn/start", "turn/steer", "turn/interrupt"]
        let responseMethods = [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
            "item/tool/requestUserInput",
        ]
        for version in SupportedAppServerVersion.allCases {
            for mode in [
                AppServerCapabilityMode.stable,
                .experimental([.threadSearch]),
            ] {
                let policy = AppServerCompatibilityPolicy(version: version, mode: mode)
                suite.check(
                    clientMethods.allSatisfy(policy.supports(method:)),
                    "\(version.rawValue) \(mode) supports only reviewed stable turn controls"
                )
                suite.check(
                    responseMethods.allSatisfy(policy.supportsServerResponse(method:)),
                    "\(version.rawValue) \(mode) supports reviewed modern server responses"
                )
                suite.check(
                    !policy.supports(method: "thread/archive")
                        && !policy.supportsServerResponse(method: "future/requestApproval"),
                    "\(version.rawValue) \(mode) does not widen to unreviewed controls"
                )
                do {
                    try policy.requireServerResponseSupport(for: "future/requestApproval")
                    suite.check(false, "unsupported response policy throws")
                } catch let error as ConnAppServerConnectionError {
                    suite.checkEqual(
                        error,
                        .unsupportedMethod(
                            method: "future/requestApproval",
                            version: version.rawValue,
                            experimentalAPIEnabled: false
                        ),
                        "server-response rejection never implies experimental response authority"
                    )
                } catch {
                    suite.check(false, "unsupported response policy uses the public connection error")
                }

                let store = AppServerProjectionStore()
                let adapter = AppServerObservationAdapter()
                _ = await store.apply(adapter.connectionActivated(
                    identity: connection,
                    source: .managedDaemon,
                    serverVersion: version,
                    mode: mode
                ))
                let features = await store.snapshot(at: observedAt).featureSupport.features
                suite.checkEqual(
                    features,
                    [.monitor, .createThread, .followUp, .steer, .stopTurn, .resolveApproval, .answer],
                    "domain capabilities derive from exact client and response method policies"
                )
            }
        }
    }

    private static func decodesAndPresentsBoundedRequestFacts(
        into suite: inout TestSuite
    ) async throws {
        let longCommand = String(repeating: "x", count: 5_000)
        let command = try await projectedRequest(
            method: "item/commandExecution/requestApproval",
            id: .integer(901),
            params: approvalBase().merging([
                "command": .string(longCommand),
                "cwd": .string("/tmp/phase9"),
                "reason": .string("Needs a harmless capability"),
            ]) { _, replacement in replacement }
        )
        guard case let .commandApproval(commandFacts) = command.facts else {
            suite.check(false, "command approval retains typed facts")
            return
        }
        suite.checkEqual(
            commandFacts.command?.utf8.count,
            AppServerObservationAdapter.maximumRequestTextUTF8Bytes,
            "command presentation text is UTF-8 bounded"
        )
        suite.checkEqual(commandFacts.workingDirectory, "/tmp/phase9", "command cwd is exact")
        suite.checkEqual(commandFacts.reason, "Needs a harmless capability", "command reason is exact")

        let questions = try await projectedRequest(
            method: "item/tool/requestUserInput",
            id: .string("question-901"),
            params: [
                "threadId": .string("thread-phase9"),
                "turnId": .string("turn-phase9"),
                "itemId": .string("item-phase9"),
                "autoResolutionMs": .integer(60_000),
                "questions": .array([.object([
                    "id": .string("release"),
                    "header": .string("Release"),
                    "question": .string("Ship this build?"),
                    "options": .array([.object([
                        "label": .string("Ship"),
                        "description": .string("Proceed with the release."),
                    ])]),
                    "isOther": .bool(true),
                    "isSecret": .bool(true),
                ])]),
            ]
        )
        guard case let .structuredQuestions(questionFacts) = questions.facts else {
            suite.check(false, "structured request retains typed questions")
            return
        }
        suite.checkEqual(questionFacts.autoResolutionMilliseconds, 60_000, "auto-resolution is retained")
        suite.checkEqual(questionFacts.questions.first?.id, "release", "question ID is exact")
        suite.checkEqual(questionFacts.questions.first?.header, "Release", "question header is exact")
        suite.checkEqual(questionFacts.questions.first?.prompt, "Ship this build?", "question prompt is exact")
        suite.checkEqual(questionFacts.questions.first?.options?.first?.label, "Ship", "option label is exact")
        suite.check(
            questionFacts.questions.first?.permitsOther == true
                && questionFacts.questions.first?.isSecret == true,
            "other and secret semantics are retained"
        )

        let presentation = try await attentionPresentation(for: questions)
        suite.checkEqual(
            presentation.scopedRequestID,
            questions.id,
            "presentation exposes the exact scoped request correlation"
        )
        suite.checkEqual(presentation.threadID, questions.threadID, "presentation exposes the exact thread")
        suite.checkEqual(presentation.turnID, questions.turnID, "presentation exposes the exact turn")
        suite.checkEqual(presentation.detail, "Ship this build?", "presentation surfaces the exact prompt")
        suite.checkEqual(presentation.questions, questionFacts.questions, "presentation exposes grouped typed questions")
        suite.check(presentation.isResponseShapeSupported, "supported question shape has honest response copy")
    }

    private static func encodesExactApprovalAndQuestionResponses(
        into suite: inout TestSuite
    ) async throws {
        let permissions = try await projectedRequest(
            method: "item/permissions/requestApproval",
            id: .integer(902),
            params: approvalBase().merging([
                "cwd": .string("/tmp/phase9"),
                "reason": .string("Read and network access"),
                "permissions": .object([
                    "fileSystem": .object([
                        "entries": .array([.object([
                            "access": .string("read"),
                            "path": .object([
                                "type": .string("special"),
                                "value": .object([
                                    "kind": .string("project_roots"),
                                    "subpath": .string("Sources"),
                                ]),
                            ]),
                        ])]),
                        "read": .array([.string("/tmp/phase9/README.md")]),
                        "globScanMaxDepth": .integer(4),
                    ]),
                    "network": .object(["enabled": .bool(true)]),
                ]),
            ]) { _, replacement in replacement }
        )
        let approved = try AppServerControlResponseEncoder.approvalResult(
            for: permissions,
            choice: .approve
        )
        suite.checkEqual(
            approved,
            .object([
                "scope": .string("turn"),
                "permissions": .object([
                    "fileSystem": .object([
                        "entries": .array([.object([
                            "access": .string("read"),
                            "path": .object([
                                "type": .string("special"),
                                "value": .object([
                                    "kind": .string("project_roots"),
                                    "subpath": .string("Sources"),
                                ]),
                            ]),
                        ])]),
                        "read": .array([.string("/tmp/phase9/README.md")]),
                        "globScanMaxDepth": .integer(4),
                    ]),
                    "network": .object(["enabled": .bool(true)]),
                ]),
            ]),
            "permission approval reconstructs the exact requested grant with turn scope"
        )
        suite.checkEqual(
            try AppServerControlResponseEncoder.approvalResult(for: permissions, choice: .deny),
            .object([
                "permissions": .object([:]),
                "scope": .string("turn"),
            ]),
            "permission denial grants no permissions"
        )

        let command = try await projectedRequest(
            method: "item/fileChange/requestApproval",
            id: .integer(903),
            params: approvalBase()
        )
        suite.checkEqual(
            try AppServerControlResponseEncoder.approvalResult(for: command, choice: .approveForSession),
            .object(["decision": .string("acceptForSession")]),
            "file approval uses the pinned stable decision spelling"
        )

        let question = try await projectedRequest(
            method: "item/tool/requestUserInput",
            id: .integer(904),
            params: [
                "threadId": .string("thread-phase9"),
                "turnId": .string("turn-phase9"),
                "itemId": .string("item-phase9"),
                "questions": .array([.object([
                    "id": .string("choice"),
                    "header": .string("Choice"),
                    "question": .string("Choose"),
                    "options": .null,
                ])]),
            ]
        )
        suite.checkEqual(
            try AppServerControlResponseEncoder.questionResult(
                for: question,
                answers: .init(valuesByQuestionID: ["choice": ["A"]])
            ),
            .object(["answers": .object([
                "choice": .object(["answers": .array([.string("A")])]),
            ])]),
            "question response preserves exact question correlation"
        )
    }

    private static func keepsOverBoundResponseFactsVisibleButUnsupported(
        into suite: inout TestSuite
    ) async throws {
        let rawQuestions = (0...AppServerObservationAdapter.maximumStructuredQuestions).map { index in
            JSONValue.object([
                "id": .string("question-\(index)"),
                "header": .string("Header"),
                "question": .string("Question"),
                "options": .null,
            ])
        }
        let request = try await projectedRequest(
            method: "item/tool/requestUserInput",
            id: .integer(905),
            params: [
                "threadId": .string("thread-phase9"),
                "turnId": .string("turn-phase9"),
                "itemId": .string("item-phase9"),
                "questions": .array(rawQuestions),
            ]
        )
        suite.checkEqual(request.facts, .unsupported, "over-bound questions never become a partial answer form")
        let presentation = try await attentionPresentation(for: request)
        suite.check(
            !presentation.isResponseShapeSupported
                && presentation.responseSupportDetail.contains("Respond in Codex"),
            "over-bound request remains visible with honest unsupported copy"
        )
    }

    private static func refusesTransformedPermissionSubpaths(
        into suite: inout TestSuite
    ) async throws {
        let overBoundSubpath = String(
            repeating: "x",
            count: AppServerObservationAdapter.maximumRequestTextUTF8Bytes + 1
        )
        let overBound = try await projectedRequest(
            method: "item/permissions/requestApproval",
            id: .integer(906),
            params: permissionApprovalParams(
                specialPath: [
                    "kind": .string("project_roots"),
                    "subpath": .string(overBoundSubpath),
                ]
            )
        )
        suite.checkEqual(
            overBound.facts,
            .unsupported,
            "over-bound project-roots subpath refuses a transformed grant"
        )
        let overBoundPresentation = try await attentionPresentation(for: overBound)
        suite.check(
            !overBoundPresentation.isResponseShapeSupported
                && overBoundPresentation.responseSupportDetail.contains("Respond in Codex"),
            "over-bound permission subpath disables the response with honest copy"
        )
        do {
            _ = try AppServerControlResponseEncoder.approvalResult(
                for: overBound,
                choice: .approve
            )
            suite.check(false, "over-bound permission subpath cannot produce an approval response")
        } catch AppServerControlResponseEncodingError.unsupportedRequest {
            suite.check(true, "over-bound permission subpath cannot produce an approval response")
        } catch {
            suite.check(false, "over-bound permission subpath fails with the unsupported-request error")
        }

        let multiline = try await projectedRequest(
            method: "item/permissions/requestApproval",
            id: .integer(907),
            params: permissionApprovalParams(
                specialPath: [
                    "kind": .string("project_roots"),
                    "subpath": .string("Sources\nTests"),
                ]
            )
        )
        suite.checkEqual(
            multiline.facts,
            .unsupported,
            "multi-line project-roots subpath refuses a first-line grant"
        )
        do {
            _ = try AppServerControlResponseEncoder.approvalResult(
                for: multiline,
                choice: .approve
            )
            suite.check(false, "multi-line permission subpath cannot produce an approval response")
        } catch AppServerControlResponseEncodingError.unsupportedRequest {
            suite.check(true, "multi-line permission subpath cannot produce an approval response")
        } catch {
            suite.check(false, "multi-line permission subpath fails with the unsupported-request error")
        }

        for (id, label, subpath) in [
            (909, "over-bound", overBoundSubpath),
            (910, "multi-line", "Sources\nTests"),
        ] {
            let unknown = try await projectedRequest(
                method: "item/permissions/requestApproval",
                id: .integer(Int64(id)),
                params: permissionApprovalParams(
                    specialPath: [
                        "kind": .string("unknown"),
                        "path": .string("/tmp/phase9"),
                        "subpath": .string(subpath),
                    ]
                )
            )
            suite.checkEqual(
                unknown.facts,
                .unsupported,
                "\(label) unknown-kind subpath refuses a transformed grant"
            )
            do {
                _ = try AppServerControlResponseEncoder.approvalResult(
                    for: unknown,
                    choice: .approve
                )
                suite.check(false, "\(label) unknown-kind subpath cannot produce an approval response")
            } catch AppServerControlResponseEncodingError.unsupportedRequest {
                suite.check(true, "\(label) unknown-kind subpath cannot produce an approval response")
            } catch {
                suite.check(false, "\(label) unknown-kind subpath fails with the unsupported-request error")
            }
        }

        let boundarySubpath = String(
            repeating: "é",
            count: AppServerObservationAdapter.maximumRequestTextUTF8Bytes / 2
        )
        let boundary = try await projectedRequest(
            method: "item/permissions/requestApproval",
            id: .integer(908),
            params: permissionApprovalParams(
                specialPath: [
                    "kind": .string("project_roots"),
                    "subpath": .string(boundarySubpath),
                ]
            )
        )
        guard case let .permissionsApproval(facts) = boundary.facts,
              case let .special(.projectRoots(decodedSubpath)) =
                facts.requestedPermissions.fileSystem?.entries?.first?.path else {
            suite.check(false, "boundary-length permission subpath remains typed")
            return
        }
        suite.checkEqual(
            decodedSubpath,
            boundarySubpath,
            "boundary-length permission subpath decodes byte-exact"
        )
        let approval = try AppServerControlResponseEncoder.approvalResult(
            for: boundary,
            choice: .approve
        )
        let echoedSubpath = approval.objectValue?["permissions"]?.objectValue?["fileSystem"]?
            .objectValue?["entries"]?.arrayValue?.first?.objectValue?["path"]?.objectValue?["value"]?
            .objectValue?["subpath"]?.stringValue
        suite.checkEqual(
            echoedSubpath,
            boundarySubpath,
            "boundary-length permission approval echoes the requested UTF-8 bytes exactly"
        )
    }

    private static func presentsExactPermissionEntriesAndRefusesUnknownKinds(
        into suite: inout TestSuite
    ) async throws {
        let visible = try await projectedRequest(
            method: "item/permissions/requestApproval",
            id: .integer(911),
            params: approvalBase().merging([
                "cwd": .string("/tmp/phase9"),
                "permissions": .object([
                    "fileSystem": .object([
                        "entries": .array([
                            .object([
                                "access": .string("read"),
                                "path": .object([
                                    "type": .string("special"),
                                    "value": .object([
                                        "kind": .string("project_roots"),
                                        "subpath": .string("Sources"),
                                    ]),
                                ]),
                            ]),
                            .object([
                                "access": .string("write"),
                                "path": .object([
                                    "type": .string("path"),
                                    "path": .string("/tmp/phase9/output"),
                                ]),
                            ]),
                            .object([
                                "access": .string("deny"),
                                "path": .object([
                                    "type": .string("glob_pattern"),
                                    "pattern": .string("**/.env"),
                                ]),
                            ]),
                        ]),
                        "read": .array([.string("/tmp/phase9/README.md")]),
                        "write": .array([.string("/tmp/phase9/generated")]),
                        "globScanMaxDepth": .integer(4),
                    ]),
                    "network": .object(["enabled": .bool(true)]),
                ]),
            ]) { _, replacement in replacement }
        )
        let presentation = try await attentionPresentation(for: visible)
        for expected in [
            "Filesystem entry · read · project_roots · subpath: Sources",
            "Filesystem entry · write · path: /tmp/phase9/output",
            "Filesystem entry · deny · glob_pattern: **/.env",
            "Filesystem read path: /tmp/phase9/README.md",
            "Filesystem write path: /tmp/phase9/generated",
            "Filesystem glob scan max depth: 4",
            "Network access requested",
        ] {
            suite.check(
                presentation.detail.contains(expected),
                "permission consent detail renders \(expected)"
            )
        }
        suite.check(
            !presentation.detail.contains("Filesystem entries: 5"),
            "permission consent does not replace exact entries with a count"
        )
        suite.check(presentation.isResponseShapeSupported, "fully visible permission entries remain answerable")

        let unknown = try await projectedRequest(
            method: "item/permissions/requestApproval",
            id: .integer(912),
            params: permissionApprovalParams(
                specialPath: [
                    "kind": .string("unknown"),
                    "path": .string("opaque-root"),
                    "subpath": .string("Sources"),
                ]
            )
        )
        let unknownPresentation = try await attentionPresentation(for: unknown)
        suite.check(
            unknownPresentation.detail.contains(
                "Filesystem entry · read · unknown · path: opaque-root · subpath: Sources"
            ),
            "unknown permission kind remains visible with its exact bounded path and subpath"
        )
        suite.check(
            !unknownPresentation.isResponseShapeSupported
                && unknownPresentation.responseSupportDetail.contains("Respond in Codex"),
            "unknown permission kind disables every response with honest copy"
        )
        do {
            _ = try AppServerControlResponseEncoder.approvalResult(
                for: unknown,
                choice: .approve
            )
            suite.check(false, "unknown permission kind cannot produce an approval response")
        } catch AppServerControlResponseEncodingError.unsupportedRequest {
            suite.check(true, "unknown permission kind cannot produce an approval response")
        } catch {
            suite.check(false, "unknown permission kind fails with the unsupported-request error")
        }

        let futureKind = try await projectedRequest(
            method: "item/permissions/requestApproval",
            id: .integer(914),
            params: permissionApprovalParams(
                specialPath: ["kind": .string("future_permission_root")]
            )
        )
        suite.checkEqual(
            futureKind.facts,
            .unsupported,
            "an unrecognized future permission kind remains an unsupported card"
        )
        let futureKindPresentation = try await attentionPresentation(for: futureKind)
        suite.check(
            !futureKindPresentation.isResponseShapeSupported
                && futureKindPresentation.responseSupportDetail.contains("Respond in Codex"),
            "an unrecognized permission kind disables response with honest copy"
        )
        do {
            _ = try AppServerControlResponseEncoder.approvalResult(
                for: futureKind,
                choice: .approve
            )
            suite.check(false, "an unrecognized permission kind cannot produce an approval response")
        } catch AppServerControlResponseEncodingError.unsupportedRequest {
            suite.check(true, "an unrecognized permission kind cannot produce an approval response")
        } catch {
            suite.check(false, "an unrecognized permission kind uses the unsupported-request error")
        }

        let aggregateOverBound = try await projectedRequest(
            method: "item/permissions/requestApproval",
            id: .integer(913),
            params: approvalBase().merging([
                "cwd": .string("/tmp/phase9"),
                "permissions": .object([
                    "fileSystem": .object([
                        "read": .array([
                            .string("/" + String(repeating: "a", count: 600)),
                            .string("/" + String(repeating: "b", count: 600)),
                        ]),
                    ]),
                ]),
            ]) { _, replacement in replacement }
        )
        let boundedPresentation = try await attentionPresentation(for: aggregateOverBound)
        suite.check(
            boundedPresentation.detail.utf8.count
                <= AppServerTimelineItemPresentation.maximumVisibleDetailUTF8Bytes,
            "permission consent detail stays within the existing presentation byte bound"
        )
        suite.check(
            !boundedPresentation.isResponseShapeSupported
                && boundedPresentation.responseSupportDetail.contains("Respond in Codex"),
            "permission entries that cannot all fit visibly disable the response"
        )
    }

    private static func projectedRequest(
        method: String,
        id: RequestID,
        params: [String: JSONValue]
    ) async throws -> AppServerProjectedRequest {
        let adapter = AppServerObservationAdapter()
        let input = try adapter.projectionInput(
            from: .init(id: id, method: method, params: .object(params)),
            cursor: .init(connection: connection, sequence: 1),
            observedAt: observedAt
        )!
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [
                .monitor, .followUp, .steer, .stopTurn, .resolveApproval, .answer,
            ])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 0),
            observedAt: observedAt,
            threads: [requestThread()]
        )))
        _ = await store.apply(input)
        return try unwrap(
            await store.snapshot(at: observedAt).attentionRequests.first,
            "projected request"
        )
    }

    private static func attentionPresentation(
        for request: AppServerProjectedRequest
    ) async throws -> AppServerAttentionPresentation {
        let store = AppServerProjectionStore()
        _ = await store.apply(.connectionActivated(
            identity: connection,
            source: .managedDaemon,
            featureSupport: .init(features: [.monitor, .answer, .resolveApproval])
        ))
        _ = await store.apply(.snapshot(.init(
            cursor: .init(connection: connection, sequence: 0),
            observedAt: observedAt,
            threads: [requestThread()]
        )))
        _ = await store.apply(.delta(.init(
            cursor: .init(connection: connection, sequence: 1),
            observedAt: observedAt,
            delta: .requestOpened(.init(
                requestID: request.id.requestID,
                threadID: request.threadID,
                turnID: request.turnID,
                itemID: request.itemID,
                kind: request.kind,
                facts: request.facts,
                startedAt: request.startedAt
            ))
        )))
        let domain = AppServerDomainPresentation(
            snapshot: await store.snapshot(at: observedAt),
            runtimeStatus: .init(phase: .connected, detail: "Connected"),
            now: observedAt
        )
        return try unwrap(domain.threads.first?.attention, "attention presentation")
    }

    private static func requestThread() -> AppServerThreadInput {
        .init(
            id: .init(rawValue: "thread-phase9"),
            sessionID: .init(rawValue: "session-phase9"),
            title: "Phase 9 throwaway",
            source: .appServer,
            status: .active([.waitingOnUserInput]),
            createdAt: observedAt,
            updatedAt: observedAt
        )
    }

    private static func approvalBase() -> [String: JSONValue] {
        [
            "threadId": .string("thread-phase9"),
            "turnId": .string("turn-phase9"),
            "itemId": .string("item-phase9"),
            "startedAtMs": .integer(1_850_000_000_000),
        ]
    }

    private static func permissionApprovalParams(
        specialPath: [String: JSONValue]
    ) -> [String: JSONValue] {
        approvalBase().merging([
            "cwd": .string("/tmp/phase9"),
            "permissions": .object([
                "fileSystem": .object([
                    "entries": .array([.object([
                        "access": .string("read"),
                        "path": .object([
                            "type": .string("special"),
                            "value": .object(specialPath),
                        ]),
                    ])]),
                ]),
            ]),
        ]) { _, replacement in replacement }
    }

    private static func unwrap<Value>(_ value: Value?, _ label: String) throws -> Value {
        guard let value else { throw Phase9FixtureError.missing(label) }
        return value
    }
}

private enum Phase9FixtureError: Error {
    case missing(String)
}
