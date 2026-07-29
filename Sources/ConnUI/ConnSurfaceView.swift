import AppKit
import ConnAppCore
import ConnDomain
import SwiftUI

private struct ConnRunExpansionKey: Hashable {
    let sessionID: ConnSessionID
    let runID: RunID
}

public struct ConnSurfaceView<IntegrationSettingsContent: View>: View {
    @ObservedObject private var model: ConnViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runExpansion: [ConnRunExpansionKey: Bool] = [:]
    @State private var showsFollowUpModelPopover = false
    @State private var showsNewSessionModelPopover = false
    @FocusState private var newSessionPromptIsFocused: Bool
    private let integrationSettingsContent: () -> IntegrationSettingsContent

    public init(
        model: ConnViewModel,
        @ViewBuilder integrationSettingsContent:
            @escaping () -> IntegrationSettingsContent
    ) {
        self.model = model
        self.integrationSettingsContent = integrationSettingsContent
    }

    public var body: some View {
        ZStack(alignment: .top) {
            if model.surfaceState == .expanded {
                if model.presentsExpandedContent {
                    chrome
                    expandedContent
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                compactSurface
            }
        }
        .frame(
            minWidth: model.surfaceState == .expanded ? 760 : 330,
            minHeight: model.surfaceState == .expanded
                ? 540
                : model.compactShelfPreferredHeight
        )
        .preferredColorScheme(model.appearance == .dark ? .dark : .light)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.3, bounce: 0.08),
            value: model.surfaceState
        )
        .animation(
            .easeOut(duration: reduceMotion ? 0.12 : 0.18),
            value: model.presentsExpandedContent
        )
        .animation(.easeOut(duration: 0.16), value: model.compactNotificationBatch?.id)
    }

    private var chrome: some View {
        chromeContent
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.09))
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
    }

    private var compactSurface: some View {
        let hasNotification = model.compactNotificationBatch != nil
        let shape = RoundedRectangle(
            cornerRadius: hasNotification ? 16 : 20,
            style: .continuous
        )
        return VStack(spacing: 0) {
            chromeContent
            if let batch = model.compactNotificationBatch {
                compactNotification(batch)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(
            width: ConnCompactHeaderLayoutPolicy.compactContentWidth(
                placement: model.panelPlacement
            )
        )
        .background(.ultraThinMaterial)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(0.09))
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private var chromeContent: some View {
        let presentation = ConnCompactHeaderLayoutPolicy.presentation(
            surface: model.surfaceState,
            placement: model.panelPlacement
        )
        return ZStack {
            Button {
                model.onToggleExpansion?()
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            HStack(spacing: 10) {
                Button {
                    model.onToggleExpansion?()
                } label: {
                    HStack(spacing: 7) {
                        ConnMarkView()
                            .frame(width: 22, height: 22)
                        if presentation.showsProductName {
                            Text("CONN")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .tracking(1.2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isExpanded ? "Collapse Conn" : "Expand Conn")

                if presentation.showsIntegrationStatus {
                    if let integration = model.integrations.first {
                        Circle()
                            .fill(toneColor(integration.tone))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(integration.statusLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Connecting")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: presentation.minimumCenterGap)

                ForEach(ShellStatusPillLayoutPolicy.orderedVisiblePills(
                    model.statusPills,
                    surface: model.surfaceState,
                    placement: model.panelPlacement
                )) { pill in
                    Button {
                        model.selectSession(pill.primarySessionID)
                        if !model.isExpanded {
                            model.onToggleExpansion?()
                        }
                    } label: {
                        metric(
                            "\(pill.count)",
                            label: "\(pill.label) Sessions",
                            color: toneColor(pill.tone)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(pill.label)
                }

                if model.isExpanded {
                    Button {
                        model.beginNewSessionDraft()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(ChromeButtonStyle())
                    .help("New Session")
                    .accessibilityLabel("Create a new Session")

                    Button {
                        model.showsSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(ChromeButtonStyle())
                    .help("Settings")
                    .accessibilityLabel("Open Conn settings")
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 40)
    }

    private var expandedContent: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
            Divider().opacity(0.35)
            detail
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.08))
        }
        .padding(.top, 46)
        .overlay {
            if model.showsSettings {
                settings
            }
        }
        .onAppear {
            model.loadSessionModels()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button {
                    model.showsSessionPicker.toggle()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter Sessions")
            }
            .padding(14)

            if model.showsSessionPicker {
                TextField("Search Sessions", text: $model.sessionPickerSearch)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.pickerResult.rows) { row in
                        sessionRow(row.session, project: row.projectLabel)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(.black.opacity(0.08))
    }

    private func sessionRow(
        _ session: ConnSessionPresentation,
        project: String
    ) -> some View {
        Button {
            model.selectSession(session.id)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                harnessBadge(session.harness)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Text(project)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(session.statusLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(toneColor(session.tone))
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                model.selectedSessionID == session.id
                    && !model.showsNewSessionComposer
                    ? Color.accentColor.opacity(0.16)
                    : Color.white.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(session.title), \(session.harness.label), \(session.statusLabel)"
        )
    }

    @ViewBuilder
    private var detail: some View {
        if model.showsNewSessionComposer {
            newSessionDetail
        } else if let session = model.selectedSession {
            VStack(spacing: 0) {
                sessionHeader(session)
                Divider().opacity(0.35)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if !session.attention.isEmpty {
                            ForEach(session.attention) { attention in
                                attentionCard(attention)
                            }
                        }
                        if session.activities.isEmpty && session.attention.isEmpty {
                            ContentUnavailableView(
                                "No Activity Yet",
                                systemImage: "waveform.path",
                                description: Text("Conn will show bounded Harness activity here.")
                            )
                            .padding(.top, 80)
                        } else {
                            ForEach(session.runs) { run in
                                runRow(run, sessionID: session.id)
                            }
                            ForEach(session.activities.filter {
                                $0.activity.runID == nil
                            }) { activity in
                                activityRow(activity)
                            }
                        }
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .id(session.id)
                Divider().opacity(0.35)
                composer(session)
            }
        } else {
            ContentUnavailableView(
                "No Sessions",
                systemImage: "rectangle.stack",
                description: Text("Conn is waiting for a qualified Integration.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func runRow(
        _ run: ConnRunPresentation,
        sessionID: ConnSessionID
    ) -> some View {
        let expansionKey = ConnRunExpansionKey(
            sessionID: sessionID,
            runID: run.id
        )
        let isExpanded = Binding(
            get: {
                runExpansion[expansionKey] ?? !run.isCollapsedByDefault
            },
            set: { runExpansion[expansionKey] = $0 }
        )
        return DisclosureGroup(isExpanded: isExpanded) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(run.activities) { activity in
                    activityRow(activity)
                }
                if let workedForLabel = run.workedForLabel {
                    runDurationFooter(workedForLabel)
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                if !isExpanded.wrappedValue,
                   let userMessage = run.triggeringUserMessage {
                    compactTriggeringMessage(userMessage)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: run.isCollapsedByDefault
                            ? "checkmark.circle.fill"
                            : "waveform.path")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                run.isCollapsedByDefault ? .green : .secondary
                            )
                        Text(run.title)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                        Text(
                            run.activities.count == 1
                                ? "1 item"
                                : "\(run.activities.count) items"
                        )
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    if !isExpanded.wrappedValue, let summary = run.summary {
                        Text(summary)
                            .font(.system(size: 12.5))
                            .lineSpacing(3)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !isExpanded.wrappedValue,
                       let workedForLabel = run.workedForLabel {
                        runDurationFooter(workedForLabel)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
            }
        }
        .tint(.secondary)
    }

    private func compactTriggeringMessage(_ message: String) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 88)
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    Color.accentColor.opacity(0.16),
                    in: messageBubbleShape(.outgoingBubble)
                )
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("You, \(message)")
    }

    private func runDurationFooter(_ label: String) -> some View {
        Label(label, systemImage: "clock")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func sessionHeader(_ session: ConnSessionPresentation) -> some View {
        HStack(spacing: 10) {
            harnessBadge(session.harness)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 15, weight: .bold))
                Text("\(session.workspaceLabel) · \(session.harness.label)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(toneColor(session.tone))
            Button("Open") {
                model.openSelectedInHarness()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
    }

    private func activityRow(_ item: ConnActivityPresentation) -> some View {
        let lane = ConnTranscriptAlignmentPolicy.lane(
            for: item.activity.kind
        )
        let isUser = lane == .trailing
        let contentLane = ConnTranscriptAlignmentPolicy.contentLane(
            for: item.activity.kind
        )
        let usesLeadingContent = contentLane == .leading
        let style = ConnTranscriptPresentationPolicy.style(
            for: item.activity.kind
        )
        let isSpeech = style != .activityCard
        return HStack(alignment: .top, spacing: 0) {
            if isUser {
                Spacer(minLength: 72)
            }
            HStack(alignment: .top, spacing: 10) {
                if !isUser && !isSpeech {
                    activityIcon(item)
                }
                VStack(
                    alignment: usesLeadingContent ? .leading : .trailing,
                    spacing: 4
                ) {
                    Text(item.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .multilineTextAlignment(
                                usesLeadingContent ? .leading : .trailing
                            )
                            .textSelection(.enabled)
                    }
                }
                if isUser && !isSpeech {
                    activityIcon(item)
                }
            }
            .padding(.horizontal, isSpeech ? 13 : 10)
            .padding(.vertical, isSpeech ? 9 : 10)
            .background(
                isUser
                    ? Color.accentColor.opacity(0.18)
                    : Color.white.opacity(isSpeech ? 0.07 : 0.035),
                in: messageBubbleShape(style)
            )
            .accessibilityElement(children: .combine)
            if !isUser {
                Spacer(minLength: 72)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func messageBubbleShape(_ style: ConnTranscriptStyle) -> AnyShape {
        switch style {
        case .incomingBubble:
            AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 14,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 14,
                topTrailingRadius: 14,
                style: .continuous
            ))
        case .outgoingBubble:
            AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 14,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 4,
                topTrailingRadius: 14,
                style: .continuous
            ))
        case .activityCard:
            AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func activityIcon(
        _ item: ConnActivityPresentation
    ) -> some View {
        Image(systemName: activitySymbol(item.activity.kind))
            .frame(width: 18)
            .foregroundStyle(toneColor(item.tone))
    }

    @ViewBuilder
    private func attentionCard(
        _ attention: ConnAttentionPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(attention.label, systemImage: "exclamationmark.bubble.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.orange)
            Text(attention.state.request.summary)
                .font(.system(size: 12))

            switch attention.state.request.content {
            case let .approval(decisions):
                HStack {
                    if decisions.contains(.approve) {
                        Button("Approve") {
                            model.resolveApproval(attention, decision: .approve)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if decisions.contains(.approveForSession) {
                        Button("Approve for Session") {
                            model.resolveApproval(
                                attention,
                                decision: .approveForSession
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                    if decisions.contains(.deny) {
                        Button("Deny") {
                            model.resolveApproval(attention, decision: .deny)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            case let .structuredQuestions(questions, _):
                ForEach(questions, id: \.id) { question in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(question.header.nonEmpty ?? question.prompt)
                            .font(.system(size: 11, weight: .semibold))
                        if question.header.nonEmpty != nil {
                            Text(question.prompt)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if question.isSecret {
                            SecureField(
                                "Answer",
                                text: questionBinding(attention.id, question.id)
                            )
                            .textFieldStyle(.roundedBorder)
                        } else {
                            TextField(
                                "Answer",
                                text: questionBinding(attention.id, question.id)
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                Button("Send answers") {
                    model.submitAnswers(attention)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange.opacity(0.25))
        }
    }

    private func composer(_ session: ConnSessionPresentation) -> some View {
        let canOverrideModel =
            session.state.actionAvailability.supports(.followUp)
                && !session.state.session.runs.contains {
                    $0.status == .inProgress
                }
        return VStack(spacing: 7) {
            if let error = model.actionError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let notice = model.actionNotice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                followUpModelControl(canOverrideModel: canOverrideModel)
                TextField("Follow up or steer…", text: $model.composerText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submitComposer() }
                Button {
                    model.submitComposer()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(
                    model.isPerformingAction
                        || (!session.state.actionAvailability.supports(.followUp)
                            && !session.state.actionAvailability.supports(.steer))
                )
                if session.state.actionAvailability.supports(.interrupt) {
                    Button {
                        model.interruptSelectedRun()
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Interrupt active Run")
                }
            }
        }
        .padding(12)
    }

    private func followUpModelControl(
        canOverrideModel: Bool
    ) -> some View {
        let effortName = model.followUpReasoningEfforts.first {
            $0.id == model.selectedFollowUpReasoningEffortID
        }?.displayName
        let label = ConnCompositeModelControlPresentation.label(
            modelName: model.selectedFollowUpModel?.displayName,
            reasoningName: effortName,
            isLoading: model.isLoadingSessionModels
        )
        return Button {
            showsFollowUpModelPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(minWidth: 130, idealWidth: 170, maxWidth: 190)
        .disabled(model.isLoadingSessionModels || !canOverrideModel)
        .accessibilityLabel("Model and reasoning for next message")
        .accessibilityValue(label)
        .help(
            canOverrideModel
                ? "Choose the model and reasoning effort for the next follow-up."
                : "Model changes are available when this Session is idle."
        )
        .popover(isPresented: $showsFollowUpModelPopover) {
            followUpModelPopover
        }
    }

    private var followUpModelPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model & Reasoning")
                .font(.system(size: 12, weight: .semibold))
            Picker(
                "Model",
                selection: Binding(
                    get: { model.selectedFollowUpModelID },
                    set: { model.updateFollowUpModel($0) }
                )
            ) {
                ForEach(model.sessionModelOptions) { option in
                    Text(option.displayName).tag(Optional(option.id))
                }
            }
            .pickerStyle(.menu)
            Picker(
                "Reasoning",
                selection: $model.selectedFollowUpReasoningEffortID
            ) {
                ForEach(model.followUpReasoningEfforts) { effort in
                    Text(effort.displayName).tag(Optional(effort.id))
                }
            }
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button("Done") {
                    showsFollowUpModelPopover = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private var settings: some View {
        modalCard(title: "Conn Settings", dismiss: { model.showsSettings = false }) {
            Form {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(ShellAppearance.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                TextField("Default Workspace", text: $model.defaultWorkspace)
                if !model.availableDisplays.isEmpty {
                    Picker(
                        "Display",
                        selection: Binding(
                            get: {
                                model.availableDisplays.first(where: \.isSelected)?.id
                                    ?? model.availableDisplays[0].id
                            },
                            set: { newValue in
                                model.selectDisplay(newValue)
                            }
                        )
                    ) {
                        ForEach(model.availableDisplays) {
                            Text($0.name).tag($0.id)
                        }
                    }
                }
                Section("Integrations") {
                    integrationSettingsContent()
                }
                if let shortcutIssue = model.shortcutIssue {
                    Text(shortcutIssue)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .onDisappear { model.finishSettings() }
        }
    }

    private var newSessionDetail: some View {
        VStack(spacing: 0) {
            newSessionHeader
            Divider().opacity(0.35)
            Group {
                if model.newSessionDraft.requiresDefaultWorkspace {
                    VStack(spacing: 14) {
                        ContentUnavailableView(
                            "Choose a Default Workspace",
                            systemImage: "folder.badge.questionmark",
                            description: Text(
                                "Conn needs a Workspace before it can start a Harness Session. You only need to configure this once."
                            )
                        )
                        Button("Choose in Settings") {
                            newSessionPromptIsFocused = false
                            model.configureDefaultWorkspace()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(28)
                } else if model.newSessionDraft.isAwaitingCreatedSession {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Creating Session…")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Waiting for the Harness Session to appear in Conn.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Start a New Session",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(
                            "Write your first message below. Conn creates the Harness Session only when you send it."
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(28)
                }
            }
            Divider().opacity(0.35)
            newSessionComposer
        }
        .onAppear {
            if !model.newSessionDraft.requiresDefaultWorkspace {
                Task { @MainActor in
                    newSessionPromptIsFocused = true
                }
            }
        }
    }

    private var newSessionHeader: some View {
        HStack(spacing: 10) {
            if let harness = model.newSessionHarness {
                harnessBadge(harness)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("New Session")
                    .font(.system(size: 15, weight: .bold))
                Text(
                    model.newSessionDraft.requiresDefaultWorkspace
                        ? "Default Workspace required"
                        : model.newSessionWorkspace
                )
                .font(.system(size: 11))
                .foregroundStyle(
                    model.newSessionDraft.requiresDefaultWorkspace
                        ? Color.orange
                        : Color.secondary
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
            if let integration = model.newSessionIntegration {
                Text(integration.state.descriptor.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(toneColor(integration.tone))
            }
            Button {
                model.hideNewSessionDraft()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(model.newSessionDraft.isAwaitingCreatedSession)
            .accessibilityLabel("Close new Session draft")
        }
        .padding(14)
    }

    private var newSessionComposer: some View {
        VStack(spacing: 7) {
            if let error = model.actionError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let modelError = model.sessionModelError {
                HStack(spacing: 8) {
                    Text(modelError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Button("Retry") { model.loadNewSessionModels() }
                        .buttonStyle(.link)
                        .disabled(model.isLoadingSessionModels)
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                newSessionModelControl
                TextField(
                    "Message your Harness…",
                    text: $model.newSessionPrompt,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($newSessionPromptIsFocused)
                .onSubmit { model.createSession() }
                Button {
                    model.createSession()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canCreateSession)
                .accessibilityLabel("Create Session and send message")
            }
            .disabled(
                model.newSessionDraft.requiresDefaultWorkspace
                    || model.newSessionDraft.isAwaitingCreatedSession
            )
        }
        .padding(12)
    }

    private var newSessionModelControl: some View {
        let effortName = model.newSessionReasoningEfforts.first {
            $0.id == model.selectedNewSessionReasoningEffortID
        }?.displayName
        let label = ConnCompositeModelControlPresentation.label(
            modelName: model.selectedNewSessionModel?.displayName,
            reasoningName: effortName,
            isLoading: model.isLoadingSessionModels
        )
        return Button {
            showsNewSessionModelPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(minWidth: 130, idealWidth: 170, maxWidth: 190)
        .disabled(
            model.isLoadingSessionModels
                || model.sessionModelOptions.isEmpty
                || model.newSessionDraft.isAwaitingCreatedSession
        )
        .accessibilityLabel("Model and reasoning for new Session")
        .accessibilityValue(label)
        .help("Choose the model and reasoning effort for the first message.")
        .popover(isPresented: $showsNewSessionModelPopover) {
            newSessionModelPopover
        }
    }

    private var newSessionModelPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model & Reasoning")
                .font(.system(size: 12, weight: .semibold))
            Picker(
                "Model",
                selection: Binding(
                    get: { model.selectedNewSessionModelID },
                    set: { model.updateNewSessionModel($0) }
                )
            ) {
                ForEach(model.sessionModelOptions) { option in
                    Text(option.displayName).tag(Optional(option.id))
                }
            }
            .pickerStyle(.menu)
            Picker(
                "Reasoning",
                selection: $model.selectedNewSessionReasoningEffortID
            ) {
                ForEach(model.newSessionReasoningEfforts) { effort in
                    Text(effort.displayName).tag(Optional(effort.id))
                }
            }
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button("Done") {
                    showsNewSessionModelPopover = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func modalCard<Content: View>(
        title: String,
        dismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            Color.black.opacity(0.45)
                .onTapGesture(perform: dismiss)
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(title)")
                }
                .padding(14)
                Divider()
                content()
                    .padding(16)
            }
            .frame(width: 470)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.12))
            }
        }
        .padding(.top, 46)
    }

    private func compactNotification(
        _ batch: ConnUserFacingNotificationBatch
    ) -> some View {
        let isFinal = batch.notifications.last?.isFinal == true
        return HStack(alignment: .top, spacing: 10) {
            switch ConnCompactNotificationLayoutPolicy.indicator(
                isFinal: isFinal
            ) {
            case .animatedWaveform:
                CompactNotificationWaveform(reduceMotion: reduceMotion)
                    .id(batch.id)
            case .completion:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(batch.notifications) { notification in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(notification.sessionTitle)
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                        Text(notification.text)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(
                                ConnCompactNotificationLayoutPolicy
                                    .messageLineLimit
                            )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            CompactNotificationCountdownRing(
                duration: batch.duration,
                reduceMotion: reduceMotion
            )
            .id(batch.id)
        }
        .padding(.horizontal, 12)
        .frame(
            width: ConnCompactNotificationLayoutPolicy.contentWidth(
                placement: model.panelPlacement
            )
        )
        .frame(
            height: ConnCompactNotificationLayoutPolicy.rowHeight(
                messageTexts: batch.notifications.map(\.text),
                placement: model.panelPlacement
            )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = batch.notifications.last?.sessionID {
                model.selectSession(id)
                model.dismissCompactNotification()
                model.onToggleExpansion?()
            }
        }
        .accessibilityLabel("Conn Session update")
    }

    private func harnessBadge(_ attribution: ConnHarnessAttribution) -> some View {
        Group {
            if let assetName = attribution.assetName,
               let image = NSImage(named: assetName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
            } else {
                Text(attribution.label.prefix(1).uppercased())
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .frame(width: 26, height: 26)
                    .background(
                        .white.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            }
        }
        .accessibilityLabel(attribution.label)
    }

    private func metric(_ value: String, label: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("\(value) \(label)")
    }

    private func questionBinding(
        _ attentionID: AttentionRequestID,
        _ questionID: String
    ) -> Binding<String> {
        Binding(
            get: {
                model.questionAnswer(
                    attentionID: attentionID,
                    questionID: questionID
                )
            },
            set: {
                model.updateQuestionAnswer(
                    attentionID: attentionID,
                    questionID: questionID,
                    value: $0
                )
            }
        )
    }

    private func toneColor(_ tone: ConnPresentationTone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .active: .mint
        case .attention: .orange
        case .success: .green
        case .failure: .red
        case .stale: .yellow
        }
    }

    private func activitySymbol(_ kind: ConnActivityKind) -> String {
        switch kind {
        case .userMessage: "person.fill"
        case .agentMessage: "sparkles"
        case .plan: "checklist"
        case .reasoning: "brain"
        case .command: "terminal"
        case .fileChange: "doc.badge.gearshape"
        case .toolCall: "wrench.and.screwdriver"
        case .subagent: "person.2"
        case .webSearch: "globe"
        case .image: "photo"
        case .compaction: "arrow.down.right.and.arrow.up.left"
        case .unknown: "circle.dotted"
        }
    }
}

private struct CompactNotificationWaveform: View {
    let reduceMotion: Bool
    @State private var appearedAt = Date()

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: reduceMotion
        )) { context in
            let elapsed = context.date.timeIntervalSince(appearedAt)
            HStack(alignment: .center, spacing: 1.8) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(.mint.opacity(index == 2 ? 1 : 0.78))
                        .frame(
                            width: 2,
                            height: ShellCompactShelfMotionPolicy.waveformHeight(
                                barIndex: index,
                                elapsed: elapsed,
                                reduceMotion: reduceMotion
                            )
                        )
                }
            }
        }
        .frame(width: 18, height: 16)
        .accessibilityHidden(true)
        .onAppear {
            appearedAt = Date()
        }
    }
}

private struct CompactNotificationCountdownRing: View {
    let duration: TimeInterval
    let reduceMotion: Bool
    @State private var progress = 1.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.14), lineWidth: 2)
            Circle()
                .trim(from: 0, to: reduceMotion ? 1 : progress)
                .stroke(
                    .mint,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
        .onAppear {
            progress = 1
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: max(duration, 0.1))) {
                progress = 0
            }
        }
    }
}

private struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(
                .white.opacity(configuration.isPressed ? 0.14 : 0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
