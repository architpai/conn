import ConnDomain
import ConnUI

enum ConnSessionOpenerTestCases {
    static func run(into suite: inout TestSuite) async {
        let codexID = ConnSessionID(
            integrationID: .init(rawValue: "builtin-codex"),
            upstreamID: .init(rawValue: "codex-session")
        )
        let piID = ConnSessionID(
            integrationID: .init(rawValue: "pi.external"),
            upstreamID: .init(rawValue: "pi-session")
        )
        let opened = LockedSessionIDs()
        let opener = AnyConnSessionOpener(
            availability: { sessionID in
                sessionID.integrationID.rawValue == "builtin-codex"
                    ? .available
                    : .unavailable(reason: "Exact Pi terminal activation is unavailable")
            },
            open: { sessionID in
                await opened.append(sessionID)
                return true
            }
        )

        suite.check(
            opener.availability(for: codexID) == .available,
            "the composition opener exposes Codex availability before click"
        )
        suite.check(
            opener.availability(for: piID)
                == .unavailable(reason: "Exact Pi terminal activation is unavailable"),
            "the composition opener suppresses unqualified external Pi opening"
        )
        let didOpen = await opener.open(codexID)
        suite.check(didOpen, "an available route performs its opener")
        let openedValues = await opened.values
        suite.check(
            openedValues == [codexID],
            "the opener receives the exact provider-qualified Session identity"
        )
    }
}

private actor LockedSessionIDs {
    private var storage: [ConnSessionID] = []

    func append(_ value: ConnSessionID) {
        storage.append(value)
    }

    var values: [ConnSessionID] { storage }
}
