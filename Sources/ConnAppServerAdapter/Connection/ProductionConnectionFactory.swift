import Foundation

public extension ConnAppServerConnection {
    /// The only production transport selected by Phase 5. The proxy is a
    /// disposable connection helper; disconnecting or losing it never stops
    /// the Codex-managed daemon or assigns meaning to a turn.
    static func productionProxy(
        codexExecutableURL: URL,
        configuration: ConnAppServerConnectionConfiguration = .init(),
        clientInfo: InitializeClientInfo = .init(
            name: "conn",
            title: "Conn",
            version: "0.1.0"
        )
    ) -> ConnAppServerConnection {
        ConnAppServerConnection(
            transport: ProxyStdioTransport(codexExecutableURL: codexExecutableURL),
            configuration: configuration,
            clientInfo: clientInfo
        )
    }
}

public extension ManagedDaemonStatus {
    var supportedAppServerVersion: SupportedAppServerVersion? {
        guard kind == .running, let rawValue = report?.appServerVersion else { return nil }
        return SupportedAppServerVersion(rawValue: rawValue)
    }
}
