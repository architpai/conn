import Foundation
import ConnAppCore
import ConnAppServerAdapter
import ConnDomain

enum Phase11LegacyPluginRetirementTestCases {
    static func run(into suite: inout TestSuite) async {
        await detectsAndRemovesOnlyExactLegacyIdentity(into: &suite)
        await neverRetriesAfterUncertainAcknowledgement(into: &suite)
        await rejectsAmbiguousAndStaleCandidates(into: &suite)
        await doesNotCallFailedMarketplaceLoadAbsent(into: &suite)
        await requiresHookRemovalProof(into: &suite)
        await rejectsPartialHookRemovalProof(into: &suite)
    }

    private static func doesNotCallFailedMarketplaceLoadAbsent(
        into suite: inout TestSuite
    ) async {
        let wire = ConnAppServerConnectionIdentity(instanceID: UUID(), generation: 4)
        let domain = AppServerConnectionIdentity(instanceID: wire.instanceID, generation: 4)
        let connection = Phase11PluginConnection(identity: wire, listResults: [.object([
            "marketplaces": .array([]),
            "marketplaceLoadErrors": .array([.object([
                "marketplacePath": .string("/PRIVATE-BROKEN-MARKETPLACE"),
                "message": .string("PRIVATE-LOAD-ERROR"),
            ])]),
        ])])
        let runtime = LegacyPluginRetirementRuntime()
        await runtime.attach(connection: connection, wireIdentity: wire, domainConnection: domain, version: .v0_144_6)
        let scan = await runtime.scan(workingDirectories: ["/tmp/known"])
        let candidate = await runtime.currentCandidate()
        suite.checkEqual(scan, .invalidResponse, "marketplace load errors are indeterminate, never plugin-absent")
        suite.check(candidate == nil, "failed marketplace load retains no uninstall authority")
    }

    private static func detectsAndRemovesOnlyExactLegacyIdentity(
        into suite: inout TestSuite
    ) async {
        let wire = ConnAppServerConnectionIdentity(instanceID: UUID(), generation: 1)
        let domain = AppServerConnectionIdentity(instanceID: wire.instanceID, generation: 1)
        let connection = Phase11PluginConnection(identity: wire, listResults: [
            pluginList([
                marketplace("sidequest-local", plugins: [plugin("sidequest", installed: true)]),
                marketplace("other-market", plugins: [plugin("unrelated", installed: true)]),
            ]),
            pluginList([]),
        ])
        let runtime = LegacyPluginRetirementRuntime()
        await runtime.attach(
            connection: connection,
            wireIdentity: wire,
            domainConnection: domain,
            version: .v0_144_6
        )
        guard case let .candidate(candidate) = await runtime.scan(workingDirectories: ["/tmp/known"]) else {
            suite.check(false, "exact legacy plugin should be detected")
            return
        }
        suite.checkEqual(candidate.pluginID, "sidequest", "candidate keeps exact server plugin id")
        suite.checkEqual(candidate.marketplaceName, "sidequest-local", "candidate is scoped to legacy marketplace")
        suite.check(
            !String(reflecting: candidate).contains("PRIVATE-PLUGIN-PATH-CANARY"),
            "plugin scan drops marketplace paths and plugin source details"
        )
        let removal = await runtime.uninstall(
            confirmed: candidate,
            verificationWorkingDirectories: ["/tmp/known"]
        )
        suite.checkEqual(removal, .removed, "confirmed exact candidate is removed")
        let methods = await connection.sentMethods
        suite.checkEqual(methods, ["plugin/list", "plugin/uninstall", "plugin/list", "hooks/list"], "uninstall is one exact send followed by plugin and hook proof")
        let firstParams = await connection.sentParams.first ?? nil
        let kinds = firstParams?.objectValue?["marketplaceKinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        suite.checkEqual(
            Set(kinds),
            Set(["local", "vertical", "workspace-directory", "shared-with-me", "created-by-me-remote"]),
            "ambiguity scan covers every stable marketplace kind before global-id uninstall"
        )
    }

