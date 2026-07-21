import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    enum RegistrationError: Error {
        case installHandler(OSStatus)
        case register(OSStatus)
    }

    private static let signature: OSType = 0x5351_4854 // SQHT
    private static let identifier: UInt32 = 1

    // Carbon's opaque pointers are not Sendable, but their lifetime is owned by
    // this MainActor type and must remain reachable from its nonisolated deinit.
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        // Swift 6 treats deinitializers as nonisolated even for this
        // MainActor-owned type, so release the Carbon registrations directly.
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func invalidate() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
    }

    /// Registers Control-Option-Space through the public Carbon hot-key API.
    /// Unlike global key monitoring this does not require Accessibility trust.
    func register() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard result == noErr,
                      identifier.signature == GlobalHotKey.signature,
                      identifier.id == GlobalHotKey.identifier
                else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { owner.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { throw RegistrationError.installHandler(status) }

        let identifier = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let registration = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registration == noErr else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            throw RegistrationError.register(registration)
        }
    }
}
