import AppKit
import Foundation
import ConnAppCore
import ConnDomain
import SwiftUI

public struct ConnDisplayChoice: Equatable, Identifiable, Sendable {
    public let id: UInt32
    public let name: String
    public let isSelected: Bool

    public init(id: UInt32, name: String, isSelected: Bool) {
        self.id = id
        self.name = name
        self.isSelected = isSelected
    }
}

@MainActor
public final class ConnViewModel: ObservableObject {
    @Published public private(set) var presentation: ConnDomainPresentation?
    @Published public private(set) var selectedSessionID: ConnSessionID?
    @Published public var surfaceState: ShellSurfaceState = .compact
    @Published public private(set) var isExpandedContentRevealReady = false
    @Published public var showsSettings = false
    @Published public var showsSessionPicker = false
    @Published public private(set) var newSessionDraft = ConnNewSessionDraft()
    @Published public var sessionPickerSearch = ""
    @Published public var sessionPickerWindow: SessionPickerActivityWindow = .default
    @Published public var appearance: ShellAppearance
    @Published public var defaultWorkspace: String
    @Published public var isPresentationPaused = false
    @Published public var shortcutIssue: String?
    @Published public private(set) var availableDisplays: [ConnDisplayChoice] = []
    @Published public private(set) var panelPlacement: ShellPanelPlacement = .externalCapsule
    @Published public private(set) var integrationError: String?
    @Published public private(set) var actionNotice: String?
    @Published public private(set) var actionError: String?
    @Published public private(set) var isPerformingAction = false
    @Published public var composerText = ""
    @Published public var selectedFollowUpModelID: ConnSessionModelID?
    @Published public var selectedFollowUpReasoningEffortID:
        ConnReasoningEffortID?
    @Published public private(set) var sessionModelOptions:
        [ConnSessionModelOption] = []
    @Published public private(set) var currentSessionModelSelection:
        ConnSessionModelSelection?
    @Published public private(set) var isLoadingSessionModels = false
    @Published public private(set) var sessionModelError: String?
    @Published public private(set) var compactNotificationBatch:
        ConnUserFacingNotificationBatch?
    @Published private var questionDrafts: [AttentionRequestID: [String: String]] = [:]

    public var onToggleExpansion: (() -> Void)?
    public var onCollapse: (() -> Void)?
    public var onHidePresentation: (() -> Void)?
    public var onSelectDisplay: ((UInt32) -> Void)?
    public var onCompactNotificationVisibilityChanged: (() -> Void)?

    private let coordinator: ConnIntegrationCoordinator
    private let harnessAssets: [HarnessID: String]
    private let sessionOpener: AnyConnSessionOpener
    private var stateTask: Task<Void, Never>?
    private var latestSnapshot: ConnAggregateSnapshot?
    private let compactNotificationLifetime =
        ConnCompactNotificationLifetimeController()
    private var notificationLedger = ConnUserFacingNotificationLedger()
    private var outcomeLedger: ConnOutcomeReviewLedger
    private let outcomeStore: ConnOutcomeReviewPreferenceStore
    private var dismissalLedger: ConnSessionDismissalLedger
    private let dismissalStore: ConnSessionDismissalPreferenceStore
    private var surfaceGeometryTransitionGate =
        ShellSurfaceGeometryTransitionGenerationGate()
    private var sessionModelLoadGeneration: UInt64 = 0

    public init(
        coordinator: ConnIntegrationCoordinator,
        harnessAssets: [HarnessID: String] = [:],
        sessionOpener: AnyConnSessionOpener = .unavailable,
        defaults: UserDefaults = .standard
    ) {
        self.coordinator = coordinator
        self.harnessAssets = harnessAssets
        self.sessionOpener = sessionOpener
        self.appearance = defaults.string(forKey: "conn.appearance")
            .flatMap(ShellAppearance.init(rawValue:)) ?? .dark
        self.defaultWorkspace = defaults.string(forKey: "conn.defaultWorkspace") ?? ""
        self.outcomeStore = .init(defaults: defaults)
        self.outcomeLedger = outcomeStore.load()
        self.dismissalStore = .init(defaults: defaults)
        self.dismissalLedger = dismissalStore.load()
    }