    private static func neverRetriesAfterUncertainAcknowledgement(
        into suite: inout TestSuite
    ) async {
        let wire = ConnAppServerConnectionIdentity(instanceID: UUID(), generation: 2)
        let domain = AppServerConnectionIdentity(instanceID: wire.instanceID, generation: 2)
        let connection = Phase11PluginConnection(
            identity: wire,
            listResults: [pluginList([
                marketplace("sidequest-release-1-0-0", plugins: [plugin("sidequest", installed: true)]),
            ])],
            failUninstall: true
        )
        let runtime = LegacyPluginRetirementRuntime()
        await runtime.attach(connection: connection, wireIdentity: wire, domainConnection: domain, version: .v0_144_5)
        guard case let .candidate(candidate) = await runtime.scan(workingDirectories: ["/tmp/known"]) else {
            suite.check(false, "release legacy plugin should be detected")
            return
        }
        let firstRemoval = await runtime.uninstall(
            confirmed: candidate,
            verificationWorkingDirectories: ["/tmp/known"]
        )
        let repeatedRemoval = await runtime.uninstall(
            confirmed: candidate,
            verificationWorkingDirectories: ["/tmp/known"]
        )
        let methods = await connection.sentMethods
        suite.checkEqual(firstRemoval, .acknowledgementUncertain, "timeout remains acknowledgement-uncertain")
        suite.checkEqual(repeatedRemoval, .alreadyAttempted, "uncertain uninstall is never retried")
        suite.checkEqual(methods.filter { $0 == "plugin/uninstall" }.count, 1, "only one consequential uninstall is sent")
    }

    private static func rejectsAmbiguousAndStaleCandidates(
        into suite: inout TestSuite
    ) async {
        let wire = ConnAppServerConnectionIdentity(instanceID: UUID(), generation: 3)
        let domain = AppServerConnectionIdentity(instanceID: wire.instanceID, generation: 3)
        let connection = Phase11PluginConnection(identity: wire, listResults: [pluginList([
            marketplace("sidequest-local", plugins: [plugin("sidequest", installed: true)]),
            marketplace("other-market", plugins: [plugin("sidequest", installed: true)]),
        ])])
        let runtime = LegacyPluginRetirementRuntime()
        await runtime.attach(connection: connection, wireIdentity: wire, domainConnection: domain, version: .v0_144_6)
        let scan = await runtime.scan(workingDirectories: ["/tmp/known"])
        suite.checkEqual(scan, .ambiguous, "same plugin id in another marketplace makes uninstall ambiguous")
        let invented = LegacySidequestPluginCandidate(
            connection: domain,
            pluginID: "sidequest",
            marketplaceName: "sidequest-local"
        )
        let uninstall = await runtime.uninstall(
            confirmed: invented,
            verificationWorkingDirectories: ["/tmp/known"]
        )
        let methods = await connection.sentMethods
        suite.checkEqual(uninstall, .staleConfirmation, "invented candidate cannot authorize uninstall")
        suite.check(!methods.contains("plugin/uninstall"), "ambiguous scan sends no uninstall")
    }

    private static func requiresHookRemovalProof(into suite: inout TestSuite) async {
        let wire = ConnAppServerConnectionIdentity(instanceID: UUID(), generation: 5)
        let domain = AppServerConnectionIdentity(instanceID: wire.instanceID, generation: 5)
        let connection = Phase11PluginConnection(
            identity: wire,
            listResults: [
                pluginList([
                    marketplace("sidequest-local", plugins: [plugin("sidequest", installed: true)]),
                ]),
                pluginList([]),
            ],
            hookResult: .object(["data": .array([.object([
                "cwd": .string("/tmp/known"),
                "errors": .array([]),
                "warnings": .array([]),
                "hooks": .array([legacyHookMetadata()]),
            ])])])
        )
        let runtime = LegacyPluginRetirementRuntime()
        await runtime.attach(connection: connection, wireIdentity: wire, domainConnection: domain, version: .v0_144_6)
        guard case let .candidate(candidate) = await runtime.scan(workingDirectories: ["/tmp/known"]) else {
            suite.check(false, "legacy plugin should be detected before hook verification")
            return
        }
        let removal = await runtime.uninstall(
            confirmed: candidate,
            verificationWorkingDirectories: ["/tmp/known"]
        )
        suite.checkEqual(removal, .stillInstalled, "lingering legacy hooks prevent a removed result")
    }

