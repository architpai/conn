import AppKit
import ConnAppCore
import ConnDomain
import SwiftUI

public struct ConnSurfaceView<IntegrationSettingsContent: View>: View {
    @ObservedObject private var model: ConnViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                chrome
                expandedContent
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
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
            if model.isExpanded {
                Button {
                    model.onToggleExpansion?()
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }

            HStack(spacing: 10) {
                Button {
                    model.onToggleExpansion?()
                } label: {
                    HStack(spacing: 7) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
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

                if model.activeCount > 0 {
                    metric("\(model.activeCount)", label: "active Sessions", color: .mint)
                }
                if model.attentionCount > 0 {
                    metric("\(model.attentionCount)", label: "Attention Requests", color: .orange)
                }

                if model.isExpanded {
                    Button {
                        model.showsNewSessionComposer.toggle()
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
            } else if model.showsNewSessionComposer {
                newSessionComposer
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
        if let session = model.selectedSession {
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
                        if session.activities.isEmpty {
                            ContentUnavailableView(
                                "No Activity Yet",
                                systemImage: "waveform.path",
                                description: Text("Conn will show bounded Harness activity here.")
                            )
                            .padding(.top, 80)
                        } else {
                            ForEach(session.activities) { activity in
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activitySymbol(item.activity.kind))
                .frame(width: 18)
                .foregroundStyle(toneColor(item.tone))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.label)
                    .font(.system(size: 11, weight: .semibold))
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
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
                Picker(
                    "Model",
                    selection: $model.selectedFollowUpModelID
                ) {
                    Text("Current model").tag(Optional<ConnSessionModelID>.none)
                    ForEach(model.sessionModelOptions) { option in
                        Text(option.displayName).tag(Optional(option.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
                .disabled(
                    model.isLoadingSessionModels
                        || !canOverrideModel
                )
                .accessibilityLabel("Model for next message")
                .help(
                    canOverrideModel
                        ? "Use the current model or override the next follow-up."
                        : "Model changes are available when this Session is idle."
                )
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
            .onDisappear { model.persistPreferences() }
        }
    }

    private var newSessionComposer: some View {
        modalCard(
            title: "New Session",
            dismiss: { model.showsNewSessionComposer = false }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Workspace path", text: $model.newSessionWorkspace)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    if model.sessionModelOptions.isEmpty {
                        Button {
                            model.loadSessionModels()
                        } label: {
                            if model.isLoadingSessionModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Retry models", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isLoadingSessionModels)
                    } else {
                        Picker(
                            "Model",
                            selection: $model.selectedNewSessionModelID
                        ) {
                            ForEach(model.sessionModelOptions) { option in
                                Text(option.displayName).tag(Optional(option.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityLabel("Model for new Session")
                        .help(
                            model.sessionModelOptions.first(where: {
                                $0.id == model.selectedNewSessionModelID
                            })?.detail ?? "Model for the first message"
                        )
                    }
                    Spacer()
                }
                if let modelError = model.sessionModelError {
                    Text(modelError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextEditor(text: $model.newSessionPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button("Create Session") {
                        model.createSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.isPerformingAction
                            || model.selectedNewSessionModelID == nil
                    )
                }
            }
        }
        .onAppear {
            if model.newSessionWorkspace.isEmpty {
                model.newSessionWorkspace = model.defaultWorkspace
            }
            model.loadSessionModels()
        }
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
        HStack(spacing: 10) {
            Image(
                systemName: batch.notifications.last?.isFinal == true
                    ? "checkmark.circle.fill"
                    : "waveform.path"
            )
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(
                batch.notifications.last?.isFinal == true ? .green : .mint
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(batch.notifications) { notification in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(notification.sessionTitle)
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                        Text(notification.text)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
        .frame(height: 52)
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
                    .padding(5)
            } else {
                Text(attribution.label.prefix(1).uppercased())
                    .font(.system(size: 11, weight: .black, design: .rounded))
            }
        }
        .frame(width: 26, height: 26)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
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