    deinit {
        stateTask?.cancel()
    }

    public var sessions: [ConnSessionPresentation] {
        presentation?.sessions ?? []
    }

    public var projects: [ConnProjectPresentation] {
        presentation?.projects ?? []
    }

    public var integrations: [ConnIntegrationPresentation] {
        presentation?.integrations ?? []
    }

    public var selectedSession: ConnSessionPresentation? {
        let visible = pickerResult.rows.map(\.session)
        guard let selectedSessionID else { return visible.first }
        return visible.first { $0.id == selectedSessionID } ?? visible.first
    }

    public var activeCount: Int {
        normalPickerResult.rows.filter(\.session.isActive).count
    }
    public var attentionCount: Int {
        normalPickerResult.rows.reduce(0) {
            $0 + $1.session.attention.count
        }
    }
    public var presentsExpandedContent: Bool {
        ShellExpandedContentPresentationPolicy.presentsExpandedContent(
            surface: surfaceState,
            isRevealReady: isExpandedContentRevealReady
        )
    }
    public var statusPills: [ConnStatusPillPresentation] {
        ConnStatusPillPolicy.make(
            from: normalPickerResult.rows.map(\.session)
        )
    }
    public var isExpanded: Bool { surfaceState == .expanded }
    public var compactShelfPreferredHeight: CGFloat {
        guard let compactNotificationBatch else { return 44 }
        return ConnCompactNotificationLayoutPolicy.headerHeight
            + ConnCompactNotificationLayoutPolicy.rowHeight(
                messageTexts: compactNotificationBatch.notifications.map(\.text),
                placement: panelPlacement
            )
    }

    public var selectedFollowUpModel: ConnSessionModelOption? {
        sessionModelOptions.first { $0.id == selectedFollowUpModelID }
    }

    public var showsNewSessionComposer: Bool {
        newSessionDraft.isPresented
    }

    public var newSessionWorkspace: String {
        get { newSessionDraft.workspace }
        set { newSessionDraft.workspace = newValue }
    }

    public var newSessionPrompt: String {
        get { newSessionDraft.message }
        set { newSessionDraft.message = newValue }
    }

    public var selectedNewSessionModelID: ConnSessionModelID? {
        get { newSessionDraft.modelID }
        set { newSessionDraft.modelID = newValue }
    }

    public var selectedNewSessionReasoningEffortID: ConnReasoningEffortID? {
        get { newSessionDraft.reasoningEffortID }
        set { newSessionDraft.reasoningEffortID = newValue }
    }

    public var selectedNewSessionModel: ConnSessionModelOption? {
        sessionModelOptions.first { $0.id == selectedNewSessionModelID }
    }

    public var followUpReasoningEfforts: [ConnReasoningEffortOption] {
        selectedFollowUpModel?.reasoningEfforts ?? []
    }

    public var newSessionReasoningEfforts: [ConnReasoningEffortOption] {
        selectedNewSessionModel?.reasoningEfforts ?? []
    }

    public var newSessionIntegration: ConnIntegrationPresentation? {
        guard let integrationID = newSessionDraft.integrationID else {
            return nil
        }
        return integrations.first { $0.id == integrationID }
    }

    public var newSessionHarness: ConnHarnessAttribution? {
        guard let descriptor = newSessionIntegration?.state.descriptor else {
            return nil
        }
        return .init(
            harnessID: descriptor.harnessID,
            label: descriptor.displayName,
            assetName: harnessAssets[descriptor.harnessID]
        )
    }

    public var canCreateSession: Bool {
        !isPerformingAction
            && !newSessionDraft.isAwaitingCreatedSession
            && !newSessionDraft.requiresDefaultWorkspace
            && (try? ConnActionText(newSessionPrompt)) != nil
            && modelSelection(
                modelID: selectedNewSessionModelID,
                reasoningEffortID: selectedNewSessionReasoningEffortID
            ) != nil
            && newSessionIntegration?.state.freshness == .live
            && newSessionIntegration?.state.capabilities.supports(.createSession) == true
    }