    private static func rejectsPartialHookRemovalProof(into suite: inout TestSuite) async {
        let wire = ConnAppServerConnectionIdentity(instanceID: UUID(), generation: 6)
        let domain = AppServerConnectionIdentity(instanceID: wire.instanceID, generation: 6)
        let connection = Phase11PluginConnection(
            identity: wire,
            listResults: [
                pluginList([marketplace("sidequest-local", plugins: [plugin("sidequest", installed: true)])]),
                pluginList([]),
            ],
            hookResult: .object(["data": .array([])])
        )
        let runtime = LegacyPluginRetirementRuntime()
        await runtime.attach(connection: connection, wireIdentity: wire, domainConnection: domain, version: .v0_144_6)
        guard case let .candidate(candidate) = await runtime.scan(workingDirectories: ["/tmp/known"]) else {
            suite.check(false, "legacy plugin should be detected before partial proof test")
            return
        }
        let removal = await runtime.uninstall(
            confirmed: candidate,
            verificationWorkingDirectories: ["/tmp/known"]
        )
        suite.checkEqual(removal, .acknowledgementUncertain, "missing cwd rows can never prove hook removal")
    }

    private static func pluginList(_ marketplaces: [JSONValue]) -> JSONValue {
        .object(["marketplaces": .array(marketplaces)])
    }

    private static func marketplace(_ name: String, plugins: [JSONValue]) -> JSONValue {
        .object([
            "name": .string(name),
            "path": .string("/PRIVATE-PLUGIN-PATH-CANARY"),
            "plugins": .array(plugins),
        ])
    }

    private static func plugin(_ id: String, installed: Bool) -> JSONValue {
        .object([
            "id": .string(id),
            "installed": .bool(installed),
            "source": .object([
                "type": .string("local"),
                "path": .string("/PRIVATE-PLUGIN-PATH-CANARY"),
            ]),
        ])
    }

    private static func legacyHookMetadata() -> JSONValue {
        .object([
            "command": .null,
            "currentHash": .string("hash"),
            "displayOrder": .integer(1),
            "enabled": .bool(true),
            "eventName": .string("preToolUse"),
            "handlerType": .string("command"),
            "isManaged": .bool(false),
            "key": .string("key"),
            "matcher": .null,
            "pluginId": .string("sidequest"),
            "source": .string("plugin"),
            "sourcePath": .string("/tmp/plugin"),
            "statusMessage": .null,
            "timeoutSec": .integer(10),
            "trustStatus": .string("trusted"),
        ])
    }
}

private actor Phase11PluginConnection: AppServerThreadControlConnection {
    enum Failure: Error { case requested }

    let identity: ConnAppServerConnectionIdentity
    private var listResults: [JSONValue]
    private let hookResult: JSONValue?
    private let failUninstall: Bool
    private(set) var sentMethods: [String] = []
    private(set) var sentParams: [JSONValue?] = []
    private var sequence: UInt64 = 0

    init(
        identity: ConnAppServerConnectionIdentity,
        listResults: [JSONValue],
        failUninstall: Bool = false,
        hookResult: JSONValue? = nil
    ) {
        self.identity = identity
        self.listResults = listResults
        self.failUninstall = failUninstall
        self.hookResult = hookResult
    }

    func requestEnvelope(
        method: String,
        params: JSONValue?,
        timeout: Duration?
    ) async throws -> ConnAppServerResponseEnvelope {
        sentMethods.append(method)
        sentParams.append(params)
        sequence += 1
        if method == "plugin/uninstall", failUninstall { throw Failure.requested }
        let result: JSONValue
        if method == "plugin/list", !listResults.isEmpty {
            result = listResults.removeFirst()
        } else if method == "hooks/list" {
            if let hookResult {
                result = hookResult
            } else {
                let cwds = params?.objectValue?["cwds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                result = .object(["data": .array(cwds.map { cwd in
                    .object([
                        "cwd": .string(cwd),
                        "errors": .array([]),
                        "warnings": .array([]),
                        "hooks": .array([]),
                    ])
                })])
            }
        } else {
            result = .object([:])
        }
        return .init(connection: identity, sequence: sequence, result: result)
    }

    func respond(to requestID: RequestID, result: JSONValue) async throws {}

    func controlIdentity() async -> ConnAppServerConnectionIdentity? { identity }
}
