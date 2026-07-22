import AppKit
import Combine
import Foundation
import ConnAppCore
import ConnDomain

@MainActor
final class ConnViewModel: ObservableObject {
    @Published private(set) var presentation: AppServerDomainPresentation?
    @Published private(set) var hookVisibility = AppServerHookVisibilityPresentation(.init(
        connection: nil,
        freshness: .stale,
        configuredHooks: [],
        runsByThread: [:]
    ))
    @Published private(set) var legacyPluginCandidate: LegacySidequestPluginCandidate?
    @Published private(set) var legacyHookRetirementDiagnostic: String?
    @Published private(set) var pendingLegacyPluginCandidate: LegacySidequestPluginCandidate?
    @Published var showsLegacyPluginRemovalConfirmation = false {
        didSet {
            if !showsLegacyPluginRemovalConfirmation, !isRemovingLegacyPlugin {
                pendingLegacyPluginCandidate = nil
            }
        }
    }
    @Published private(set) var isRemovingLegacyPlugin = false
    @Published private(set) var legacyPluginRetirementNotice: String?
    @Published private(set) var availableDisplays: [DisplayChoice] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var presentationDate = Date()
    @Published private(set) var surfaceState: ShellSurfaceState = .compact
    @Published private(set) var isSurfaceGeometryTransitionInFlight = false
    @Published private(set) var isExpandedContentRevealReady = false
    @Published private(set) var compactShelf: ShellCompactShelfPresentation?
    @Published private(set) var compactNotificationBatch: ShellUserFacingNotificationBatch?
    @Published private(set) var panelPlacement: ShellPanelPlacement = .externalCapsule
    @Published var sidebarMode: ShellSidebarMode = .threads {
        didSet {
            guard sidebarMode != oldValue else { return }
            UserDefaults.standard.set(sidebarMode.rawValue, forKey: Self.threadPickerGroupingPreferenceKey)
        }
    }
    @Published var threadPickerActivityWindow: ThreadPickerActivityWindow = .default {
        didSet {
            guard threadPickerActivityWindow != oldValue else { return }
            UserDefaults.standard.set(
                threadPickerActivityWindow.rawValue,
                forKey: Self.threadPickerActivityWindowPreferenceKey
            )
        }
    }
    @Published private var threadOrder = ShellManualOrder()
    @Published private var projectOrder = ShellManualOrder()
    @Published private var collapsedProjectIDs: Set<String> = []
    @Published var showsSettings = false
    @Published var showsThreadOptions = false
    @Published var defaultWorkspace: String {
        didSet {
            guard defaultWorkspace != oldValue else { return }
            UserDefaults.standard.set(defaultWorkspace, forKey: Self.defaultWorkspacePreferenceKey)
        }
    }
    @Published var appearance: ShellAppearance = .dark {
        didSet {
            guard appearance != oldValue else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearancePreferenceKey)
        }
    }
    @Published var isPresentationPaused = false {
        didSet {
            guard isPresentationPaused != oldValue else { return }
            rebuildPresentation()
        }
    }
    @Published var shortcutIssue: String?
    @Published var integrationError: String?
    @Published private(set) var actionError: String?
    @Published private(set) var actionNotice: String?
    @Published private(set) var isPerformingAction = false
    @Published private(set) var actionSessionID: String?
    @Published private var controlPresentationState = AppServerThreadControlPresentationState()
    @Published private(set) var controlAvailability = AppServerThreadControlAvailability()
    @Published private(set) var showsNewThreadComposer = false
    @Published private var newThreadDraft = AppServerNewThreadDraft()
    @Published private(set) var isCreatingThread = false
    @Published private(set) var newThreadError: String?
    @Published private(set) var newThreadNotice: String?
    @Published private(set) var newThreadModelOptions: [AppServerNewThreadModelOption] = []
    @Published private(set) var isLoadingNewThreadModels = false
    @Published private(set) var newThreadModelError: String?
    @Published var showsSharedDesktopLabs = false
    @Published var sharedDesktopLabsEnabled = false {
        didSet {
            guard sharedDesktopLabsEnabled != oldValue else { return }
            UserDefaults.standard.set(
                sharedDesktopLabsEnabled,
                forKey: Self.sharedDesktopLabsPreferenceKey
            )
            rebuildPresentation()
            requestSharedDesktopDiagnosis()
        }
    }
    @Published private(set) var sharedDesktopDiagnostics: SharedDesktopDiagnosticsSnapshot?
    @Published private(set) var isDiagnosingSharedDesktop = false
    @Published private(set) var isSettingUpSharedDesktop = false
    @Published private(set) var sharedDesktopSetupResult: SharedDesktopSetupResult?
    @Published private(set) var sharedDesktopSetupEnabled = false
    @Published private(set) var sharedDesktopSetupExplicitlyDisabled = false
    @Published private(set) var sharedDesktopPromptNotice: String?
    @Published var sharedDesktopCandidateThreadID = "" {
        didSet {
            guard sharedDesktopCandidateThreadID != oldValue else { return }
            attestsSharedDesktopCandidate = false
            confirmsDesktopObservedCandidateEvent = false
        }
    }
    @Published var attestsSharedDesktopCandidate = false
    @Published private(set) var sharedDesktopProofBaselineCaptured = false
    @Published private(set) var sharedDesktopThreadProofStatus = AppServerSharedDesktopThreadProofStatus(
        connection: nil,
        threadID: nil,
        didReadOnlyResume: false,
        isWaitingForNewEvent: false,
        didObserveNewEvent: false
    )
    @Published private(set) var confirmsDesktopObservedCandidateEvent = false

    var onToggleExpansion: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onRequestExpansion: (() -> Void)?
    var onCompactShelfVisibilityChanged: ((Bool) -> Void)?
    var onPausePresentation: (() -> Void)?
    var onHidePresentation: (() -> Void)?
    var onSelectDisplay: ((UInt32) -> Void)?
    var onOpenCodex: ((ShellActionToken) -> Void)?
    var onQualifySelectedSession: ((String) -> Void)?
    var onRequestSync: (() -> Void)?
    var onSubmitControl: ((AppServerControlIntent, UInt64, ShellActionToken) -> Void)?
    var onSubmitNewThread: ((AppServerNewThreadIntent) -> Void)?
    var onRequestNewThreadModels: ((UInt64) -> Void)?
    var onControlSelectionChanged: ((UInt64) -> Void)?
    var onDiagnoseSharedDesktop: ((Bool, SharedDesktopDiagnosisGeneration) -> Void)?
    var onSetUpSharedDesktop: (() -> Void)?
    var onTurnOffSharedDesktop: (() -> Void)?
    var onBeginSharedDesktopThreadProof: ((String) -> Void)?
    var onCancelSharedDesktopThreadProof: (() -> Void)?
    var onUninstallLegacyPlugin: ((LegacySidequestPluginCandidate) -> Void)?

    private var selection = ShellSelectionState()
    private var actionState = ShellActionState()
    private var latestSnapshot: AppServerProjectionSnapshot?
    private var latestRuntimeStatus: AppServerRuntimeStatus?
    private var selectionGeneration: UInt64 = 0
    private let outcomeReviewStore: AppServerOutcomeReviewPreferenceStore
    private var outcomeReviewLedger: AppServerOutcomeReviewLedger
    private var pendingCreatedThreadID: String?
    private var createdThreadPlaceholder: AppServerThreadPresentation?
    private var createdThreadPlaceholderConnection: AppServerConnectionIdentity?
    private var newThreadModelCatalogConnection: AppServerConnectionIdentity?
    private var threadModelSelections: [AppServerThreadID: AppServerThreadModelSelection] = [:]
    private var preferredNewThreadModelID: String?
    @Published private var followUpModelOverrideIDByThread: [String: String] = [:]
    private var sharedDesktopProofBaselineThreadIDs: Set<AppServerThreadID> = []
    private var sharedDesktopProofBaselineConnection: AppServerConnectionIdentity?
    private var sharedDesktopDiagnosisGate = SharedDesktopDiagnosisGenerationGate()
    private var sharedDesktopDiagnosticsLease: SharedDesktopDiagnosticsFreshnessLease?
    private var newThreadModelLoadGeneration: UInt64 = 0
    private var surfaceGeometryTransitionGate = ShellSurfaceGeometryTransitionGenerationGate()
    private var compactShelfTask: Task<Void, Never>?
    private var didSeedUserFacingNotifications = false
    private var seenUserFacingNotificationIDs: Set<String> = []
    private var notificationSeedLedger = ShellUserFacingNotificationSeedLedger()
    private var notificationHydratedThreadIDs: Set<String> = []
    private var pendingUserFacingNotifications: [ShellUserFacingNotification] = []
    private var newThreadSelectionTask: Task<Void, Never>?
    private static let appearancePreferenceKey = "appearance.v1"
    private static let defaultWorkspacePreferenceKey = "defaultWorkspace.v1"
    private static let threadOrderPreferenceKey = "threadOrder.v1"
    private static let projectOrderPreferenceKey = "projectOrder.v1"
    private static let collapsedProjectsPreferenceKey = "collapsedProjects.v1"
    private static let sharedDesktopLabsPreferenceKey = "sharedDesktopLabs.v1"
    private static let sharedDesktopSetupPreferenceKey = "sharedDesktopAppManaged.v1"
    private static let sharedDesktopDisabledPreferenceKey = "sharedDesktopAppManagedDisabled.v1"
    private static let threadPickerActivityWindowPreferenceKey = "threadPickerActivityWindow.v1"
    private static let threadPickerGroupingPreferenceKey = "threadPickerGrouping.v1"
    private static let preferredNewThreadModelPreferenceKey = "preferredNewThreadModel.v1"
    private static let maximumDraftUTF8Bytes = 16 * 1_024
    private static let maximumSetupPromptBytes = 64 * 1_024

    init() {
        let reviewStore = AppServerOutcomeReviewPreferenceStore()
        outcomeReviewStore = reviewStore
        outcomeReviewLedger = reviewStore.load(orBaselineAt: Date())
        defaultWorkspace = UserDefaults.standard.string(
            forKey: Self.defaultWorkspacePreferenceKey
        ) ?? NSHomeDirectory()
        preferredNewThreadModelID = UserDefaults.standard.string(
            forKey: Self.preferredNewThreadModelPreferenceKey
        )
        if let rawValue = UserDefaults.standard.string(forKey: Self.appearancePreferenceKey),
           let savedAppearance = ShellAppearance(rawValue: rawValue) {
            appearance = savedAppearance
        }
        if let rawValue = UserDefaults.standard.string(
            forKey: Self.threadPickerActivityWindowPreferenceKey
        ), let savedWindow = ThreadPickerActivityWindow(rawValue: rawValue) {
            threadPickerActivityWindow = savedWindow
        }
        if let rawValue = UserDefaults.standard.string(
            forKey: Self.threadPickerGroupingPreferenceKey
        ), let savedGrouping = ShellSidebarMode(rawValue: rawValue) {
            sidebarMode = savedGrouping
        }
        threadOrder = Self.loadOrder(forKey: Self.threadOrderPreferenceKey)
        projectOrder = Self.loadOrder(forKey: Self.projectOrderPreferenceKey)
        collapsedProjectIDs = Set(
            UserDefaults.standard.stringArray(forKey: Self.collapsedProjectsPreferenceKey) ?? []
        )
        sharedDesktopLabsEnabled = UserDefaults.standard.bool(
            forKey: Self.sharedDesktopLabsPreferenceKey
        )
        sharedDesktopSetupEnabled = UserDefaults.standard.bool(
            forKey: Self.sharedDesktopSetupPreferenceKey
        )
        sharedDesktopSetupExplicitlyDisabled = UserDefaults.standard.bool(
            forKey: Self.sharedDesktopDisabledPreferenceKey
        )
        sharedDesktopDiagnosisGate.invalidate(
            isLabsFeatureEnabled: sharedDesktopLabsEnabled
        )
    }

    struct DisplayChoice: Identifiable, Equatable {
        let id: UInt32
        let name: String
        let isSelected: Bool
    }

    var sessions: [AppServerThreadPresentation] {
        let byID = Dictionary(uniqueKeysWithValues: latestFirstThreads.map { ($0.id, $0) })
        var ordered = visibleThreadOrder.compactMap { byID[$0] }
        if let createdThreadPlaceholder,
           !ordered.contains(where: { $0.id == createdThreadPlaceholder.id }) {
            ordered.insert(createdThreadPlaceholder, at: 0)
        }
        return ordered
    }
    var projects: [AppServerProjectPresentation] {
        let latest = latestFirstProjects
        let byID = Dictionary(uniqueKeysWithValues: latest.map { ($0.id, $0) })
        return visibleProjectOrder.compactMap { byID[$0] }
    }
    var activeCount: Int { presentation?.activeCount ?? 0 }
    var attentionCount: Int { presentation?.attentionCount ?? 0 }
    var selectedSession: AppServerThreadPresentation? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }
    var selectedPresentation: AppServerThreadPresentation? { selectedSession }

    func threadPickerResult(searchText: String) -> ThreadPickerResult {
        ThreadPickerPolicy.select(
            threads: sessions,
            projects: projects,
            configuration: .init(
                activityWindow: threadPickerActivityWindow,
                searchText: searchText,
                grouping: sidebarMode == .projects ? .project : .flat
            ),
            now: Date()
        )
    }
    var selectedHookRuns: [AppServerHookRunPresentation] {
        guard let selectedSessionID else { return [] }
        return hookVisibility.runsByThread[selectedSessionID] ?? []
    }
    var connectionPresentation: AppServerConnectionPresentation? { presentation?.connection }
    var isUserInteracting: Bool { selection.isUserInteracting }
    var selectedActionError: String? {
        if let selectedSessionID,
           !selectedActionIsInProgress,
           let routed = controlPresentationState.outcome(for: selectedSessionID) {
            return routed.error
        }
        return actionSessionID == selectedSessionID ? actionError : nil
    }
    var selectedActionNotice: String? {
        if let selectedSessionID,
           !selectedActionIsInProgress,
           let routed = controlPresentationState.outcome(for: selectedSessionID) {
            return routed.notice
        }
        return actionSessionID == selectedSessionID ? actionNotice : nil
    }
    var selectedActionIsInProgress: Bool {
        actionSessionID == selectedSessionID && isPerformingAction
    }
    var newThreadWorkingDirectory: String { newThreadDraft.workingDirectory }
    var newThreadInitialPrompt: String { newThreadDraft.initialPrompt }
    var selectedNewThreadModelID: String? { newThreadDraft.selectedModelID }
    var selectedNewThreadModel: AppServerNewThreadModelOption? {
        guard let selectedModelID = newThreadDraft.selectedModelID else { return nil }
        return newThreadModelOptions.first { $0.id == selectedModelID }
    }
    var selectedNewThreadModelDetail: String? { selectedNewThreadModel?.detail }
    var selectedFollowUpModelID: String? {
        guard let selectedSessionID else { return nil }
        return followUpModelOverrideIDByThread[selectedSessionID]
    }
    var selectedThreadModelLabel: String {
        let selection = selectedSessionID.map(AppServerThreadID.init(rawValue:))
            .flatMap { threadModelSelections[$0] }
        return AppServerThreadModelLabelPolicy.label(
            selection: selection,
            options: newThreadModelOptions
        )
    }
    var canSelectFollowUpModel: Bool {
        guard !selectedActionIsInProgress else { return false }
        if let thread = selectedProjectedThread {
            return thread.status == .idle && thread.activeTurnIDs.isEmpty
        }
        return selectedSessionID == createdThreadPlaceholder?.id
    }
    var canSubmitNewThread: Bool {
        newThreadValidationError == nil && !isCreatingThread
    }
    var newThreadCreationDetail: String {
        if isCreatingThread {
            return "Creating the thread and waiting for its first turn acknowledgement."
        }
        return newThreadError
            ?? newThreadNotice
            ?? newThreadValidationError
            ?? "Creates a managed-daemon thread, then immediately starts its first turn."
    }

    private var newThreadValidationError: String? {
        guard onSubmitNewThread != nil,
              let snapshot = latestSnapshot,
              snapshot.connection != nil,
              snapshot.connection == controlAvailability.connection,
              snapshot.featureSupport.supports(.createThread),
              snapshot.featureSupport.supports(.followUp) else {
            return "New Chat requires a current qualified managed-daemon connection."
        }
        guard !isLoadingNewThreadModels else {
            return "Loading models from the current App Server."
        }
        guard newThreadModelCatalogConnection == snapshot.connection,
              selectedNewThreadModel != nil else {
            return "Choose a model from the current App Server catalog."
        }
        let directory = newThreadDraft.workingDirectory.trimmingCharacters(in: .whitespaces)
        guard !directory.isEmpty else { return "Set a Default workspace in Settings." }
        guard NSString(string: directory).isAbsolutePath,
              directory.utf8.count <= 4_096,
              !directory.unicodeScalars.contains(where: Self.isLineSeparator) else {
            return "Default workspace must be one bounded absolute path in Settings."
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "Default workspace does not exist or is not a directory. Update it in Settings."
        }
        let prompt = newThreadDraft.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return "Enter an initial prompt." }
        guard newThreadDraft.initialPrompt.utf8.count <= Self.maximumDraftUTF8Bytes else {
            return "Initial prompt is too large for the bounded New Chat composer."
        }
        return nil
    }

    var isExpanded: Bool { surfaceState == .expanded }
    var presentsExpandedContent: Bool {
        ShellExpandedContentPresentationPolicy.presentsExpandedContent(
            surface: surfaceState,
            isRevealReady: isExpandedContentRevealReady
        )
    }
    var canRequestSync: Bool { onRequestSync != nil }
    var canSetUpSharedDesktop: Bool {
        onSetUpSharedDesktop != nil && !isSettingUpSharedDesktop && !isDiagnosingSharedDesktop
    }
    var sharedDesktopCandidateThreads: [AppServerThreadPresentation] {
        guard sharedDesktopProofBaselineCaptured,
              sharedDesktopProofBaselineConnection == latestSnapshot?.connection else { return [] }
        return latestFirstThreads.filter {
            !sharedDesktopProofBaselineThreadIDs.contains($0.threadID)
        }
    }
    var sharedDesktopPresentation: SharedDesktopModePresentation? {
        sharedDesktopDiagnostics?.presentation
    }
    var sharedDesktopProofDetail: String {
        if !sharedDesktopProofBaselineCaptured {
            return "Capture the current inventory before creating the throwaway Desktop thread."
        }
        if sharedDesktopThreadProofStatus.didObserveNewEvent {
            return confirmsDesktopObservedCandidateEvent
                ? "Exact-thread activity was observed by Conn and confirmed in Desktop."
                : "Conn observed new exact-thread activity. Confirm that Desktop showed the same activity."
        }
        if sharedDesktopThreadProofStatus.isWaitingForNewEvent {
            return "Read-only resume passed. Now start one harmless turn in the throwaway Desktop task."
        }
        if sharedDesktopThreadProofStatus.didReadOnlyResume {
            return "Read-only resume passed; Conn is waiting beyond the exact resume boundary."
        }
        return "Create the Desktop thread, Sync Conn, attest its exact ID, then begin read-only proof."
    }
    var canBeginSharedDesktopThreadProof: Bool {
        guard sharedDesktopProofBaselineCaptured,
              attestsSharedDesktopCandidate,
              latestRuntimeStatus?.isThreadInventoryMembershipComplete == true,
              latestRuntimeStatus?.phase == .connected,
              let connection = latestSnapshot?.connection,
              sharedDesktopProofBaselineConnection == connection else { return false }
        let raw = sharedDesktopCandidateThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 512 else { return false }
        let threadID = AppServerThreadID(rawValue: raw)
        return !sharedDesktopProofBaselineThreadIDs.contains(threadID)
            && latestSnapshot?.threads.contains(where: { $0.id == threadID }) == true
    }
    var selectedDraftText: String {
        guard let selectedSessionID else { return "" }
        return controlPresentationState.draft(for: selectedSessionID).text
    }
    var phase9AffordancePolicy: ShellPhase9AffordancePolicy {
        guard let snapshot = latestSnapshot,
              let connection = snapshot.connection,
              connection == controlAvailability.connection else {
            return .init(detail: "Thread controls require a current qualified connection.")
        }
        if selectedProjectedThread == nil,
           let selectedSessionID,
           selectedSessionID == createdThreadPlaceholder?.id,
           createdThreadPlaceholderConnection == connection,
           snapshot.featureSupport.supports(.followUp) {
            let draft = selectedDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
            let draftIsValid = !draft.isEmpty
                && selectedDraftText.utf8.count <= Self.maximumDraftUTF8Bytes
            return .init(
                isComposerEnabled: !isPerformingAction,
                isSendEnabled: !isPerformingAction && draftIsValid,
                detail: isPerformingAction
                    ? "Waiting for the exact App Server acknowledgement."
                    : "Send starts the exact acknowledged empty thread."
            )
        }
        guard let thread = selectedProjectedThread,
              thread.freshness == .live else {
            return .init(detail: "Thread controls require a current qualified connection.")
        }
        // One shell action token exists at a time. A compact approval for a
        // non-selected thread must therefore gate selected-thread controls too,
        // or a second click could invalidate the first acknowledgement lease.
        let isPending = isPerformingAction
        let canFollowUp = snapshot.featureSupport.supports(.followUp)
            && thread.status == .idle
            && thread.activeTurnIDs.isEmpty
        let canSteer = snapshot.featureSupport.supports(.steer)
            && thread.activeTurnIDs.count == 1
        let composerEnabled = !isPending && (canFollowUp || canSteer)
        let draft = selectedDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftIsValid = !draft.isEmpty
            && selectedDraftText.utf8.count <= Self.maximumDraftUTF8Bytes
        let visibleRequest = selectedPresentation?.attention.flatMap { attention in
            thread.requests.first { $0.id == attention.scopedRequestID }
        }
        let responseAuthorized = visibleRequest.map(controlAvailability.mayRespond) ?? false
        let responseShapeSupported = selectedPresentation?.attention?.isResponseShapeSupported == true
        let approvalEnabled = !isPending
            && snapshot.featureSupport.supports(.resolveApproval)
            && visibleRequest?.kind != .structuredQuestion
            && responseAuthorized
            && responseShapeSupported
        let questionEnabled = !isPending
            && snapshot.featureSupport.supports(.answer)
            && visibleRequest?.kind == .structuredQuestion
            && responseAuthorized
            && responseShapeSupported
        let detail: String
        if isPending {
            detail = "Waiting for the exact App Server acknowledgement."
        } else if selectedDraftText.utf8.count > Self.maximumDraftUTF8Bytes {
            detail = "Draft is too large for the bounded notch composer."
        } else if canSteer {
            detail = "Send steers the exact active turn."
        } else if canFollowUp {
            detail = "Send starts a follow-up turn."
        } else if visibleRequest != nil, !responseAuthorized {
            detail = "Respond in the originating Codex client; selecting a thread does not grant response authority."
        } else {
            detail = "This thread has no currently supported control."
        }
        return .init(
            isComposerEnabled: composerEnabled,
            isSendEnabled: composerEnabled && draftIsValid,
            isStopEnabled: !isPending
                && snapshot.featureSupport.supports(.stopTurn)
                && thread.activeTurnIDs.count == 1,
            areApprovalResponsesEnabled: approvalEnabled,
            areQuestionResponsesEnabled: questionEnabled,
            detail: detail
        )
    }

    var needsIntegrationRepair: Bool {
        if integrationError != nil { return true }
        guard let connection = connectionPresentation else { return false }
        return connection.tone == .unavailable
    }

    var showsIntegrationDiagnostic: Bool {
        integrationError != nil || connectionPresentation?.showsDiagnostic == true
    }

    func publish(
        _ snapshot: AppServerProjectionSnapshot,
        threadModelSelections: [AppServerThreadID: AppServerThreadModelSelection] = [:],
        hooks: AppServerHookProjectionSnapshot = .init(
            connection: nil,
            freshness: .stale,
            configuredHooks: [],
            runsByThread: [:]
        ),
        legacyPluginCandidate: LegacySidequestPluginCandidate? = nil,
        legacyHookRetirementDiagnostic: String? = nil,
        runtimeStatus: AppServerRuntimeStatus,
        at date: Date = Date()
    ) {
        let connectionChanged = latestSnapshot?.connection != snapshot.connection
        if connectionChanged {
            // Remove connection-bound optimistic presentation before the
            // replacement snapshot can participate in selection or
            // qualification, including a coincidental raw thread-ID match.
            pendingCreatedThreadID = nil
            createdThreadPlaceholder = nil
            createdThreadPlaceholderConnection = nil
            newThreadSelectionTask?.cancel()
            resetUserFacingNotifications()
        }
        latestSnapshot = snapshot
        self.threadModelSelections = threadModelSelections
        hookVisibility = AppServerHookVisibilityPresentation(hooks)
        self.legacyPluginCandidate = legacyPluginCandidate
        if let pendingLegacyPluginCandidate,
           pendingLegacyPluginCandidate != legacyPluginCandidate {
            showsLegacyPluginRemovalConfirmation = false
        }
        self.legacyHookRetirementDiagnostic = legacyHookRetirementDiagnostic
        controlPresentationState.reconcile(with: snapshot)
        latestRuntimeStatus = runtimeStatus
        presentationDate = date
        if outcomeReviewLedger.reconcile(
            with: snapshot,
            hasCurrentAuthority: runtimeStatus.phase == .connected && snapshot.connection != nil,
            observedAt: date
        ) {
            _ = outcomeReviewStore.save(outcomeReviewLedger)
        }
        rebuildPresentation()
        reconcileManualOrdering()
        let selectedSessionIDBeforePassiveUpdate = selectedSessionID
        _ = selection.applyPassiveUpdate(
            availableSessionIDs: sessions.map(\.id)
        )
        selectedSessionID = selection.selectedSessionID
        selectCreatedThreadIfAvailable()
        if selectedSessionID != selectedSessionIDBeforePassiveUpdate {
            // Timeline materialization is selection-sensitive. Refresh the
            // projection immediately instead of waiting for another runtime
            // publication that may never arrive for an already-cached task.
            rebuildPresentation()
        }
        if connectionChanged {
            resetSharedDesktopProofForConnectionChange(snapshot.connection)
            invalidateNewThreadModelCatalog()
            advanceControlSelectionGeneration()
            if showsNewThreadComposer {
                requestNewThreadModels()
            }
        }
        // Passive metadata publication may establish a visual fallback, but it
        // must never trigger thread/read or thread/resume. Qualification is
        // reserved for an explicit row selection below.
    }

    func setDisplays(
        _ displays: [DisplayChoice],
        panelPlacement: ShellPanelPlacement
    ) {
        availableDisplays = displays
        self.panelPlacement = panelPlacement
    }

    func setSurfaceState(_ state: ShellSurfaceState) {
        surfaceGeometryTransitionGate.invalidate()
        isExpandedContentRevealReady = state == .expanded
        isSurfaceGeometryTransitionInFlight = false
        surfaceState = state
        if state == .compact { reconcileCompactShelf() }
        onCompactShelfVisibilityChanged?(state == .compact && compactShelf != nil)
    }

    @discardableResult
    func beginSurfaceGeometryTransition(
        to state: ShellSurfaceState
    ) -> ShellSurfaceGeometryTransitionGeneration {
        let generation = surfaceGeometryTransitionGate.begin()
        // Publish the transition guard first. When expansion begins, SwiftUI
        // must never observe an expanded surface with its heavy content mounted.
        isExpandedContentRevealReady = false
        isSurfaceGeometryTransitionInFlight = true
        surfaceState = state
        if state == .compact { reconcileCompactShelf() }
        return generation
    }

    func revealExpandedContentDuringGeometryTransition(
        _ generation: ShellSurfaceGeometryTransitionGeneration
    ) {
        guard surfaceGeometryTransitionGate.isCurrent(generation),
              surfaceState == .expanded,
              isSurfaceGeometryTransitionInFlight else { return }
        isExpandedContentRevealReady = true
    }

    func completeSurfaceGeometryTransition(
        to state: ShellSurfaceState,
        generation: ShellSurfaceGeometryTransitionGeneration
    ) {
        guard surfaceGeometryTransitionGate.isCurrent(generation),
              surfaceState == state else { return }
        isExpandedContentRevealReady = state == .expanded
        isSurfaceGeometryTransitionInFlight = false
    }

    var compactShelfPreferredHeight: CGFloat {
        if compactShelf?.mode == .approval { return 68 }
        return compactNotificationBatch?.preferredHeight ?? 36
    }

    func requestSharedDesktopDiagnosis() {
        guard sharedDesktopLabsEnabled else {
            sharedDesktopDiagnosisGate.invalidate(isLabsFeatureEnabled: false)
            isDiagnosingSharedDesktop = false
            sharedDesktopDiagnostics = nil
            sharedDesktopDiagnosticsLease = nil
            sharedDesktopPromptNotice = nil
            resetSharedDesktopProofForConnectionChange(latestSnapshot?.connection)
            onCancelSharedDesktopThreadProof?()
            rebuildPresentation()
            return
        }
        guard let onDiagnoseSharedDesktop else {
            isDiagnosingSharedDesktop = false
            sharedDesktopPromptNotice = "Shared Desktop diagnostics are unavailable."
            return
        }
        let generation = sharedDesktopDiagnosisGate.begin(
            isLabsFeatureEnabled: sharedDesktopLabsEnabled
        )
        isDiagnosingSharedDesktop = true
        sharedDesktopPromptNotice = nil
        onDiagnoseSharedDesktop(sharedDesktopLabsEnabled, generation)
    }

    func openSharedDesktopLabs() {
        showsSettings = false
        showsSharedDesktopLabs = true
        if !sharedDesktopLabsEnabled {
            sharedDesktopLabsEnabled = true
        } else {
            requestSharedDesktopDiagnosis()
        }
    }

    func beginSharedDesktopSetup() {
        guard canSetUpSharedDesktop else { return }
        isSettingUpSharedDesktop = true
        sharedDesktopSetupEnabled = true
        sharedDesktopSetupExplicitlyDisabled = false
        UserDefaults.standard.set(true, forKey: Self.sharedDesktopSetupPreferenceKey)
        UserDefaults.standard.set(false, forKey: Self.sharedDesktopDisabledPreferenceKey)
        sharedDesktopSetupResult = nil
        sharedDesktopPromptNotice = "Setting up the current-user shared socket…"
        onSetUpSharedDesktop?()
    }

    func finishSharedDesktopSetup(_ result: SharedDesktopSetupResult) {
        isSettingUpSharedDesktop = false
        sharedDesktopSetupResult = result
        if result.outcome == .ready
            || result.outcome == .relaunchRequired
            || result.outcome == .partial {
            sharedDesktopSetupEnabled = true
            sharedDesktopSetupExplicitlyDisabled = false
            UserDefaults.standard.set(true, forKey: Self.sharedDesktopSetupPreferenceKey)
            UserDefaults.standard.set(false, forKey: Self.sharedDesktopDisabledPreferenceKey)
        } else {
            sharedDesktopSetupEnabled = false
            UserDefaults.standard.set(false, forKey: Self.sharedDesktopSetupPreferenceKey)
        }
        sharedDesktopPromptNotice = switch result.outcome {
        case .ready: "Setup and socket diagnosis passed."
        case .relaunchRequired: "Setup passed. Relaunch Codex Desktop once, then run Diagnose."
        case .disabled: "Shared Desktop is off."
        case .partial: "Setup could not be verified and persistent state may remain. Use Turn off."
        case .blocked: "Setup was blocked to preserve an existing configuration."
        case .failed: "Setup did not pass every safety check. Review the activity log."
        }
        requestSharedDesktopDiagnosis()
    }

    func beginSharedDesktopTurnOff() {
        guard !isSettingUpSharedDesktop, !isDiagnosingSharedDesktop,
              onTurnOffSharedDesktop != nil else { return }
        isSettingUpSharedDesktop = true
        sharedDesktopSetupEnabled = false
        sharedDesktopSetupExplicitlyDisabled = true
        UserDefaults.standard.set(false, forKey: Self.sharedDesktopSetupPreferenceKey)
        UserDefaults.standard.set(true, forKey: Self.sharedDesktopDisabledPreferenceKey)
        sharedDesktopSetupResult = nil
        sharedDesktopPromptNotice = "Turning off Conn's shared-daemon preference…"
        onTurnOffSharedDesktop?()
    }

    func finishSharedDesktopTurnOff(_ result: SharedDesktopSetupResult) {
        isSettingUpSharedDesktop = false
        sharedDesktopSetupResult = result
        if result.outcome == .disabled {
            sharedDesktopSetupEnabled = false
            sharedDesktopSetupExplicitlyDisabled = true
            UserDefaults.standard.set(false, forKey: Self.sharedDesktopSetupPreferenceKey)
            UserDefaults.standard.set(true, forKey: Self.sharedDesktopDisabledPreferenceKey)
            sharedDesktopPromptNotice = "Shared Desktop is off. Relaunch Codex once to return to its default transport."
        } else {
            sharedDesktopPromptNotice = "Shared Desktop could not be turned off safely. Review the activity log."
        }
        requestSharedDesktopDiagnosis()
    }

    @discardableResult
    func finishSharedDesktopDiagnosis(
        _ snapshot: SharedDesktopDiagnosticsSnapshot,
        generation: SharedDesktopDiagnosisGeneration
    ) -> Bool {
        guard sharedDesktopDiagnosisGate.accepts(generation),
              snapshot.evidence.isLabsFeatureEnabled == sharedDesktopLabsEnabled else {
            return false
        }
        isDiagnosingSharedDesktop = false
        sharedDesktopDiagnostics = snapshot
        sharedDesktopDiagnosticsLease = .init(observedAt: Date())
        rebuildPresentation()
        return true
    }

    func refreshSharedDesktopDiagnosticsFreshness() {
        rebuildPresentation()
    }

    func captureSharedDesktopProofBaseline() {
        guard latestRuntimeStatus?.phase == .connected,
              latestRuntimeStatus?.isThreadInventoryMembershipComplete == true,
              let latestSnapshot else {
            sharedDesktopPromptNotice = "A complete current daemon inventory is required before verification."
            return
        }
        sharedDesktopProofBaselineThreadIDs = Set(latestSnapshot.threads.map(\.id))
        sharedDesktopProofBaselineConnection = latestSnapshot.connection
        sharedDesktopProofBaselineCaptured = true
        sharedDesktopCandidateThreadID = ""
        attestsSharedDesktopCandidate = false
        confirmsDesktopObservedCandidateEvent = false
        sharedDesktopPromptNotice = "Baseline captured. Create a new throwaway task in Desktop, then Sync Conn."
    }

    func beginSharedDesktopThreadProof() {
        guard canBeginSharedDesktopThreadProof else {
            sharedDesktopPromptNotice = "The candidate must be a new exact thread in the current authoritative inventory."
            return
        }
        let raw = sharedDesktopCandidateThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        confirmsDesktopObservedCandidateEvent = false
        onBeginSharedDesktopThreadProof?(raw)
    }

    @discardableResult
    func publishSharedDesktopThreadProofStatus(
        _ status: AppServerSharedDesktopThreadProofStatus
    ) -> Bool {
        guard status != sharedDesktopThreadProofStatus else { return false }
        sharedDesktopThreadProofStatus = status
        return true
    }

    func confirmDesktopObservedCandidateEvent() {
        guard sharedDesktopThreadProofStatus.didObserveNewEvent else { return }
        confirmsDesktopObservedCandidateEvent = true
    }

    func sharedDesktopCandidateEvidence() -> SharedDesktopThreadCandidateEvidence? {
        let raw = sharedDesktopCandidateThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard attestsSharedDesktopCandidate,
              !raw.isEmpty,
              raw.utf8.count <= 512,
              let connection = latestSnapshot?.connection,
              sharedDesktopProofBaselineConnection == connection,
              sharedDesktopThreadProofStatus.connection == connection else { return nil }
        let threadID = AppServerThreadID(rawValue: raw)
        return .init(
            threadID: threadID,
            userAttestedDesktopOrigin: true,
            authoritativeDiscoveryThreadIDs: Set(latestSnapshot?.threads.map(\.id) ?? []),
            resumedThreadID: sharedDesktopThreadProofStatus.didReadOnlyResume
                ? sharedDesktopThreadProofStatus.threadID : nil,
            resumeStartedTurn: false,
            resumeTookOwnership: false,
            resumeSentConsequentialAction: false,
            newEventThreadID: sharedDesktopThreadProofStatus.didObserveNewEvent
                ? sharedDesktopThreadProofStatus.threadID : nil
        )
    }

    private func resetSharedDesktopProofForConnectionChange(
        _ connection: AppServerConnectionIdentity?
    ) {
        sharedDesktopProofBaselineThreadIDs.removeAll()
        sharedDesktopProofBaselineConnection = nil
        sharedDesktopProofBaselineCaptured = false
        sharedDesktopCandidateThreadID = ""
        attestsSharedDesktopCandidate = false
        confirmsDesktopObservedCandidateEvent = false
        sharedDesktopThreadProofStatus = .init(
            connection: connection,
            threadID: nil,
            didReadOnlyResume: false,
            isWaitingForNewEvent: false,
            didObserveNewEvent: false
        )
    }

    @discardableResult
    func copySharedDesktopSetupPrompt() -> Bool {
        guard let url = Bundle.main.url(
            forResource: "shared-desktop-agent-prompt",
            withExtension: "md"
        ), let data = try? Data(contentsOf: url),
           data.count <= Self.maximumSetupPromptBytes,
           let prompt = String(data: data, encoding: .utf8),
           !prompt.isEmpty else {
            sharedDesktopPromptNotice = "The packaged setup prompt is unavailable."
            return false
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(prompt, forType: .string) else {
            sharedDesktopPromptNotice = "Conn could not copy the setup prompt."
            return false
        }
        sharedDesktopPromptNotice = "Bounded setup prompt copied. It diagnoses first and asks before every persistent change."
        return true
    }

    func beginInteraction() {
        selection.beginUserInteraction()
    }

    func endInteraction() {
        let previousSessionID = selectedSessionID
        _ = selection.endUserInteraction()
        selectedSessionID = selection.selectedSessionID
        if selectedSessionID != previousSessionID {
            rebuildPresentation()
        }
    }

    func selectSession(_ sessionID: String) {
        let previousSessionID = selectedSessionID
        let didSelect = selection.selectSession(
            sessionID,
            availableSessionIDs: sessions.map(\.id)
        )
        if didSelect {
            showsNewThreadComposer = false
            selectedSessionID = selection.selectedSessionID
            if selectedSessionID != previousSessionID {
                advanceControlSelectionGeneration()
                rebuildPresentation()
            }
            if let selectedSessionID {
                onQualifySelectedSession?(selectedSessionID)
            }
        }
        reviewCurrentOutcomeIfNeeded(for: sessionID)
    }

    func qualifySelectedSessionForExpandedPresentation() {
        let threadID = selectedSessionID.map(AppServerThreadID.init(rawValue:))
        guard AppServerThreadModelQualificationPolicy.shouldRequestForExpandedPresentation(
            selectedThreadID: threadID,
            knownSelections: threadModelSelections
        ), let selectedSessionID else { return }
        onQualifySelectedSession?(selectedSessionID)
    }

    func openSession(_ sessionID: String) {
        selectSession(sessionID)
        onRequestExpansion?()
    }

    func openCompactNotification(threadID: AppServerThreadID) {
        clearCompactShelf()
        openSession(threadID.rawValue)
    }

    /// Presents an already-projected attention card without turning a passive
    /// update into thread qualification. Only explicit user selection may ask
    /// the runtime to read or resume a thread.
    private func presentProjectedSession(_ sessionID: String) {
        let previousSessionID = selectedSessionID
        guard selection.selectSession(
            sessionID,
            availableSessionIDs: sessions.map(\.id)
        ) else { return }
        selectedSessionID = selection.selectedSessionID
        if selectedSessionID != previousSessionID {
            advanceControlSelectionGeneration()
            rebuildPresentation()
        }
        onRequestExpansion?()
    }

    func requestSync() {
        onRequestSync?()
    }

    func requestLegacyPluginRemovalConfirmation() {
        guard let legacyPluginCandidate, !isRemovingLegacyPlugin else { return }
        pendingLegacyPluginCandidate = legacyPluginCandidate
        showsLegacyPluginRemovalConfirmation = true
    }

    func confirmLegacyPluginRemoval() {
        guard let pendingLegacyPluginCandidate,
              pendingLegacyPluginCandidate == legacyPluginCandidate,
              !isRemovingLegacyPlugin,
              onUninstallLegacyPlugin != nil else { return }
        isRemovingLegacyPlugin = true
        showsLegacyPluginRemovalConfirmation = false
        legacyPluginRetirementNotice = nil
        onUninstallLegacyPlugin?(pendingLegacyPluginCandidate)
        self.pendingLegacyPluginCandidate = nil
    }

    func finishLegacyPluginRemoval(_ outcome: LegacySidequestPluginUninstallOutcome) {
        isRemovingLegacyPlugin = false
        pendingLegacyPluginCandidate = nil
        switch outcome {
        case .removed:
            legacyPluginCandidate = nil
            legacyPluginRetirementNotice = "Legacy Sidequest plugin removed. Managed-daemon threads were unchanged."
        case .stillInstalled:
            legacyPluginRetirementNotice = "App Server still reports the legacy plugin. Remove its exact selector manually in Codex /plugins."
        case .staleConfirmation:
            legacyPluginRetirementNotice = "The connection or plugin identity changed. Sync before confirming again."
        case .alreadyAttempted:
            legacyPluginRetirementNotice = "Conn will not retry that uninstall because its acknowledgement is uncertain. Check Codex /plugins."
        case .acknowledgementUncertain:
            legacyPluginRetirementNotice = "Plugin uninstall acknowledgement is uncertain. Conn will not retry it; verify in Codex /plugins."
        case .unsupported:
            legacyPluginRetirementNotice = "This App Server cannot uninstall the plugin. Remove its exact selector manually in Codex /plugins."
        }
    }

    func showNewThread() {
        newThreadError = nil
        newThreadNotice = nil
        let workspace = AppServerNewChatWorkspacePolicy.resolveDefaultWorkspace(defaultWorkspace)
        if newThreadDraft.workingDirectory != workspace {
            newThreadDraft.updateWorkingDirectory(workspace)
        }
        showsNewThreadComposer = true
        onRequestExpansion?()
        requestNewThreadModels()
    }

    /// Every New Chat entry point opens the explicit composer. Creating an
    /// empty server-default thread here would bypass the required model choice.
    func startNewChat() {
        showNewThread()
    }

    func cancelNewThread() {
        guard !isCreatingThread else { return }
        showsNewThreadComposer = false
        newThreadError = nil
        newThreadNotice = nil
    }

    func updateNewThreadWorkingDirectory(_ value: String) {
        guard !isCreatingThread else { return }
        newThreadDraft.updateWorkingDirectory(value)
        newThreadError = nil
        newThreadNotice = nil
    }

    func updateNewThreadInitialPrompt(_ value: String) {
        guard !isCreatingThread else { return }
        newThreadDraft.updateInitialPrompt(value)
        newThreadError = nil
        newThreadNotice = nil
    }

    func updateNewThreadModel(_ modelID: String?) {
        guard !isCreatingThread,
              modelID == nil || newThreadModelOptions.contains(where: { $0.id == modelID })
        else { return }
        newThreadDraft.updateSelectedModelID(modelID)
        preferredNewThreadModelID = modelID
        if let modelID {
            UserDefaults.standard.set(modelID, forKey: Self.preferredNewThreadModelPreferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.preferredNewThreadModelPreferenceKey)
        }
        newThreadError = nil
        newThreadNotice = nil
    }

    func updateSelectedFollowUpModel(_ modelID: String?) {
        guard canSelectFollowUpModel,
              let selectedSessionID,
              modelID == nil || newThreadModelOptions.contains(where: { $0.id == modelID })
        else { return }
        if let modelID {
            followUpModelOverrideIDByThread[selectedSessionID] = modelID
        } else {
            followUpModelOverrideIDByThread.removeValue(forKey: selectedSessionID)
        }
    }

    func requestComposerModels() {
        guard let connection = latestSnapshot?.connection,
              newThreadModelCatalogConnection != connection || newThreadModelOptions.isEmpty
        else { return }
        requestNewThreadModels()
    }

    func requestNewThreadModels() {
        guard !isCreatingThread,
              !isLoadingNewThreadModels,
              onRequestNewThreadModels != nil else { return }
        isLoadingNewThreadModels = true
        newThreadModelError = nil
        newThreadModelLoadGeneration &+= 1
        onRequestNewThreadModels?(newThreadModelLoadGeneration)
    }

    func finishNewThreadModelLoading(
        _ result: AppServerNewThreadModelCatalogResult,
        generation: UInt64
    ) {
        guard generation == newThreadModelLoadGeneration else { return }
        isLoadingNewThreadModels = false
        guard result.outcome == .available,
              let catalog = result.catalog,
              catalog.connection == latestSnapshot?.connection else {
            newThreadModelOptions = []
            newThreadModelCatalogConnection = nil
            followUpModelOverrideIDByThread.removeAll()
            switch result.outcome {
            case .connectionInvalidated:
                newThreadModelError = "The connection changed while loading models. Retry on the current connection."
            case .invalidResponse:
                newThreadModelError = "App Server returned an invalid model catalog."
            case .unavailable, .available:
                newThreadModelError = "Models are unavailable from the current App Server."
            }
            return
        }

        newThreadModelOptions = catalog.options
        newThreadModelCatalogConnection = catalog.connection
        newThreadModelError = nil
        let availableIDs = Set(catalog.options.map(\.id))
        followUpModelOverrideIDByThread = followUpModelOverrideIDByThread.filter {
            availableIDs.contains($0.value)
        }
        let resolution = AppServerNewThreadModelSelectionPolicy.resolve(
            options: catalog.options,
            currentSelectionID: newThreadDraft.selectedModelID,
            preferredSelectionID: preferredNewThreadModelID
        )
        newThreadDraft.updateSelectedModelID(resolution.selectedID)
        if resolution.preferredModelIsUnavailable {
            newThreadModelError = "The last selected model is unavailable. Review the current default before creating this chat."
        }
    }

    func submitNewThread() {
        guard canSubmitNewThread else { return }
        guard let selectedModel = selectedNewThreadModel else { return }
        preferredNewThreadModelID = selectedModel.id
        UserDefaults.standard.set(
            selectedModel.id,
            forKey: Self.preferredNewThreadModelPreferenceKey
        )
        let directory = URL(
            fileURLWithPath: newThreadDraft.workingDirectory.trimmingCharacters(in: .whitespaces)
        ).standardizedFileURL.path
        let prompt = newThreadDraft.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreatingThread = true
        newThreadError = nil
        newThreadNotice = nil
        onSubmitNewThread?(.init(
            workingDirectory: directory,
            initialPrompt: prompt,
            modelID: selectedModel.id,
            model: selectedModel.model,
            draftRevision: newThreadDraft.revision
        ))
    }

    private func invalidateNewThreadModelCatalog() {
        newThreadModelLoadGeneration &+= 1
        newThreadModelOptions = []
        newThreadModelCatalogConnection = nil
        followUpModelOverrideIDByThread.removeAll()
        newThreadModelError = nil
        isLoadingNewThreadModels = false
    }

    func finishNewThreadCreation(_ result: AppServerNewThreadExecutionResult) {
        guard result.draftRevision == newThreadDraft.revision else {
            isCreatingThread = false
            if result.outcome == .accepted, let threadID = result.createdThreadID {
                prepareCreatedThread(
                    threadID.rawValue,
                    workingDirectory: newThreadDraft.workingDirectory,
                    connection: latestSnapshot?.connection
                )
            }
            return
        }
        isCreatingThread = false
        switch result.outcome {
        case .accepted:
            let submittedWorkingDirectory = newThreadDraft.workingDirectory
            newThreadDraft.apply(result)
            showsNewThreadComposer = false
            newThreadError = nil
            newThreadNotice = "New thread created."
            if let threadID = result.createdThreadID {
                prepareCreatedThread(
                    threadID.rawValue,
                    workingDirectory: submittedWorkingDirectory,
                    connection: latestSnapshot?.connection
                )
            }
        case .duplicateSuppressed:
            newThreadNotice = "That exact New Chat attempt is already pending."
        case .acknowledgementUncertain:
            newThreadError = result.createdThreadID == nil
                ? "Thread creation is acknowledgement-uncertain. The unchanged draft will not be resent; edit it to make a new explicit attempt."
                : "The first turn is acknowledgement-uncertain. Conn retained the exact created thread and will not resend the unchanged attempt."
        case .acknowledgementTimedOut:
            newThreadError = result.stage == .threadStart
                ? "App Server did not acknowledge thread creation. Your draft is preserved and the unchanged attempt is locked against resend."
                : "A thread was allocated, but its first turn was not acknowledged. Your draft is preserved and will not be resent unchanged."
        case .connectionInvalidated:
            newThreadError = result.createdThreadID == nil
                ? "The connection changed during New Chat. Nothing was retargeted; your draft is preserved."
                : "The connection changed after allocating a thread. Conn did not retarget or repeat its first turn; your draft is preserved."
        case .rejected, .stalePrecondition:
            newThreadError = result.stage == .threadStart
                ? "App Server rejected New Chat before a thread was confirmed. Your draft is preserved."
                : "A thread was allocated, but App Server rejected its first turn. The unchanged attempt will not create another thread."
        case .resolvedElsewhere, .terminalStateUnconfirmed:
            newThreadError = "New Chat could not be completed safely. Your draft is preserved."
        }
    }

    func isProjectExpanded(_ projectID: String) -> Bool {
        !collapsedProjectIDs.contains(projectID)
    }

    func toggleProject(_ projectID: String) {
        if collapsedProjectIDs.contains(projectID) {
            collapsedProjectIDs.remove(projectID)
        } else {
            collapsedProjectIDs.insert(projectID)
        }
        UserDefaults.standard.set(
            collapsedProjectIDs.sorted(),
            forKey: Self.collapsedProjectsPreferenceKey
        )
    }

    func orderedThreads(in project: AppServerProjectPresentation) -> [AppServerThreadPresentation] {
        let rank = Dictionary(uniqueKeysWithValues: visibleThreadOrder.enumerated().map { ($1, $0) })
        return project.threads.sorted {
            let lhs = rank[$0.id] ?? Int.max
            let rhs = rank[$1.id] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    @discardableResult
    func moveThread(
        _ threadID: String,
        relativeTo targetID: String,
        placement: ShellOrderPlacement,
        withinProjectID projectID: String? = nil
    ) -> Bool {
        if let projectID {
            guard projectIDForThread(threadID) == projectID,
                  projectIDForThread(targetID) == projectID else { return false }
        }
        var candidate = threadOrder
        guard candidate.move(
            threadID,
            relativeTo: targetID,
            placement: placement,
            fromVisibleOrder: visibleThreadOrder
        ) else { return false }
        threadOrder = candidate
        save(threadOrder, forKey: Self.threadOrderPreferenceKey)
        return true
    }

    @discardableResult
    func moveProject(
        _ projectID: String,
        relativeTo targetID: String,
        placement: ShellOrderPlacement
    ) -> Bool {
        var candidate = projectOrder
        guard candidate.move(
            projectID,
            relativeTo: targetID,
            placement: placement,
            fromVisibleOrder: visibleProjectOrder
        ) else { return false }
        projectOrder = candidate
        save(projectOrder, forKey: Self.projectOrderPreferenceKey)
        return true
    }

    @discardableResult
    func moveThread(
        _ threadID: String,
        direction: ShellOrderStepDirection,
        withinProjectID projectID: String? = nil
    ) -> Bool {
        let fullVisibleOrder = visibleThreadOrder
        var candidate = threadOrder
        let didMove: Bool
        if let projectID,
           let project = projects.first(where: { $0.id == projectID }) {
            didMove = candidate.move(
                threadID,
                direction: direction,
                within: orderedThreads(in: project).map(\.id),
                fromVisibleOrder: fullVisibleOrder
            )
        } else {
            didMove = candidate.move(
                threadID,
                direction: direction,
                within: fullVisibleOrder,
                fromVisibleOrder: fullVisibleOrder
            )
        }
        guard didMove else { return false }
        threadOrder = candidate
        save(threadOrder, forKey: Self.threadOrderPreferenceKey)
        return true
    }

    private func projectIDForThread(_ threadID: String) -> String? {
        projects.first { project in
            project.threads.contains { $0.id == threadID }
        }?.id
    }

    @discardableResult
    func moveProject(_ projectID: String, direction: ShellOrderStepDirection) -> Bool {
        let visibleOrder = visibleProjectOrder
        var candidate = projectOrder
        guard candidate.move(
            projectID,
            direction: direction,
            within: visibleOrder,
            fromVisibleOrder: visibleOrder
        ) else { return false }
        projectOrder = candidate
        save(projectOrder, forKey: Self.projectOrderPreferenceKey)
        return true
    }

    func openCodex() {
        let token = beginAction(contextID: selectedSessionID, isPerforming: false)
        onOpenCodex?(token)
    }

    @discardableResult
    func finishOpenCodex(
        _ token: ShellActionToken,
        error: String? = nil
    ) -> ShellActionPresentationEffect {
        finishAction(
            token,
            outcome: error == nil ? .success : .failure,
            error: error,
            collapseOnSuccess: false
        )
    }

    /// Starts a token-bound asynchronous action for Phase 9+ callers. Every
    /// terminal path must call `finishAction(_:outcome:error:notice:)`.
    @discardableResult
    func beginAction(
        contextID: String?,
        isPerforming: Bool = true
    ) -> ShellActionToken {
        let token = actionState.begin(
            contextID: contextID,
            isPerforming: isPerforming
        )
        actionSessionID = contextID
        actionError = nil
        actionNotice = nil
        self.isPerformingAction = isPerforming
        return token
    }

    @discardableResult
    func finishAction(
        _ token: ShellActionToken,
        outcome: ShellActionTerminalOutcome,
        error: String? = nil,
        notice: String? = nil,
        collapseOnSuccess: Bool = false
    ) -> ShellActionPresentationEffect {
        let effect = actionState.finish(
            token,
            outcome: outcome,
            collapseOnSuccess: collapseOnSuccess
        )
        guard effect != .ignored else { return .ignored }
        isPerformingAction = false
        actionError = error
        actionNotice = notice
        return effect
    }

    func invalidateActions() {
        actionState.invalidate()
        actionSessionID = nil
        isPerformingAction = false
        actionError = nil
        actionNotice = nil
    }

    func setControlAvailability(_ availability: AppServerThreadControlAvailability) {
        controlAvailability = availability
        reconcileCompactShelf()
    }

    func updateSelectedDraft(_ text: String) {
        guard let selectedSessionID else { return }
        controlPresentationState.updateDraft(text, threadID: selectedSessionID)
    }

    func submitSelectedDraft() {
        guard !selectedActionIsInProgress,
              phase9AffordancePolicy.isSendEnabled,
              let selectedSessionID,
              !controlPresentationState.draft(for: selectedSessionID).text.isEmpty
        else { return }
        let draft = controlPresentationState.draft(for: selectedSessionID)
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedFollowUpModel = selectedFollowUpModelID.flatMap { selectedID in
            newThreadModelOptions.first(where: { $0.id == selectedID })?.model
        }
        let intent: AppServerControlIntent
        if let thread = selectedProjectedThread,
           thread.status == .idle, thread.activeTurnIDs.isEmpty {
            intent = .followUp(
                threadID: thread.id,
                text: text,
                model: selectedFollowUpModel,
                draftRevision: draft.revision
            )
        } else if let thread = selectedProjectedThread,
                  thread.activeTurnIDs.count == 1,
                  let turnID = thread.activeTurnIDs.first {
            intent = .steer(
                threadID: thread.id,
                expectedTurnID: turnID,
                text: text,
                draftRevision: draft.revision
            )
        } else if selectedSessionID == createdThreadPlaceholder?.id,
                  createdThreadPlaceholderConnection == latestSnapshot?.connection {
            intent = .followUp(
                threadID: .init(rawValue: selectedSessionID),
                text: text,
                model: selectedFollowUpModel,
                draftRevision: draft.revision
            )
        } else { return }
        controlPresentationState.clearOutcome(for: selectedSessionID)
        let token = beginAction(contextID: selectedSessionID)
        onSubmitControl?(intent, selectionGeneration, token)
    }

    func stopSelectedTurn() {
        guard !selectedActionIsInProgress,
              phase9AffordancePolicy.isStopEnabled,
              let selectedSessionID,
              let thread = selectedProjectedThread,
              thread.activeTurnIDs.count == 1,
              let turnID = thread.activeTurnIDs.first else { return }
        controlPresentationState.clearOutcome(for: selectedSessionID)
        let token = beginAction(contextID: selectedSessionID)
        onSubmitControl?(
            .interrupt(threadID: thread.id, expectedTurnID: turnID),
            selectionGeneration,
            token
        )
    }

    func respondToSelectedApproval(_ choice: AppServerApprovalChoice) {
        guard !selectedActionIsInProgress,
              phase9AffordancePolicy.areApprovalResponsesEnabled,
              let selectedSessionID,
              let attention = selectedPresentation?.attention,
              attention.availableApprovalChoices.contains(choice) else { return }
        controlPresentationState.clearOutcome(for: selectedSessionID)
        let token = beginAction(contextID: selectedSessionID)
        onSubmitControl?(
            .decide(
                request: attention.scopedRequestID,
                threadID: attention.threadID,
                turnID: attention.turnID,
                choice: choice
            ),
            selectionGeneration,
            token
        )
    }

    func respondToCompactApproval(_ choice: AppServerApprovalChoice) {
        guard !isPerformingAction,
              let shelf = compactShelf,
              shelf.mode == .approval,
              shelf.approvalChoices.contains(choice),
              let requestID = shelf.requestID,
              let snapshot = latestSnapshot,
              snapshot.connection == controlAvailability.connection,
              snapshot.featureSupport.supports(.resolveApproval),
              let thread = snapshot.threads.first(where: { $0.id == shelf.threadID }),
              let request = thread.requests.first(where: { $0.id == requestID }),
              controlAvailability.mayRespond(to: request),
              let attention = presentation?.urgencySortedThreads
                .first(where: { $0.threadID == shelf.threadID })?.attention,
              attention.scopedRequestID == requestID,
              attention.isResponseShapeSupported,
              attention.availableApprovalChoices.contains(choice),
              ShellCompactApprovalPolicy.visibleChoices(
                from: attention.availableApprovalChoices
              ).contains(choice)
        else {
            if let shelf = compactShelf { openSession(shelf.threadID.rawValue) }
            return
        }
        let token = beginAction(contextID: shelf.threadID.rawValue)
        onSubmitControl?(
            .decide(
                request: requestID,
                threadID: shelf.threadID,
                turnID: shelf.turnID,
                choice: choice
            ),
            selectionGeneration,
            token
        )
    }

    func questionAnswer(
        request: AppServerScopedRequestID,
        questionID: String
    ) -> String {
        controlPresentationState.questionAnswer(request: request, questionID: questionID)
    }

    func updateQuestionAnswer(
        _ value: String,
        request: AppServerScopedRequestID,
        questionID: String
    ) {
        controlPresentationState.updateQuestionAnswer(
            value,
            request: request,
            questionID: questionID
        )
    }

    func answerSelectedQuestions() {
        guard !selectedActionIsInProgress,
              phase9AffordancePolicy.areQuestionResponsesEnabled,
              let selectedSessionID,
              let attention = selectedPresentation?.attention else { return }
        let values = controlPresentationState.questionAnswers(for: attention.scopedRequestID)
        guard attention.questions.allSatisfy({ question in
            values[question.id]?.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } == true
        }) else {
            actionSessionID = selectedSessionID
            actionError = "Answer every question before submitting."
            return
        }
        controlPresentationState.clearOutcome(for: selectedSessionID)
        let token = beginAction(contextID: selectedSessionID)
        onSubmitControl?(
            .answer(
                request: attention.scopedRequestID,
                threadID: attention.threadID,
                turnID: attention.turnID,
                answers: .init(valuesByQuestionID: values)
            ),
            selectionGeneration,
            token
        )
    }

    @discardableResult
    func finishControlAction(
        _ token: ShellActionToken,
        intent: AppServerControlIntent,
        result: AppServerControlExecutionResult
    ) -> ShellActionPresentationEffect {
        let outcome: ShellActionTerminalOutcome
        let error: String?
        let notice: String?
        switch result.outcome {
        case .accepted:
            (outcome, error, notice) = (.success, nil, "App Server acknowledged the action.")
        case .resolvedElsewhere:
            (outcome, error, notice) = (.cancelled, nil, "This request was already resolved elsewhere.")
        case .stalePrecondition:
            (outcome, error, notice) = (
                .rejected,
                "The thread changed before Conn could send. Its latest state has been reconciled.",
                nil
            )
        case .duplicateSuppressed:
            (outcome, error, notice) = (.cancelled, nil, "That exact action is already pending.")
        case .acknowledgementUncertain:
            (outcome, error, notice) = (
                .cancelled,
                nil,
                "That unchanged draft was not resent because its earlier acknowledgement timed out. Conn confirmed newer projection facts or performed one bounded reconcile; edit the draft or retry only if the thread remains idle."
            )
        case .acknowledgementTimedOut:
            (outcome, error, notice) = (
                .failure,
                "App Server did not acknowledge the action before the deadline. Your draft is preserved.",
                nil
            )
        case .connectionInvalidated:
            (outcome, error, notice) = (
                .cancelled,
                "The connection or selection changed. Nothing was retargeted or queued.",
                nil
            )
        case .rejected:
            (outcome, error, notice) = (
                .rejected,
                "App Server rejected the action. Your draft is preserved.",
                nil
            )
        case .terminalStateUnconfirmed:
            (outcome, error, notice) = (
                .failure,
                "Stop was acknowledged, but terminal state could not be confirmed by thread/read.",
                nil
            )
        }
        controlPresentationState.applyCompletion(
            intent: intent,
            result: result,
            error: error,
            notice: notice
        )
        if result.outcome == .accepted,
           case let .followUp(threadID, _, model, _) = intent,
           model != nil {
            followUpModelOverrideIDByThread.removeValue(forKey: threadID.rawValue)
        }
        let effect = finishAction(token, outcome: outcome, error: error, notice: notice)
        return effect
    }

    private func advanceControlSelectionGeneration() {
        selectionGeneration &+= 1
        invalidateActions()
        onControlSelectionChanged?(selectionGeneration)
    }

    func markSelectedOutcomeReviewed() {
        guard let selectedSessionID else { return }
        reviewCurrentOutcomeIfNeeded(for: selectedSessionID)
    }

    private func reviewCurrentOutcomeIfNeeded(for sessionID: String) {
        guard let thread = latestSnapshot?.threads.first(where: {
            $0.id.rawValue == sessionID && $0.freshness == .live
        }),
        let outcome = thread.outcome else { return }
        let identity = AppServerOutcomeIdentity(
            threadID: outcome.threadID,
            turnID: outcome.turnID
        )
        guard outcomeReviewLedger.markReviewed(identity, at: Date()) else { return }
        _ = outcomeReviewStore.save(outcomeReviewLedger)
        rebuildPresentation()
    }

    private func prepareCreatedThread(
        _ threadID: String,
        workingDirectory: String,
        connection: AppServerConnectionIdentity?
    ) {
        pendingCreatedThreadID = threadID
        createdThreadPlaceholder = .init(
            newlyCreatedThreadID: .init(rawValue: threadID),
            workingDirectory: workingDirectory,
            now: Date()
        )
        createdThreadPlaceholderConnection = connection
        let previousSessionID = selectedSessionID
        if selection.selectSession(threadID, availableSessionIDs: sessions.map(\.id)) {
            selectedSessionID = selection.selectedSessionID
            if selectedSessionID != previousSessionID {
                advanceControlSelectionGeneration()
                rebuildPresentation()
            }
        }
        onQualifySelectedSession?(threadID)
        onRequestSync?()
        selectCreatedThreadIfAvailable()
        newThreadSelectionTask?.cancel()
        newThreadSelectionTask = Task { @MainActor [weak self] in
            for delay in [150, 500, 1_500, 3_000] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let self else { return }
                if self.sessions.contains(where: { $0.id == threadID }) {
                    self.selectSession(threadID)
                    self.pendingCreatedThreadID = nil
                    return
                }
                self.onRequestSync?()
            }
        }
    }

    private func selectCreatedThreadIfAvailable() {
        guard let pendingCreatedThreadID,
              latestFirstThreads.contains(where: { $0.id == pendingCreatedThreadID }) else { return }
        let previousSessionID = selectedSessionID
        guard selection.selectSession(
            pendingCreatedThreadID,
            availableSessionIDs: sessions.map(\.id)
        ) else {
            self.pendingCreatedThreadID = nil
            return
        }
        selectedSessionID = selection.selectedSessionID
        self.pendingCreatedThreadID = nil
        createdThreadPlaceholder = nil
        createdThreadPlaceholderConnection = nil
        if selectedSessionID != previousSessionID {
            advanceControlSelectionGeneration()
            rebuildPresentation()
        }
        onQualifySelectedSession?(pendingCreatedThreadID)
    }

    private func rebuildPresentation() {
        guard let latestSnapshot, let latestRuntimeStatus else { return }
        let detailedThreadIDs = AppServerDomainPresentation.detailedThreadIDs(
            snapshot: latestSnapshot,
            selectedThreadID: selectedSessionID,
            now: presentationDate
        )
        let verified = sharedDesktopLabsEnabled
            && sharedDesktopDiagnostics?.evaluation.state == .verified
            && sharedDesktopDiagnosticsLease?.isFresh(at: Date()) == true
        let runtimeStatus = verified
            ? AppServerRuntimeStatus(
                phase: latestRuntimeStatus.phase,
                detail: latestRuntimeStatus.detail,
                connectionSource: .verifiedSharedDesktop,
                capabilityModeLabel: latestRuntimeStatus.capabilityModeLabel,
                scopeLabel: "Threads shared by this verified Desktop and managed daemon",
                cliVersion: latestRuntimeStatus.cliVersion,
                appServerVersion: latestRuntimeStatus.appServerVersion,
                attempt: latestRuntimeStatus.attempt,
                listedThreadCount: latestRuntimeStatus.listedThreadCount,
                hydratedThreadCount: latestRuntimeStatus.hydratedThreadCount,
                monitoredThreadCount: latestRuntimeStatus.monitoredThreadCount,
                isThreadInventoryTruncated: latestRuntimeStatus.isThreadInventoryTruncated,
                malformedInventoryRowCount: latestRuntimeStatus.malformedInventoryRowCount,
                isThreadInventoryMembershipComplete: latestRuntimeStatus.isThreadInventoryMembershipComplete
            )
            : latestRuntimeStatus
        presentation = AppServerDomainPresentation(
            snapshot: latestSnapshot,
            runtimeStatus: runtimeStatus,
            now: presentationDate,
            isPresentationPaused: isPresentationPaused,
            unreviewedOutcomeIDs: outcomeReviewLedger.unreviewedOutcomeIDs,
            reviewedOutcomeIDs: outcomeReviewLedger.reviewedOutcomeIDs,
            detailedThreadIDs: detailedThreadIDs
        )
        reconcileCompactShelf()
    }

    private func reconcileCompactShelf() {
        guard !isPresentationPaused,
              latestRuntimeStatus?.phase == .connected,
              let presentation else {
            clearCompactShelf()
            return
        }

        ingestUserFacingNotifications(from: presentation)

        if let thread = presentation.urgencySortedThreads.first(where: { thread in
            guard let attention = thread.attention,
                  attention.responseStyle == .approval,
                  attention.isResponseShapeSupported,
                  !ShellCompactApprovalPolicy.visibleChoices(
                    from: attention.availableApprovalChoices
                  ).isEmpty,
                  let projected = latestSnapshot?.threads
                    .first(where: { $0.id == thread.threadID })?.requests
                    .first(where: { $0.id == attention.scopedRequestID })
            else { return false }
            return controlAvailability.mayRespond(to: projected)
        }), let attention = thread.attention {
            if let interrupted = compactNotificationBatch {
                pendingUserFacingNotifications.insert(
                    contentsOf: interrupted.groups.flatMap(\.messages),
                    at: 0
                )
            }
            compactNotificationBatch = nil
            compactShelfTask?.cancel()
            compactShelfTask = nil
            setCompactShelf(.init(
                id: "approval:\(attention.id)",
                mode: .approval,
                verb: "Approval required",
                detail: thread.title,
                requestID: attention.scopedRequestID,
                threadID: attention.threadID,
                turnID: attention.turnID,
                approvalChoices: ShellCompactApprovalPolicy.visibleChoices(
                    from: attention.availableApprovalChoices
                )
            ))
            return
        }

        if surfaceState == .compact,
           let thread = presentation.urgencySortedThreads.first(where: { $0.attention != nil }) {
            clearCompactShelf()
            presentProjectedSession(thread.id)
            return
        }

        guard surfaceState == .compact else {
            clearCompactShelf()
            return
        }

        if !pendingUserFacingNotifications.isEmpty {
            let currentMessages = compactNotificationBatch?.groups.flatMap(\.messages) ?? []
            compactNotificationBatch = ShellUserFacingNotificationPolicy.batch(
                currentMessages + pendingUserFacingNotifications
            )
            // Older overlapping prose is already marked seen and remains in
            // the transcript. Do not replay it after newer text has replaced
            // it in the compact shelf.
            pendingUserFacingNotifications.removeAll(keepingCapacity: true)
        }

        guard let batch = compactNotificationBatch else {
            clearCompactShelf()
            return
        }
        let candidate = ShellCompactShelfPresentation(
            id: "notification:\(batch.id)",
            mode: .activity,
            verb: batch.groups.count == 1
                ? batch.groups[0].threadTitle
                : "\(batch.groups.count) thread updates",
            detail: batch.groups[0].messages[0].text,
            threadID: batch.primaryThreadID
        )
        guard compactShelf?.id != candidate.id else { return }
        setCompactShelf(candidate)
        compactShelfTask?.cancel()
        compactShelfTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(batch.duration)) } catch { return }
            guard self?.compactShelf?.id == candidate.id else { return }
            self?.compactNotificationBatch = nil
            self?.compactShelf = nil
            self?.onCompactShelfVisibilityChanged?(false)
            self?.reconcileCompactShelf()
        }
    }

    private func ingestUserFacingNotifications(
        from presentation: AppServerDomainPresentation
    ) {
        let collected = ShellUserFacingNotificationPolicy.collect(from: presentation.threads)
        // A turn is eligible only during its observed live epoch. Once sealed,
        // every later hydration/remap is historical regardless of item ID or
        // whether the restored prose arrives atomically.
        seenUserFacingNotificationIDs.formUnion(
            notificationSeedLedger.consume(
                latestSnapshot?.threads ?? [],
                notifications: collected
            )
        )
        let detailedHydrationThreadIDs = Set(
            (latestSnapshot?.threads ?? []).compactMap { thread in
                thread.turns.contains(where: { $0.itemsView == .full })
                    ? thread.id.rawValue
                    : nil
            }
        )
        guard didSeedUserFacingNotifications else {
            seenUserFacingNotificationIDs.formUnion(collected.map(\.id))
            notificationHydratedThreadIDs.formUnion(detailedHydrationThreadIDs)
            didSeedUserFacingNotifications = true
            return
        }
        let newlyHydratedHistoricalThreadIDs = Set<String>(presentation.threads.compactMap { thread in
            guard detailedHydrationThreadIDs.contains(thread.id),
                  !notificationHydratedThreadIDs.contains(thread.id)
            else { return nil }
            return ShellUserFacingNotificationPolicy.shouldSeedFirstHydration(
                wasHydrated: false,
                visualState: thread.visualState
            ) ? thread.id : nil
        })
        seenUserFacingNotificationIDs.formUnion(
            collected.filter { newlyHydratedHistoricalThreadIDs.contains($0.threadID.rawValue) }
                .map(\.id)
        )
        notificationHydratedThreadIDs.formUnion(detailedHydrationThreadIDs)
        let unseen = ShellUserFacingNotificationPolicy.unseen(
            collected,
            excluding: seenUserFacingNotificationIDs
        )
        guard !unseen.isEmpty else { return }
        seenUserFacingNotificationIDs.formUnion(unseen.map(\.id))
        pendingUserFacingNotifications.append(contentsOf: unseen)
    }

    private func resetUserFacingNotifications() {
        compactShelfTask?.cancel()
        compactShelfTask = nil
        compactNotificationBatch = nil
        pendingUserFacingNotifications.removeAll(keepingCapacity: false)
        seenUserFacingNotificationIDs.removeAll(keepingCapacity: false)
        notificationSeedLedger.reset()
        notificationHydratedThreadIDs.removeAll(keepingCapacity: false)
        didSeedUserFacingNotifications = false
    }

    private func setCompactShelf(_ shelf: ShellCompactShelfPresentation) {
        compactShelf = shelf
        onCompactShelfVisibilityChanged?(surfaceState == .compact)
    }

    private func clearCompactShelf() {
        compactShelfTask?.cancel()
        compactShelfTask = nil
        compactNotificationBatch = nil
        guard compactShelf != nil else { return }
        compactShelf = nil
        onCompactShelfVisibilityChanged?(false)
    }

    private var latestFirstThreads: [AppServerThreadPresentation] {
        presentation?.threads ?? []
    }

    private var selectedProjectedThread: AppServerProjectedThread? {
        guard let selectedSessionID else { return nil }
        return latestSnapshot?.threads.first { $0.id.rawValue == selectedSessionID }
    }

    private var latestFirstProjects: [AppServerProjectPresentation] {
        (presentation?.projects ?? []).sorted {
            let lhsDate = $0.threads.map(\.updatedAt).max() ?? .distantPast
            let rhsDate = $1.threads.map(\.updatedAt).max() ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return $0.id < $1.id
        }
    }

    private var visibleThreadOrder: [String] {
        ShellInventoryPreferencePolicy.visibleOrder(
            persisted: threadOrder,
            latestFirstIDs: latestFirstThreads.map(\.id)
        )
    }

    private var visibleProjectOrder: [String] {
        ShellInventoryPreferencePolicy.visibleOrder(
            persisted: projectOrder,
            latestFirstIDs: latestFirstProjects.map(\.id)
        )
    }

    private func reconcileManualOrdering() {
        let status = latestRuntimeStatus
        let authority = ShellInventoryAuthority.resolve(
            isConnectedInventory: status?.phase == .connected,
            isTruncated: status?.isThreadInventoryTruncated ?? true,
            malformedRowCount: status?.malformedInventoryRowCount ?? 0,
            inventoryMembershipIsComplete:
                status?.isThreadInventoryMembershipComplete ?? false,
            listedThreadCount: status?.listedThreadCount,
            renderedThreadCount: latestFirstThreads.count
        )
        let changes = ShellInventoryPreferencePolicy.reconcile(
            threadOrder: &threadOrder,
            projectOrder: &projectOrder,
            collapsedProjectIDs: &collapsedProjectIDs,
            latestFirstThreadIDs: latestFirstThreads.map(\.id),
            latestFirstProjectIDs: latestFirstProjects.map(\.id),
            authority: authority
        )
        if changes.threadOrderChanged {
            save(threadOrder, forKey: Self.threadOrderPreferenceKey)
        }
        if changes.projectOrderChanged {
            save(projectOrder, forKey: Self.projectOrderPreferenceKey)
        }
        if changes.collapsedProjectsChanged {
            UserDefaults.standard.set(
                collapsedProjectIDs.sorted(),
                forKey: Self.collapsedProjectsPreferenceKey
            )
        }
    }

    private func save(_ order: ShellManualOrder, forKey key: String) {
        guard let data = try? JSONEncoder().encode(order) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadOrder(forKey key: String) -> ShellManualOrder {
        guard let data = UserDefaults.standard.data(forKey: key),
              let order = try? JSONDecoder().decode(ShellManualOrder.self, from: data)
        else { return .init() }
        return order
    }

    private static func isLineSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }
}