    public var pickerResult: SessionPickerResult {
        SessionPickerPolicy.select(
            sessions: sessions,
            projects: projects,
            configuration: .init(
                activityWindow: sessionPickerWindow,
                searchText: sessionPickerSearch,
                grouping: .project,
                dismissedSessionIDs: dismissalLedger.dismissedSessionIDs,
                retainedSessionIDs: Set([selectedSessionID].compactMap { $0 })
            )
        )
    }

    private var normalPickerResult: SessionPickerResult {
        SessionPickerPolicy.select(
            sessions: sessions,
            projects: projects,
            configuration: .init(
                activityWindow: sessionPickerWindow,
                grouping: .project,
                dismissedSessionIDs: dismissalLedger.dismissedSessionIDs
            )
        )
    }

    public func start() {
        guard stateTask == nil else { return }
        stateTask = Task { [weak self, coordinator] in
            await coordinator.start()
            let snapshots = await coordinator.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled, let self else { return }
                if !self.isPresentationPaused {
                    self.publish(snapshot)
                }
            }
        }
    }

    public func stop() {
        stateTask?.cancel()
        stateTask = nil
        Task { [coordinator] in await coordinator.stop() }
    }

    public func setSurfaceState(_ state: ShellSurfaceState) {
        surfaceGeometryTransitionGate.invalidate()
        isExpandedContentRevealReady = state == .expanded
        surfaceState = state
        if state == .compact {
            showsSettings = false
            closeSessionPicker()
            newSessionDraft.hide()
        } else {
            markSelectedOutcomeReviewed()
        }
    }

    @discardableResult
    public func beginSurfaceGeometryTransition(
        to state: ShellSurfaceState
    ) -> ShellSurfaceGeometryTransitionGeneration {
        let generation = surfaceGeometryTransitionGate.begin()
        // Publish the guard before the expanded surface so SwiftUI never
        // constructs the transcript at each intermediate panel size.
        isExpandedContentRevealReady = false
        surfaceState = state
        if state == .compact {
            showsSettings = false
            closeSessionPicker()
            newSessionDraft.hide()
        }
        return generation
    }

    public func completeSurfaceGeometryTransition(
        to state: ShellSurfaceState,
        generation: ShellSurfaceGeometryTransitionGeneration
    ) {
        guard surfaceGeometryTransitionGate.isCurrent(generation),
              surfaceState == state else { return }
        isExpandedContentRevealReady = state == .expanded
        if state == .expanded {
            markSelectedOutcomeReviewed()
        }
    }

    public func selectSession(_ sessionID: ConnSessionID) {
        guard pickerResult.rows.contains(where: {
            $0.session.id == sessionID
        }) else { return }
        selectedSessionID = sessionID
        markOutcomeReviewed(for: sessionID)
        if sessionPickerSearch.isEmpty {
            closeSessionPicker()
        }
        newSessionDraft.hide()
        selectedFollowUpModelID = nil
        selectedFollowUpReasoningEffortID = nil
        currentSessionModelSelection = nil
        actionError = nil
        actionNotice = nil
        loadSessionModels()
    }

    public func toggleSessionPicker() {
        if showsSessionPicker {
            closeSessionPicker()
        } else {
            showsSessionPicker = true
        }
    }

    public func dismissSession(_ sessionID: ConnSessionID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              dismissalLedger.dismiss(session) else {
            return
        }
        _ = dismissalStore.save(dismissalLedger)
        if selectedSessionID == sessionID {
            selectedSessionID = normalPickerResult.rows.first?.session.id
        }
        removeVisibleNotifications(for: sessionID)
        objectWillChange.send()
    }

    public func beginNewSessionDraft() {
        guard let integration = integrations.first(where: {
            $0.state.capabilities.supports(.createSession)
        }) else {
            actionError = "A Session-creating Integration is not available"
            return
        }
        newSessionDraft.present(
            integrationID: integration.id,
            defaultWorkspace: defaultWorkspace
        )
        showsSettings = false
        closeSessionPicker()
        actionError = nil
        actionNotice = nil
        loadNewSessionModels()
    }

    public func hideNewSessionDraft() {
        newSessionDraft.hide()
    }

    public func configureDefaultWorkspace() {
        showsSettings = true
    }

    public func finishSettings(defaults: UserDefaults = .standard) {
        persistPreferences(defaults: defaults)
        newSessionDraft.applyDefaultWorkspaceIfNeeded(defaultWorkspace)
    }

    public func requestRefresh(_ integrationID: IntegrationID) {
        Task { [coordinator] in await coordinator.refresh(integrationID) }
    }

    public func openSelectedInHarness() {
        guard let selectedSession else { return }
        let sessionID = selectedSession.id
        let harnessName = selectedSession.harness.label
        guard case .available = sessionOpener.availability(for: sessionID) else {
            if case let .unavailable(reason) = sessionOpener.availability(for: sessionID) {
                actionError = reason
            }
            return
        }
        Task { [weak self, sessionOpener] in
            let opened = await sessionOpener.open(sessionID)
            guard let self else { return }
            if opened {
                actionNotice = "Opened in \(harnessName)"
            } else {
                actionError = "\(harnessName) could not be opened"
            }
        }
    }

    public func canOpenInHarness(_ sessionID: ConnSessionID) -> Bool {
        sessionOpener.availability(for: sessionID) == .available
    }

    public func submitComposer() {
        guard let selected = selectedSession else { return }
        let draft = composerText
        guard let text = try? ConnActionText(draft) else {
            actionError = "Enter a message before sending"
            return
        }
        let action: ConnAction
        if let activeRun = selected.state.session.runs.last(
            where: { $0.status == .inProgress }
        ), selected.state.actionAvailability.supports(.steer) {
            action = .steer(
                sessionID: selected.id,
                runID: activeRun.id,
                text: text
            )
        } else {
            action = .followUp(
                sessionID: selected.id,
                text: text,
                modelSelection: modelSelection(
                    modelID: selectedFollowUpModelID,
                    reasoningEffortID: selectedFollowUpReasoningEffortID
                )
            )
        }
        perform(action, clearComposerOnAcceptance: true)
    }

    public func interruptSelectedRun() {
        guard let selected = selectedSession,
              let run = selected.state.session.runs.last(
                where: { $0.status == .inProgress }
              ) else { return }
        perform(.interrupt(sessionID: selected.id, runID: run.id))
    }

    public func resolveApproval(
        _ attention: ConnAttentionPresentation,
        decision: ApprovalDecision
    ) {
        perform(.resolveApproval(
            sessionID: attention.state.request.sessionID,
            authority: attention.state.responseAuthority,
            decision: decision
        ))
    }

    public func questionAnswer(
        attentionID: AttentionRequestID,
        questionID: String
    ) -> String {
        questionDrafts[attentionID]?[questionID] ?? ""
    }

    public func updateQuestionAnswer(
        attentionID: AttentionRequestID,
        questionID: String,
        value: String
    ) {
        questionDrafts[attentionID, default: [:]][questionID] = value
    }

    public func submitAnswers(_ attention: ConnAttentionPresentation) {
        guard case let .structuredQuestions(questions, _) =
                attention.state.request.content else { return }
        let drafts = questionDrafts[attention.id] ?? [:]
        let values = Dictionary(uniqueKeysWithValues: questions.compactMap {
            question -> (String, [String])? in
            guard let value = drafts[question.id], !value.isEmpty else { return nil }
            return (question.id, [value])
        })
        guard values.count == questions.count,
              let answers = try? ConnStructuredAnswers(
                valuesByQuestionID: values
              ) else {
            actionError = "Answer every question before sending"
            return
        }
        perform(
            .answer(
                sessionID: attention.state.request.sessionID,
                authority: attention.state.responseAuthority,
                answers: answers
            ),
            clearQuestionDraft: attention.id
        )
    }

    public func createSession() {
        guard let workspace = try? ConnWorkspacePath(newSessionWorkspace),
              let prompt = try? ConnActionText(newSessionPrompt),
              let modelSelection = modelSelection(
                modelID: selectedNewSessionModelID,
                reasoningEffortID: selectedNewSessionReasoningEffortID
              ),
              let integrationID = newSessionDraft.integrationID,
              let integration = presentation?.integrations.first(where: {
                  $0.id == integrationID
                      && $0.state.capabilities.supports(.createSession)
                      && $0.state.freshness == .live
              }) else {
            actionError = "A live Integration, Workspace, and prompt are required"
            return
        }
        perform(
            .createSession(
                integrationID: integration.id,
                workspacePath: workspace,
                initialPrompt: prompt,
                modelSelection: modelSelection
            )
        )
    }

    public func loadSessionModels() {
        let selectedSessionID = selectedSession?.id
        let integration = selectedSession.map(\.state.integration)
            .flatMap { selectedIntegration in
                presentation?.integrations.first {
                    $0.id == selectedIntegration.id
                        && $0.state.freshness == .live
                }
            }
            ?? presentation?.integrations.first(where: {
                $0.state.capabilities.supports(.createSession)
                    && $0.state.freshness == .live
            })
        guard let integration else {
            clearSessionModels(
                message: "Models require a live Integration"
            )
            return
        }
        loadSessionModels(
            integrationID: integration.id,
            sessionID: selectedSessionID,
            forNewSession: false
        )
    }

    public func loadNewSessionModels() {
        guard let integrationID = newSessionDraft.integrationID,
              integrations.contains(where: {
                  $0.id == integrationID
                      && $0.state.capabilities.supports(.createSession)
                      && $0.state.freshness == .live
              }) else {
            clearSessionModels(
                message: "Models require a live Integration"
            )
            return
        }
        loadSessionModels(
            integrationID: integrationID,
            sessionID: nil,
            forNewSession: true
        )
    }

    private func loadSessionModels(
        integrationID: IntegrationID,
        sessionID: ConnSessionID?,
        forNewSession: Bool
    ) {
        sessionModelLoadGeneration &+= 1
        let generation = sessionModelLoadGeneration
        isLoadingSessionModels = true
        sessionModelError = nil
        Task { [weak self, coordinator] in
            let result = await coordinator.sessionModels(
                for: integrationID,
                sessionID: sessionID
            )
            guard let self,
                  generation == sessionModelLoadGeneration else { return }
            isLoadingSessionModels = false
            guard result.outcome == .available,
                  let catalog = result.catalog,
                  !catalog.options.isEmpty else {
                clearSessionModels(
                    message: result.outcome == .invalidated
                        ? "The Integration changed while loading models. Retry."
                        : "Models are unavailable from this Integration."
                )
                return
            }
            sessionModelOptions = catalog.options
            currentSessionModelSelection = catalog.currentSelection
            let defaultModelID = catalog.defaultOptionID
            if forNewSession {
                updateNewSessionModel(
                    catalog.options.contains(where: {
                        $0.id == selectedNewSessionModelID
                    }) ? selectedNewSessionModelID : defaultModelID
                )
            } else {
                let current = catalog.currentSelection
                    ?? defaultModelID.flatMap { modelID in
                        catalog.options.first(where: { $0.id == modelID }).flatMap {
                            $0.defaultReasoningEffortID.map {
                                ConnSessionModelSelection(
                                    modelID: modelID,
                                    reasoningEffortID: $0
                                )
                            }
                        }
                    }
                updateFollowUpModel(current?.modelID)
                selectedFollowUpReasoningEffortID =
                    current?.reasoningEffortID
            }
        }
    }

    private func clearSessionModels(message: String) {
        sessionModelLoadGeneration &+= 1
        isLoadingSessionModels = false
        sessionModelOptions = []
        selectedNewSessionModelID = nil
        selectedNewSessionReasoningEffortID = nil
        selectedFollowUpModelID = nil
        selectedFollowUpReasoningEffortID = nil
        currentSessionModelSelection = nil
        sessionModelError = message
    }

    public func updateFollowUpModel(_ modelID: ConnSessionModelID?) {
        selectedFollowUpModelID = modelID
        selectedFollowUpReasoningEffortID = modelID.flatMap { selectedID in
            sessionModelOptions.first(where: { $0.id == selectedID })?
                .defaultReasoningEffortID
        }
    }

    public func updateNewSessionModel(_ modelID: ConnSessionModelID?) {
        selectedNewSessionModelID = modelID
        selectedNewSessionReasoningEffortID = modelID.flatMap { selectedID in
            sessionModelOptions.first(where: { $0.id == selectedID })?
                .defaultReasoningEffortID
        }
    }

    private func modelSelection(
        modelID: ConnSessionModelID?,
        reasoningEffortID: ConnReasoningEffortID?
    ) -> ConnSessionModelSelection? {
        guard let modelID, let reasoningEffortID,
              sessionModelOptions.contains(where: {
                  $0.id == modelID
                      && $0.reasoningEfforts.contains {
                          $0.id == reasoningEffortID
                      }
              }) else { return nil }
        return .init(
            modelID: modelID,
            reasoningEffortID: reasoningEffortID
        )
    }

    public func markSelectedOutcomeReviewed() {
        guard let selected = selectedSession else { return }
        markOutcomeReviewed(for: selected.id)
    }

    public func setDisplays(
        _ displays: [ConnDisplayChoice],
        panelPlacement: ShellPanelPlacement
    ) {
        availableDisplays = displays
        self.panelPlacement = panelPlacement
    }

    public func selectDisplay(_ id: UInt32) {
        onSelectDisplay?(id)
    }

    public func dismissCompactNotification() {
        compactNotificationLifetime.dismiss()
        guard compactNotificationBatch != nil else { return }
        compactNotificationBatch = nil
        onCompactNotificationVisibilityChanged?()
    }

    public func persistPreferences(defaults: UserDefaults = .standard) {
        defaults.set(appearance.rawValue, forKey: "conn.appearance")
        defaults.set(defaultWorkspace, forKey: "conn.defaultWorkspace")
    }

    private func publish(_ snapshot: ConnAggregateSnapshot) {
        latestSnapshot = snapshot
        if outcomeLedger.reconcile(with: snapshot) {
            _ = outcomeStore.save(outcomeLedger)
        }
        let value = ConnPresentationBuilder.make(
            snapshot,
            harnessAssets: harnessAssets,
            reviewedOutcomeIDs: outcomeLedger.reviewedOutcomeIDs
        )
        if dismissalLedger.reconcile(with: value.sessions) {
            _ = dismissalStore.save(dismissalLedger)
        }
        presentation = value
        if let createdSessionID = newSessionDraft.reconcile(
            availableSessionIDs: value.sessions.map(\.id)
        ) {
            selectedSessionID = createdSessionID
            actionNotice = nil
        }
        if let selectedSessionID,
           !value.sessions.contains(where: { $0.id == selectedSessionID }) {
            if newSessionDraft.pendingSessionID != selectedSessionID {
                self.selectedSessionID =
                    normalPickerResult.rows.first?.session.id
            }
        } else if selectedSessionID == nil {
            selectedSessionID = normalPickerResult.rows.first?.session.id
        }
        if let compactNotificationBatch {
            let reconciled = ConnUserFacingNotificationPolicy.reconcileFinality(
                of: compactNotificationBatch,
                with: value
            )
            if reconciled != compactNotificationBatch {
                self.compactNotificationBatch = reconciled
            }
        }
        let notifications = notificationLedger.collect(from: value)
        if let batch = ConnUserFacingNotificationPolicy.batch(notifications) {
            presentCompactNotification(batch)
        }
        integrationError = value.integrations.isEmpty
            ? "No integrations enabled"
            : nil
    }

    private func markOutcomeReviewed(for sessionID: ConnSessionID) {
        guard let marker = outcomeLedger.markers.first(where: {
            $0.identity.sessionID == sessionID
                && $0.disposition == .unreviewed
        }), outcomeLedger.markReviewed(marker.identity) else { return }
        _ = outcomeStore.save(outcomeLedger)
        if let latestSnapshot {
            presentation = ConnPresentationBuilder.make(
                latestSnapshot,
                harnessAssets: harnessAssets,
                reviewedOutcomeIDs: outcomeLedger.reviewedOutcomeIDs
            )
        }
        removeVisibleNotifications(for: sessionID)
    }

    private func presentCompactNotification(
        _ batch: ConnUserFacingNotificationBatch
    ) {
        guard compactNotificationLifetime.present(
            id: batch.id,
            duration: batch.duration,
            onExpire: { [weak self] id in
                guard let self, self.compactNotificationBatch?.id == id else {
                    return
                }
                self.compactNotificationBatch = nil
                self.onCompactNotificationVisibilityChanged?()
            }
        ) else { return }
        compactNotificationBatch = batch
        onCompactNotificationVisibilityChanged?()
    }

    private func removeVisibleNotifications(for sessionID: ConnSessionID) {
        guard let batch = compactNotificationBatch else { return }
        let retained = batch.notifications.filter {
            $0.sessionID != sessionID
        }
        guard retained.count != batch.notifications.count else { return }
        if retained.isEmpty {
            compactNotificationLifetime.dismiss()
            compactNotificationBatch = nil
        } else {
            compactNotificationBatch = .init(
                notifications: retained,
                duration: batch.duration
            )
        }
        onCompactNotificationVisibilityChanged?()
    }

    private func closeSessionPicker() {
        showsSessionPicker = false
        sessionPickerSearch = ""
    }

    private func perform(
        _ action: ConnAction,
        clearComposerOnAcceptance: Bool = false,
        clearQuestionDraft: AttentionRequestID? = nil
    ) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        actionError = nil
        actionNotice = nil
        Task { [weak self, coordinator] in
            let outcome = await coordinator.perform(action)
            guard let self else { return }
            isPerformingAction = false
            switch outcome.kind {
            case .accepted:
                actionNotice = outcome.evidence ?? "Accepted"
                if clearComposerOnAcceptance { composerText = "" }
                switch action {
                case let .followUp(sessionID, _, _),
                     let .steer(sessionID, _, _):
                    if dismissalLedger.restore(sessionID) {
                        _ = dismissalStore.save(dismissalLedger)
                    }
                case .createSession, .interrupt, .answer, .resolveApproval:
                    break
                }
                if let clearQuestionDraft {
                    questionDrafts.removeValue(forKey: clearQuestionDraft)
                }
                if action.kind == .createSession {
                    guard let createdSessionID = outcome.createdSessionID else {
                        actionNotice = nil
                        actionError = "The Integration accepted creation without returning the new Session identity"
                        return
                    }
                    newSessionDraft.markCreationAccepted(createdSessionID)
                    selectedSessionID = createdSessionID
                    actionNotice = "Creating Session…"
                    if let resolved = newSessionDraft.reconcile(
                        availableSessionIDs: sessions.map(\.id)
                    ) {
                        selectedSessionID = resolved
                        actionNotice = nil
                    }
                }
            case .acknowledgementUncertain:
                actionError = outcome.evidence
                    ?? "Sent, but acknowledgement is uncertain. Conn will not retry."
            case .rejected:
                let harnessName = integrations.first {
                    $0.id == outcome.integrationID
                }?.state.descriptor.displayName ?? "Harness"
                actionError = outcome.evidence
                    ?? "\(harnessName) rejected the action"
            case .invalidated:
                actionError = outcome.evidence ?? "Connection authority changed"
            case .resolvedElsewhere:
                actionNotice = outcome.evidence ?? "Resolved by another client"
            case .unavailable:
                actionError = outcome.evidence ?? "Action is not currently available"
            }
        }
    }
}
