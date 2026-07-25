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
    @Published public var showsSettings = false
    @Published public var showsSessionPicker = false
    @Published public var showsNewSessionComposer = false
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
    @Published public var newSessionWorkspace = ""
    @Published public var newSessionPrompt = ""
    @Published public private(set) var sessionModelOptions:
        [ConnSessionModelOption] = []
    @Published public var selectedNewSessionModelID: ConnSessionModelID?
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
    private let openHarness: @Sendable (ConnSessionID) async -> Bool
    private var stateTask: Task<Void, Never>?
    private let compactNotificationLifetime =
        ConnCompactNotificationLifetimeController()
    private var notificationLedger = ConnUserFacingNotificationLedger()
    private var outcomeLedger: ConnOutcomeReviewLedger
    private let outcomeStore: ConnOutcomeReviewPreferenceStore

    public init(
        coordinator: ConnIntegrationCoordinator,
        harnessAssets: [HarnessID: String] = [:],
        openHarness: @escaping @Sendable (ConnSessionID) async -> Bool = { _ in false },
        defaults: UserDefaults = .standard
    ) {
        self.coordinator = coordinator
        self.harnessAssets = harnessAssets
        self.openHarness = openHarness
        self.appearance = defaults.string(forKey: "conn.appearance")
            .flatMap(ShellAppearance.init(rawValue:)) ?? .dark
        self.defaultWorkspace = defaults.string(forKey: "conn.defaultWorkspace") ?? ""
        self.outcomeStore = .init(defaults: defaults)
        self.outcomeLedger = outcomeStore.load()
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
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID }
    }

    public var activeCount: Int { presentation?.activeSessionCount ?? 0 }
    public var attentionCount: Int { presentation?.attentionCount ?? 0 }
    public var isExpanded: Bool { surfaceState == .expanded }
    public var compactShelfPreferredHeight: CGFloat {
        compactNotificationBatch == nil ? 44 : 92
    }

    public var pickerResult: SessionPickerResult {
        SessionPickerPolicy.select(
            sessions: sessions,
            projects: projects,
            configuration: .init(
                activityWindow: sessionPickerWindow,
                searchText: sessionPickerSearch,
                grouping: .project
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
        surfaceState = state
        if state == .compact {
            showsSettings = false
            showsSessionPicker = false
            showsNewSessionComposer = false
        }
    }

    public func selectSession(_ sessionID: ConnSessionID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        selectedSessionID = sessionID
        showsSessionPicker = false
        selectedFollowUpModelID = nil
        actionError = nil
        actionNotice = nil
    }

    public func requestRefresh(_ integrationID: IntegrationID) {
        Task { [coordinator] in await coordinator.refresh(integrationID) }
    }

    public func openSelectedInHarness() {
        guard let sessionID = selectedSession?.id else { return }
        Task { [weak self, openHarness] in
            let opened = await openHarness(sessionID)
            guard let self else { return }
            if opened {
                actionNotice = "Opened in Codex"
            } else {
                actionError = "Codex could not be opened"
            }
        }
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
                modelID: selectedFollowUpModelID
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
              let modelID = selectedNewSessionModelID,
              let integration = presentation?.integrations.first(where: {
                  $0.state.capabilities.supports(.createSession)
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
                modelID: modelID
            ),
            clearNewSessionOnAcceptance: true
        )
    }

    public func loadSessionModels() {
        guard !isLoadingSessionModels,
              let integration = presentation?.integrations.first(where: {
                  $0.state.capabilities.supports(.createSession)
                      && $0.state.freshness == .live
              }) else {
            sessionModelOptions = []
            selectedNewSessionModelID = nil
            sessionModelError = "Models require a live Integration"
            return
        }
        let integrationID = integration.id
        isLoadingSessionModels = true
        sessionModelError = nil
        Task { [weak self, coordinator] in
            let result = await coordinator.sessionModels(for: integrationID)
            guard let self else { return }
            isLoadingSessionModels = false
            guard result.outcome == .available,
                  let catalog = result.catalog,
                  !catalog.options.isEmpty else {
                sessionModelOptions = []
                selectedNewSessionModelID = nil
                sessionModelError = result.outcome == .invalidated
                    ? "The Integration changed while loading models. Retry."
                    : "Models are unavailable from this Integration."
                return
            }
            sessionModelOptions = catalog.options
            if !catalog.options.contains(where: {
                $0.id == selectedNewSessionModelID
            }) {
                selectedNewSessionModelID = catalog.defaultOptionID
            }
        }
    }

    public func markSelectedOutcomeReviewed() {
        guard let selected = selectedSession,
              let marker = outcomeLedger.markers.first(where: {
                  $0.identity.sessionID == selected.id
                      && $0.disposition == .unreviewed
              }) else { return }
        if outcomeLedger.markReviewed(marker.identity) {
            _ = outcomeStore.save(outcomeLedger)
            objectWillChange.send()
        }
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
        let value = ConnPresentationBuilder.make(
            snapshot,
            harnessAssets: harnessAssets
        )
        presentation = value
        if let selectedSessionID,
           !value.sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = value.sessions.first?.id
        } else if selectedSessionID == nil {
            selectedSessionID = value.sessions.first?.id
        }
        if outcomeLedger.reconcile(with: snapshot) {
            _ = outcomeStore.save(outcomeLedger)
        }
        let notifications = notificationLedger.collect(from: value)
        if let batch = ConnUserFacingNotificationPolicy.batch(notifications) {
            presentCompactNotification(batch)
        }
        integrationError = value.integrations.isEmpty
            ? "No Integration is installed"
            : nil
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

    private func perform(
        _ action: ConnAction,
        clearComposerOnAcceptance: Bool = false,
        clearQuestionDraft: AttentionRequestID? = nil,
        clearNewSessionOnAcceptance: Bool = false
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
                if clearComposerOnAcceptance { selectedFollowUpModelID = nil }
                if let clearQuestionDraft {
                    questionDrafts.removeValue(forKey: clearQuestionDraft)
                }
                if clearNewSessionOnAcceptance {
                    newSessionWorkspace = defaultWorkspace
                    newSessionPrompt = ""
                    showsNewSessionComposer = false
                }
            case .acknowledgementUncertain:
                actionError = outcome.evidence
                    ?? "Sent, but acknowledgement is uncertain. Conn will not retry."
            case .rejected:
                actionError = outcome.evidence ?? "Codex rejected the action"
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
