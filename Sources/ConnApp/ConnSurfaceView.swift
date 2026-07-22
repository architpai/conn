import AppKit
import SwiftUI
import ConnAppCore
import ConnDomain

struct ConnSurfaceView: View {
    @ObservedObject var model: ConnViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedQuestionInput: QuestionInputFocusID?
    @FocusState private var focusedNewThreadInput: NewThreadInputFocus?
    @FocusState private var isComposerFocused: Bool
    @State private var threadSearchQuery = ""
    @State private var activityExpansion: [String: Bool] = [:]
    @State private var lastAutoScrolledTranscriptKey: String?

    let questionInputFocus: ShellQuestionInputFocusCoordinator

    private struct QuestionInputFocusID: Hashable {
        let request: AppServerScopedRequestID
        let questionID: String
    }

    private enum NewThreadInputFocus: Hashable {
        case initialPrompt
    }

    private let accent = Color(red: 0.176, green: 0.831, blue: 0.745)

    var body: some View {
        let motion = ShellMotionPolicy.presentation(reduceMotion: reduceMotion)
        let islandShape = RoundedRectangle(
            cornerRadius: ShellGraphiteChromePolicy.cornerRadius(
                for: model.surfaceState,
                showsCompactShelf: model.surfaceState == .compact && model.compactShelf != nil
            ),
            style: .continuous
        )
        VStack(spacing: 0) {
            constantBar

            switch model.surfaceState {
            case .compact:
                if let shelf = model.compactShelf {
                    compactShelf(shelf)
                        .transition(
                            motion.style == .fadeOnly
                                ? .opacity
                                : .opacity.combined(with: .move(edge: .top))
                        )
                }
            case .expanded:
                if model.presentsExpandedContent {
                    expandedSurface
                        .transition(.opacity)
                } else {
                    // Keep the hosting view pinned to the authoritative panel
                    // size without constructing the transcript during resize.
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .background(Color.black)
        .clipShape(islandShape)
        .animation(
            .easeOut(
                duration: motion.style == .fadeOnly
                    ? 0.12
                    : ShellMotionPolicy.expandedContentFadeDuration
            ),
            value: model.presentsExpandedContent
        )
        .animation(
            motion.style == .fadeOnly
                ? .easeOut(duration: 0.12)
                : .spring(duration: 0.38, bounce: 0.1),
            value: model.compactShelf?.id
        )
        .onAppear {
            questionInputFocus.installDismissAction {
                focusedQuestionInput = nil
                focusedNewThreadInput = nil
            }
        }
        .onDisappear { questionInputFocus.clear() }
        .onChange(of: focusedQuestionInput) { _, input in
            questionInputFocus.updateFocused(input != nil || focusedNewThreadInput != nil)
        }
        .onChange(of: focusedNewThreadInput) { _, input in
            questionInputFocus.updateFocused(input != nil || focusedQuestionInput != nil)
        }
        .sheet(isPresented: $model.showsSharedDesktopLabs) {
            sharedDesktopLabsSheet
        }
        .confirmationDialog(
            "Remove the legacy Sidequest plugin?",
            isPresented: $model.showsLegacyPluginRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove exact legacy plugin", role: .destructive) {
                model.confirmLegacyPluginRemoval()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let candidate = model.pendingLegacyPluginCandidate {
                Text("Confirm \(candidate.pluginID) from \(candidate.marketplaceName). Conn sends only this captured App Server plugin identity. Managed-daemon threads are not stopped or changed.")
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Constant Graphite bar

    private var constantBar: some View {
        ZStack {
            Button { model.onToggleExpansion?() } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Button { model.onToggleExpansion?() } label: {
                        HStack(spacing: 7) {
                            connMark
                            if model.isExpanded {
                                Text("conn")
                                    .font(.system(size: 12.5, weight: .bold))
                                    .tracking(0.25)
                                    .transition(.opacity)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.isExpanded ? "Collapse Conn" : "Expand Conn")

                    if model.isExpanded {
                        Button { model.openCodex() } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 22, height: 22)
                                .background(.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.62))
                        .help(model.presentation?.genericOpenCodexDetail ?? "Opens Codex without targeting a thread.")
                        .accessibilityLabel("Open Codex")

                        Button {
                            model.showsThreadOptions = false
                            model.showsSettings.toggle()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 11.5, weight: .medium))
                                .frame(width: 22, height: 22)
                                .background(model.showsSettings ? .white.opacity(0.12) : .white.opacity(0.001), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(model.showsSettings ? 0.9 : 0.62))
                        .accessibilityLabel("Conn settings")
                        .popover(isPresented: $model.showsSettings, arrowEdge: .top) {
                            settingsPopover
                        }
                    }
                }
                .fixedSize()

                Spacer(minLength: model.panelPlacement == .physicalNotch ? 184 : 12)

                if let pills = model.presentation?.statusPills {
                    HStack(spacing: 7) {
                        ForEach(ShellStatusPillLayoutPolicy.orderedVisiblePills(
                            pills,
                            surface: model.surfaceState,
                            placement: model.panelPlacement
                        )) { pill in
                            Button {
                                model.openSession(pill.highestPriorityThreadID)
                            } label: {
                                Text("\(pill.count)")
                                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(Color.black.opacity(0.82))
                                    .frame(minWidth: 16, minHeight: 16)
                                    .padding(.horizontal, 2)
                                    .background(visualColor(pill.visualState), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(pill.accessibilityLabel)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 34)
        .background(Color(red: 0.018, green: 0.018, blue: 0.018))
    }

    private var connMark: some View {
        OrbitingConnMark(accent: accent, reduceMotion: reduceMotion)
        .accessibilityHidden(true)
    }

    private func compactShelf(_ shelf: ShellCompactShelfPresentation) -> some View {
        CompactShelfContent(
            shelf: shelf,
            notificationBatch: model.compactNotificationBatch,
            preferredHeight: model.compactShelfPreferredHeight,
            accent: accent,
            reduceMotion: reduceMotion,
            respondApproval: { model.respondToCompactApproval($0) },
            openThread: { model.openCompactNotification(threadID: $0) }
        )
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Default workspace").font(.caption.weight(.semibold))
                TextField("/absolute/path/to/project", text: $model.defaultWorkspace)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Text("New chats start here after you confirm a model and initial prompt.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("Thread recency").font(.caption.weight(.semibold))
                ForEach(ThreadPickerActivityWindow.allCases, id: \.self) { window in
                    Button {
                        model.threadPickerActivityWindow = window
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(accent)
                                .frame(width: 12)
                                .opacity(model.threadPickerActivityWindow == window ? 1 : 0)
                            Text(window.settingsLabel)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        model.threadPickerActivityWindow == window ? .isSelected : []
                    )
                }
                Text("Active jobs stay visible regardless of this window.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Sync") { model.requestSync() }
                    .disabled(!model.canRequestSync)
            }
            .buttonStyle(.bordered)

            Button {
                model.openSharedDesktopLabs()
            } label: {
                Label("Shared Desktop Labs", systemImage: "laptopcomputer.and.iphone")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Display").font(.caption.weight(.semibold))
                ForEach(model.availableDisplays) { display in
                    Button {
                        model.onSelectDisplay?(display.id)
                        model.showsSettings = false
                    } label: {
                        HStack {
                            Image(systemName: display.isSelected ? "checkmark.circle.fill" : "display")
                            Text(display.name.isEmpty ? "Built-in display" : display.name)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                Button {
                    model.isPresentationPaused.toggle()
                } label: {
                    Label(
                        model.isPresentationPaused ? "Resume Conn" : "Pause Conn",
                        systemImage: model.isPresentationPaused ? "play.fill" : "pause.fill"
                    )
                }
                Button {
                    model.showsSettings = false
                    model.onHidePresentation?()
                } label: {
                    Label("Hide Conn", systemImage: "eye.slash")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(width: 270)
    }

    private var sharedDesktopLabsSheet: some View {
        let availableScreenHeight = NSScreen.screens
            .map(\.visibleFrame.height)
            .min() ?? SharedDesktopLabsLayoutPolicy.preferredViewportHeight
        let viewportHeight = SharedDesktopLabsLayoutPolicy.viewportHeight(
            availableHeight: availableScreenHeight
        )
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHARED DESKTOP MODE")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                    Text("One-click socket setup · Labs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { model.showsSharedDesktopLabs = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 14)

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Conn installs a private current-user LaunchAgent so one named environment flag returns at login. It never edits the signed app, stops the daemon, or changes remote control.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.sharedDesktopSetupEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Restart Codex Desktop once", systemImage: "arrow.clockwise.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text("Required after enabling: fully quit Codex Desktop, reopen it, then return here and run diagnosis. Closing only the window is not enough.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if let diagnostics = model.sharedDesktopDiagnostics {
                        let presentation = diagnostics.presentation
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(presentation.status)
                                    .font(.headline)
                                Spacer()
                                Text(
                                    diagnostics.socketTransportPrerequisitesPassed
                                        ? "SOCKET READY"
                                        : sharedDesktopStatusBadge(presentation.state)
                                )
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(
                                        diagnostics.socketTransportPrerequisitesPassed
                                            ? Color.green
                                            : sharedDesktopStatusColor(presentation.state)
                                    )
                            }
                            Text(
                                diagnostics.socketTransportPrerequisitesPassed
                                    ? "The managed Unix socket is ready and no direct private Desktop stdio child was detected."
                                    : presentation.detail
                            )
                                .font(.callout)
                            Text(diagnostics.host.versionLabel)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(
                                model.sharedDesktopSetupEnabled
                                    ? "Conn preference enabled · login-persistent flag managed by Conn"
                                    : diagnostics.host.setupLabel
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(diagnostics.host.attachmentLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        ContentUnavailableView(
                            model.isDiagnosingSharedDesktop ? "Diagnosing" : "Not diagnosed",
                            systemImage: "laptopcomputer.trianglebadge.exclamationmark",
                            description: Text("Diagnosis is read-only and records no conversation content.")
                        )
                        .frame(maxWidth: .infinity)
                    }

                    Button {
                        model.beginSharedDesktopSetup()
                    } label: {
                        HStack {
                            if model.isSettingUpSharedDesktop {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "bolt.horizontal.circle.fill")
                            }
                            Text(model.isSettingUpSharedDesktop ? "Setting up…" : "Set up Shared Desktop")
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSetUpSharedDesktop)

                    if model.sharedDesktopSetupEnabled {
                        Button("Turn off Shared Desktop") {
                            model.beginSharedDesktopTurnOff()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isSettingUpSharedDesktop || model.isDiagnosingSharedDesktop)
                    }

                    HStack {
                        Button {
                            model.requestSharedDesktopDiagnosis()
                        } label: {
                            if model.isDiagnosingSharedDesktop {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Run diagnosis", systemImage: "waveform.path.ecg")
                            }
                        }
                        .disabled(model.isDiagnosingSharedDesktop || model.isSettingUpSharedDesktop)
                    }
                    .buttonStyle(.bordered)

                    if model.isSettingUpSharedDesktop || model.sharedDesktopSetupResult != nil {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("SETUP ACTIVITY")
                                .font(.caption2.weight(.bold))
                                .tracking(0.7)
                            if model.isSettingUpSharedDesktop {
                                Label("Running bounded setup checks", systemImage: "ellipsis.circle")
                                    .font(.caption)
                            }
                            ForEach(model.sharedDesktopSetupResult?.logs ?? []) { entry in
                                Label(entry.message, systemImage: sharedDesktopLogIcon(entry.state))
                                    .font(.caption)
                                    .foregroundStyle(sharedDesktopLogColor(entry.state))
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if let notice = model.sharedDesktopPromptNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("If Codex Desktop was already open, relaunch it once after setup or turn-off. Diagnose verifies Conn's LaunchAgent, current-login flag, private socket, daemon readiness, and Desktop process selection. Unknown versions remain experimental.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 14)
                .padding(.trailing, 8)
            }
        }
        .padding(20)
        .frame(width: 500, height: viewportHeight)
        .accessibilityElement(children: .contain)
    }

    private func sharedDesktopStatusBadge(_ state: SharedDesktopModeState) -> String {
        switch state {
        case .verified: "VERIFIED"
        case .candidateUnqualified, .awaitingDesktopThread, .observingCandidate,
             .rollbackRequired: "CANDIDATE"
        case .relaunchRequired: "RESTART NEEDED"
        default: "NOT READY"
        }
    }

    private func sharedDesktopStatusColor(_ state: SharedDesktopModeState) -> Color {
        switch state {
        case .verified: .green
        case .candidateUnqualified, .awaitingDesktopThread, .observingCandidate,
             .rollbackRequired: .cyan
        default: .orange
        }
    }

    private func sharedDesktopLogIcon(_ state: SharedDesktopSetupLogEntry.State) -> String {
        switch state {
        case .running: "ellipsis.circle"
        case .passed: "checkmark.circle.fill"
        case .needsAction: "arrow.clockwise.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func sharedDesktopLogColor(_ state: SharedDesktopSetupLogEntry.State) -> Color {
        switch state {
        case .running: .secondary
        case .passed: .green
        case .needsAction: .orange
        case .failed: .red
        }
    }

    // MARK: Expanded workspace

    private var expandedSurface: some View {
        VStack(spacing: 0) {
            if model.showsIntegrationDiagnostic {
                integrationDiagnostic
            }
            graphiteHeader
            Divider().overlay(palette.line)
            if model.showsNewThreadComposer {
                newThreadComposer
            } else if let thread = model.selectedPresentation {
                transcript(thread)
                Divider().overlay(palette.line)
                composer(thread)
            } else {
                idleState
            }
        }
        .foregroundStyle(palette.text)
        .background(palette.surface)
        .onAppear {
            model.beginInteraction()
            model.requestComposerModels()
            model.qualifySelectedSessionForExpandedPresentation()
            DispatchQueue.main.async { isComposerFocused = model.selectedPresentation != nil }
        }
        .onDisappear { model.endInteraction() }
        .onChange(of: model.selectedSessionID) { _, selected in
            model.showsThreadOptions = false
            if selected != nil {
                model.requestComposerModels()
                DispatchQueue.main.async { isComposerFocused = true }
            }
        }
        .onChange(of: model.surfaceState) { _, surface in
            if surface == .compact { model.showsThreadOptions = false }
        }
        .onChange(of: model.phase9AffordancePolicy.isComposerEnabled) { _, enabled in
            if enabled, model.selectedSessionID != nil {
                DispatchQueue.main.async { isComposerFocused = true }
            }
        }
    }

    private var graphiteHeader: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.28, bounce: 0.12)) {
                    model.showsSettings = false
                    model.showsThreadOptions.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    stateDot(
                        model.showsNewThreadComposer
                            ? .idle
                            : (model.selectedPresentation?.visualState ?? .unknown)
                    )
                    Text(
                        model.showsNewThreadComposer
                            ? "New chat"
                            : (model.selectedPresentation?.title ?? "Choose a thread")
                    )
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(palette.dim)
                        .rotationEffect(.degrees(model.showsThreadOptions ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help(
                model.showsNewThreadComposer
                    ? "New chat in the default workspace"
                    : (model.selectedPresentation?.metaLabel ?? "Select a connected thread")
            )
            .accessibilityLabel("Choose a thread")
            .accessibilityValue(
                "\(model.showsNewThreadComposer ? "New chat" : (model.selectedPresentation?.title ?? "No thread selected")), \(model.showsThreadOptions ? "expanded" : "collapsed")"
            )

            Spacer(minLength: 8)

            if !model.showsNewThreadComposer,
               model.selectedPresentation?.isOutcomeUnreviewed == true {
                Button("Mark reviewed") { model.markSelectedOutcomeReviewed() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if let newThreadError = model.newThreadError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(newThreadError)
                    .accessibilityLabel(newThreadError)
            }

            Button {
                model.startNewChat()
            } label: {
                if model.isCreatingThread {
                    ProgressView().controlSize(.small)
                } else {
                    Label("New chat", systemImage: "plus")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .foregroundStyle(.black)
            .controlSize(.small)
            .disabled(model.isCreatingThread)
            .help(
                model.newThreadError
                    ?? model.newThreadNotice
                    ?? "Choose a model and start a chat in the default workspace"
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(palette.sidebar)
        .overlay(alignment: .topLeading) {
            if model.showsThreadOptions {
                threadOptionsPanel
                    .offset(x: 12, y: 36)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading))
                    )
                    .zIndex(10)
            }
        }
        .zIndex(model.showsThreadOptions ? 10 : 0)
    }

    private var threadOptionsPanel: some View {
        let result = model.threadPickerResult(searchText: threadSearchQuery)
        let listHeight = result.isEmpty
            ? CGFloat(52)
            : min(CGFloat(result.rows.count) * 41 + 8, 240)
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.dim)
                    TextField("Search threads or projects", text: $threadSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                    if !threadSearchQuery.isEmpty {
                        Button { threadSearchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(palette.dim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear thread search")
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 4) {
                    threadGroupingButton("Threads", mode: .threads)
                    threadGroupingButton("By project", mode: .projects)
                    Spacer(minLength: 8)
                    Text(model.threadPickerActivityWindow.settingsLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(palette.dim)
                }
            }
            .padding(8)

            Divider().overlay(palette.line)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if result.isEmpty {
                        Text(threadSearchQuery.isEmpty ? "No recent threads" : "No matching threads")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(palette.dim)
                            .padding(10)
                    } else if result.grouping == .project {
                        ForEach(result.groups) { group in
                            Text(group.projectLabel)
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.55)
                                .foregroundStyle(palette.dim)
                                .textCase(.uppercase)
                                .padding(.horizontal, 9)
                                .padding(.top, 7)
                                .padding(.bottom, 2)
                            ForEach(group.rows) { row in
                                threadOption(row, showsProjectLabel: false)
                            }
                        }
                    } else {
                        ForEach(result.rows) { row in
                            threadOption(row, showsProjectLabel: true)
                        }
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.hidden)
            .frame(height: listHeight)
        }
        .frame(width: 340)
        .background(palette.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 18, y: 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread options")
    }

    private func threadGroupingButton(_ title: String, mode: ShellSidebarMode) -> some View {
        let isSelected = model.sidebarMode == mode
        return Button {
            model.sidebarMode = mode
        } label: {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black : palette.dim)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(isSelected ? accent : palette.card, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func threadOption(
        _ row: ThreadPickerRow,
        showsProjectLabel: Bool
    ) -> some View {
        let thread = row.thread
        let isSelected = model.selectedSessionID == thread.id
        return Button {
            model.selectSession(thread.id)
            model.showsThreadOptions = false
            DispatchQueue.main.async { isComposerFocused = true }
        } label: {
            HStack(spacing: 8) {
                stateDot(thread.visualState)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(thread.statusLabel)
                        if showsProjectLabel {
                            Spacer(minLength: 8)
                            Text(row.projectLabel)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(palette.dim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                isSelected ? accent.opacity(0.09) : Color.white.opacity(0.001),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var masterColumn: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Picker("Thread grouping", selection: $model.sidebarMode) {
                    Text("Threads").tag(ShellSidebarMode.threads)
                    Text("Projects").tag(ShellSidebarMode.projects)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button { model.showNewThread() } label: {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                }
                .buttonStyle(.plain)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(palette.line.opacity(0.75))
                }
                .accessibilityLabel("New Codex thread")

                Button { model.requestSync() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(palette.line.opacity(0.75))
                }
                .disabled(!model.canRequestSync)
                .opacity(model.canRequestSync ? 1 : 0.55)
                .help(model.canRequestSync ? "Refresh thread tiles" : "Sync is not connected yet")
                .accessibilityLabel("Sync thread tiles")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    switch model.sidebarMode {
                    case .threads:
                        ForEach(model.sessions) { threadRow($0) }
                    case .projects:
                        ForEach(model.projects) { project in
                            projectHeader(project)
                            if model.isProjectExpanded(project.id) {
                                ForEach(model.orderedThreads(in: project)) {
                                    threadRow($0, projectID: project.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.sidebar)
    }

    private func projectHeader(_ project: AppServerProjectPresentation) -> some View {
        Button { model.toggleProject(project.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isProjectExpanded(project.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(palette.dim)
                    .frame(width: 10)
                Text(project.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(project.activityLabel)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(toneColor(project.tone))
                    .lineLimit(1)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(palette.dim.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .draggable(projectDragValue(project.id))
        .dropDestination(for: String.self) { values, location in
            guard let sourceID = projectID(from: values.first) else { return false }
            return model.moveProject(
                sourceID,
                relativeTo: project.id,
                placement: location.y > 14 ? .after : .before
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(project.accessibilityLabel), \(model.isProjectExpanded(project.id) ? "expanded" : "collapsed")")
        .accessibilityHint("Activate to expand or collapse. Drag or use Move up and Move down to reorder projects.")
        .accessibilityAction(named: "Move up") {
            model.moveProject(project.id, direction: .up)
        }
        .accessibilityAction(named: "Move down") {
            model.moveProject(project.id, direction: .down)
        }
    }

    private func threadRow(
        _ thread: AppServerThreadPresentation,
        projectID: String? = nil
    ) -> some View {
        let selected = model.selectedSessionID == thread.id
        return Button { model.selectSession(thread.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                stateDot(thread.visualState).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(thread.headline)
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(palette.dim.opacity(0.55))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(accent).frame(width: 2, height: 24).padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(threadDragValue(thread.id))
        .dropDestination(for: String.self) { values, location in
            guard let sourceID = threadID(from: values.first) else { return false }
            return model.moveThread(
                sourceID,
                relativeTo: thread.id,
                placement: location.y > 20 ? .after : .before,
                withinProjectID: projectID
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(thread.accessibilityLabel)
        .accessibilityHint("Select this thread. Drag or use Move up and Move down to reorder threads.")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Move up") {
            model.moveThread(thread.id, direction: .up, withinProjectID: projectID)
        }
        .accessibilityAction(named: "Move down") {
            model.moveThread(thread.id, direction: .down, withinProjectID: projectID)
        }
    }

    private var newThreadComposer: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("New chat")
                        .font(.headline)
                    Text("Default workspace · \(model.defaultWorkspace)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.dim)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") { model.cancelNewThread() }
                    .buttonStyle(.bordered)
                    .disabled(model.isCreatingThread)
            }
            .controlSize(.small)
            .padding(.horizontal, 18)
            .frame(height: 64)

            Divider().overlay(palette.line)

            ContentUnavailableView(
                "Start a conversation",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Your first message creates the chat in the default workspace.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.newThreadError != nil || model.newThreadModelError != nil {
                Text(model.newThreadError ?? model.newThreadModelError ?? "")
                    .font(.caption2)
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }

            Divider().overlay(palette.line)

            HStack(alignment: .center, spacing: 10) {
                if model.newThreadModelOptions.isEmpty {
                    Button {
                        model.requestNewThreadModels()
                    } label: {
                        if model.isLoadingNewThreadModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Retry models", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isLoadingNewThreadModels || model.isCreatingThread)
                    .help(model.newThreadModelError ?? "Loading models from App Server")
                } else {
                    Picker(
                        "Model",
                        selection: Binding(
                            get: { model.selectedNewThreadModelID },
                            set: { model.updateNewThreadModel($0) }
                        )
                    ) {
                        ForEach(model.newThreadModelOptions) { option in
                            Text(option.displayName).tag(Optional(option.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 150)
                    .disabled(model.isLoadingNewThreadModels || model.isCreatingThread)
                    .accessibilityLabel("Model for new chat")
                    .accessibilityValue(model.selectedNewThreadModel?.displayName ?? "Unavailable")
                    .help(model.selectedNewThreadModelDetail ?? "Model for the first message")
                }

                TextField(
                    "Message your new chat…",
                    text: Binding(
                        get: { model.newThreadInitialPrompt },
                        set: { model.updateNewThreadInitialPrompt($0) }
                    )
                )
                .textFieldStyle(.plain)
                .focused($focusedNewThreadInput, equals: .initialPrompt)
                .disabled(model.isCreatingThread)
                .onSubmit {
                    if model.canSubmitNewThread { model.submitNewThread() }
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 9))
                .help(model.newThreadCreationDetail)

                if model.isCreatingThread {
                    ProgressView().controlSize(.small)
                }
                Button { model.submitNewThread() } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .foregroundStyle(.black)
                .disabled(!model.canSubmitNewThread)
                .accessibilityLabel(
                    model.canSubmitNewThread
                        ? "Send first message"
                        : "Send first message, unavailable"
                )
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(palette.sidebar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface)
        .onAppear {
            DispatchQueue.main.async { focusedNewThreadInput = .initialPrompt }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let thread = model.selectedPresentation {
            VStack(spacing: 0) {
                detailHeader(thread)
                Divider().overlay(palette.line)
                transcript(thread)
                Divider().overlay(palette.line)
                composer(thread)
            }
        } else {
            ContentUnavailableView(
                "Select a connected thread",
                systemImage: "rectangle.stack",
                description: Text("Choose a thread to inspect its bounded App Server activity.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ thread: AppServerThreadPresentation) -> some View {
        HStack(spacing: 12) {
            stateDot(thread.visualState)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(thread.title)
                        .font(.headline)
                        .lineLimit(1)
                    statusChip(thread.statusLabel, state: thread.visualState, accessibilityLabel: thread.statusAccessibilityLabel)
                }
                if let metaLabel = thread.metaLabel {
                    Text(metaLabel)
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.dim)
                        .lineLimit(1)
                }
            }
            Spacer()
            if thread.isOutcomeUnreviewed {
                Button { model.markSelectedOutcomeReviewed() } label: {
                    Label("Mark reviewed", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .help("Marks only this exact completed turn as reviewed.")
            }
            Button("Stop turn") { model.stopSelectedTurn() }
                .buttonStyle(.bordered)
                .disabled(!model.phase9AffordancePolicy.isStopEnabled)
                .help(model.phase9AffordancePolicy.detail)
            Button { model.openCodex() } label: {
                Label("Open in Codex", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .foregroundStyle(.black)
            .help(model.presentation?.genericOpenCodexDetail ?? "Opens Codex without targeting this thread.")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    private enum TranscriptEntry: Identifiable {
        case timeline(AppServerTimelineItemPresentation)
        case activity(
            [AppServerTimelineItemPresentation],
            segmentID: String,
            hasFollowingUserFacingText: Bool
        )
        case plan(AppServerTurnPlanPresentation)
        case attention(AppServerAttentionPresentation)

        var id: String {
            switch self {
            case let .timeline(item): "timeline:\(item.id)"
            case let .activity(_, segmentID, _): "activity:\(segmentID)"
            case let .plan(plan): "plan:\(plan.updatedAt.timeIntervalSinceReferenceDate)"
            case let .attention(attention): "attention:\(attention.id)"
            }
        }

        var autoScrollRevision: String {
            switch self {
            case let .timeline(item):
                Self.timelineRevision(item)
            case let .activity(items, _, hasFollowingUserFacingText):
                items.map(Self.timelineRevision).joined(separator: "|")
                    + "|summary:\(hasFollowingUserFacingText)"
            case let .plan(plan):
                "plan:\(plan.updatedAt.timeIntervalSinceReferenceDate)"
            case let .attention(attention):
                "attention:\(attention.observedAt.timeIntervalSinceReferenceDate):\(attention.detail)"
            }
        }

        private static func timelineRevision(
            _ item: AppServerTimelineItemPresentation
        ) -> String {
            [
                item.id,
                item.title,
                item.detail ?? "",
                item.statusLabel,
                String(item.observedAt.timeIntervalSinceReferenceDate),
            ]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: ",")
        }

        var observedAt: Date {
            switch self {
            case let .timeline(item): item.observedAt
            case let .activity(items, _, _): items.last?.observedAt ?? .distantPast
            case let .plan(plan): plan.updatedAt
            case let .attention(attention): attention.observedAt
            }
        }

        var sourceOrder: Int {
            switch self {
            case let .timeline(item): item.sourceOrder
            case let .activity(items, _, _): items.first?.sourceOrder ?? .max
            case .plan, .attention: .max
            }
        }
    }

    private func transcriptEntries(_ thread: AppServerThreadPresentation) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        var activity: [AppServerTimelineItemPresentation] = []
        var activityTurnID: String?
        var activitySegmentID: String?
        var precedingBoundaryID: String?
        func flushActivity(hasFollowingUserFacingText: Bool = false) {
            guard !activity.isEmpty else { return }
            entries.append(.activity(
                activity,
                segmentID: activitySegmentID ?? ShellTranscriptActivityPolicy.segmentID(
                    turnID: activityTurnID,
                    precedingBoundaryID: precedingBoundaryID
                ),
                hasFollowingUserFacingText: hasFollowingUserFacingText
            ))
            activity.removeAll(keepingCapacity: true)
            activityTurnID = nil
            activitySegmentID = nil
        }
        for item in thread.timeline {
            if isOperationalActivity(item.category) {
                if !activity.isEmpty, activityTurnID != item.turnID { flushActivity() }
                if activity.isEmpty {
                    activitySegmentID = ShellTranscriptActivityPolicy.segmentID(
                        turnID: item.turnID,
                        precedingBoundaryID: precedingBoundaryID
                    )
                }
                activityTurnID = item.turnID
                activity.append(item)
            } else {
                flushActivity(hasFollowingUserFacingText:
                    activityTurnID == item.turnID
                        && (item.category == .agentOutput || item.category == .finalAnswer)
                )
                entries.append(.timeline(item))
                // Every non-operational entry splits activity groups. Use it
                // as the next stable segment boundary, including plan/outcome
                // entries, so same-turn groups cannot share an identity.
                precedingBoundaryID = item.id
            }
        }
        flushActivity()
        if let plan = thread.plan { entries.append(.plan(plan)) }
        if let attention = thread.attention { entries.append(.attention(attention)) }
        let sorted = entries.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            if $0.sourceOrder != $1.sourceOrder { return $0.sourceOrder < $1.sourceOrder }
            return $0.id < $1.id
        }
        let maximumEntryCount = ShellTranscriptActivityPolicy.maximumVisibleEntryCount
        guard sorted.count > maximumEntryCount else { return sorted }

        // The transcript cap applies after plan/request cards are merged. Keep
        // the one unresolved attention card even when it predates the newest
        // timeline items so the visible status never loses its explanation.
        if let attention = sorted.last(where: {
            if case .attention = $0 { return true }
            return false
        }) {
            let newestNonAttention = sorted.filter {
                if case .attention = $0 { return false }
                return true
            }.suffix(maximumEntryCount - 1)
            return (Array(newestNonAttention) + [attention]).sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
                if $0.sourceOrder != $1.sourceOrder { return $0.sourceOrder < $1.sourceOrder }
                return $0.id < $1.id
            }
        }
        return Array(sorted.suffix(maximumEntryCount))
    }

    private func transcript(_ thread: AppServerThreadPresentation) -> some View {
        let entries = transcriptEntries(thread)
        let latestActivityID = entries.reversed().first(where: {
            if case .activity = $0 { return true }
            return false
        })?.id
        let autoScrollKey = ShellTranscriptActivityPolicy.autoScrollKey(
            threadID: thread.id,
            tailID: entries.last?.id,
            tailRevision: entries.last?.autoScrollRevision
        )
        return ScrollViewReader { reader in
            ScrollView {
                // The transcript is deliberately capped, so eagerly laying out
                // its small set avoids LazyVStack placement churn when a
                // DisclosureGroup changes height while new events arrive.
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(entries) {
                        transcriptEntry(
                            $0,
                            visualState: thread.visualState,
                            latestActivityID: latestActivityID
                        )
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                scrollToNewest(entries, key: autoScrollKey, with: reader)
            }
            .onChange(of: autoScrollKey) { _, newKey in
                scrollToNewest(entries, key: newKey, with: reader)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func transcriptEntry(
        _ entry: TranscriptEntry,
        visualState: AppServerThreadVisualState,
        latestActivityID: String?
    ) -> some View {
        switch entry {
        case let .timeline(item):
            timelineItem(item)
        case let .activity(items, _, hasFollowingUserFacingText):
            activityGroup(
                items,
                groupID: entry.id,
                autoExpand: ShellTranscriptActivityPolicy.shouldAutoExpand(
                    isLatestActivity: entry.id == latestActivityID,
                    hasFollowingUserFacingText: hasFollowingUserFacingText,
                    visualState: visualState
                )
            )
        case let .plan(plan):
            planCard(plan)
        case let .attention(attention):
            if attention.responseStyle == .approval {
                approvalCard(attention)
            } else {
                inputRequestCard(attention)
            }
        }
    }

    @ViewBuilder
    private func timelineItem(_ item: AppServerTimelineItemPresentation) -> some View {
        switch item.category {
        case .userMessage:
            HStack {
                Spacer(minLength: 80)
                Text(item.detail ?? item.title)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityLabel)
        case .agentOutput:
            VStack(alignment: .leading, spacing: 7) {
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                if item.isDetailTruncated, let expandedDetail = item.expandedDetail {
                    DisclosureGroup("Show full commentary") {
                        Text(expandedDetail)
                            .font(.system(size: 13.5))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .padding(.top, 5)
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent)
                }
                timelineMeta(item)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityLabel)
        case .finalAnswer:
            VStack(alignment: .leading, spacing: 7) {
                if let detail = item.detail {
                    Text(detail)
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                if item.isDetailTruncated, let expandedDetail = item.expandedDetail {
                    DisclosureGroup("Show full answer") {
                        Text(expandedDetail)
                            .font(.system(size: 13.5))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .padding(.top, 5)
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent)
                }
                timelineMeta(item)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityLabel)
        case .reasoning:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.detail ?? item.title)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(palette.dim)
                timelineMeta(item)
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(palette.line).frame(width: 2) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityLabel)
        case .command:
            transcriptCard(item, icon: "terminal", monospaced: true)
        case .fileChange:
            transcriptCard(item, icon: "doc.badge.gearshape", monospaced: true)
        case .outcome:
            banner(item)
        case .plan:
            transcriptCard(item, icon: "checklist", monospaced: false)
        default:
            transcriptCard(item, icon: icon(for: item.category), monospaced: false)
        }
    }

    private func isOperationalActivity(_ category: AppServerTimelineCategory) -> Bool {
        switch category {
        case .reasoning, .command, .fileChange, .tool, .subagent, .webSearch,
             .image, .lifecycle, .compaction, .unknown:
            true
        case .userMessage, .agentOutput, .finalAnswer, .outcome, .plan:
            false
        }
    }

    private func activityGroup(
        _ items: [AppServerTimelineItemPresentation],
        groupID: String,
        autoExpand: Bool
    ) -> some View {
        let isExpanded = Binding(
            get: {
                ShellTranscriptActivityPolicy.expansionState(
                    stored: activityExpansion[groupID],
                    autoExpand: autoExpand
                )
            },
            set: { requested in
                guard let update = ShellTranscriptActivityPolicy.expansionUpdate(
                    stored: activityExpansion[groupID],
                    requested: requested
                ) else { return }
                activityExpansion[groupID] = update
            }
        )
        return DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: item.category))
                            .font(.system(size: 10))
                            .foregroundStyle(toneColor(item.tone))
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 10.5, weight: .semibold))
                            if let detail = item.detail {
                                Text(detail)
                                    .font(.system(size: 9.5, design: item.category == .command ? .monospaced : .default))
                                    .foregroundStyle(palette.dim)
                                    .lineLimit(4)
                            }
                            if item.statusLabel != "Completed" {
                                Text(item.statusLabel)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(toneColor(item.tone))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityLabel)
                }
            }
            .padding(.top, 8)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "hammer")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.dim)
                Text(items.count == 1 ? "1 activity" : "\(items.count) activities")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
                if let latest = items.last {
                    Text(latest.observedLabel)
                        .font(.system(size: 9.5))
                        .foregroundStyle(palette.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private func transcriptCard(
        _ item: AppServerTimelineItemPresentation,
        icon: String,
        monospaced: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(toneColor(item.tone)).frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.title).font(.caption.weight(.semibold))
                    Spacer()
                    statusChip(item.statusLabel, color: toneColor(item.tone), accessibilityLabel: item.statusLabel)
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(monospaced ? .caption.monospaced() : .caption)
                        .foregroundStyle(palette.dim)
                        .lineLimit(AppServerTimelineItemPresentation.maximumVisibleDetailLineCount)
                }
                timelineMeta(item)
            }
        }
        .padding(11)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
    }

    private func banner(_ item: AppServerTimelineItemPresentation) -> some View {
        Label(item.title, systemImage: item.tone == .failure ? "xmark.octagon.fill" : "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(toneColor(item.tone))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(toneColor(item.tone).opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(item.accessibilityLabel)
    }

    private func approvalCard(_ attention: AppServerAttentionPresentation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(attention.title, systemImage: "exclamationmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.yellow)
            Text(attention.detail).font(.caption).foregroundStyle(palette.dim)
            HStack {
                if attention.availableApprovalChoices.contains(.approve) {
                    Button("Approve") { model.respondToSelectedApproval(.approve) }
                        .disabled(!model.phase9AffordancePolicy.areApprovalResponsesEnabled)
                }
                if attention.availableApprovalChoices.contains(.approveForSession) {
                    Button("Approve for session") {
                        model.respondToSelectedApproval(.approveForSession)
                    }
                    .disabled(!model.phase9AffordancePolicy.areApprovalResponsesEnabled)
                }
                if attention.availableApprovalChoices.contains(.deny) {
                    Button("Deny") { model.respondToSelectedApproval(.deny) }
                        .disabled(!model.phase9AffordancePolicy.areApprovalResponsesEnabled)
                }
                Spacer()
                Text(model.phase9AffordancePolicy.detail)
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.yellow.opacity(0.18)) }
        .accessibilityElement(children: .contain)
    }

    private func inputRequestCard(_ attention: AppServerAttentionPresentation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(attention.title, systemImage: "questionmark.bubble.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.yellow)
            Text(attention.detail).font(.caption).foregroundStyle(palette.dim)
            ForEach(attention.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.header).font(.caption.weight(.semibold))
                    Text(question.prompt).font(.caption).foregroundStyle(palette.dim)
                    if let options = question.options {
                        ForEach(options, id: \.self) { option in
                            let isSelected = model.questionAnswer(
                                request: attention.scopedRequestID,
                                questionID: question.id
                            ) == option.label
                            Button {
                                model.updateQuestionAnswer(
                                    option.label,
                                    request: attention.scopedRequestID,
                                    questionID: question.id
                                )
                            } label: {
                                HStack {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                        if !option.detail.isEmpty {
                                            Text(option.detail).font(.caption2).foregroundStyle(palette.dim)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.phase9AffordancePolicy.areQuestionResponsesEnabled)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    if question.options == nil || question.permitsOther {
                        if question.isSecret {
                            SecureField(
                                "Answer",
                                text: questionBinding(attention: attention, question: question)
                            )
                            .textFieldStyle(.roundedBorder)
                            .focused(
                                $focusedQuestionInput,
                                equals: .init(
                                    request: attention.scopedRequestID,
                                    questionID: question.id
                                )
                            )
                        } else {
                            TextField(
                                "Answer",
                                text: questionBinding(attention: attention, question: question)
                            )
                            .textFieldStyle(.roundedBorder)
                            .focused(
                                $focusedQuestionInput,
                                equals: .init(
                                    request: attention.scopedRequestID,
                                    questionID: question.id
                                )
                            )
                        }
                    }
                }
                .padding(.top, 4)
            }
            Button("Submit answers") { model.answerSelectedQuestions() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.phase9AffordancePolicy.areQuestionResponsesEnabled)
            Text(model.phase9AffordancePolicy.detail)
                .font(.caption2)
                .foregroundStyle(palette.dim)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.yellow.opacity(0.18)) }
        .accessibilityElement(children: .contain)
    }

    private func questionBinding(
        attention: AppServerAttentionPresentation,
        question: AppServerStructuredQuestion
    ) -> Binding<String> {
        Binding(
            get: {
                model.questionAnswer(
                    request: attention.scopedRequestID,
                    questionID: question.id
                )
            },
            set: {
                model.updateQuestionAnswer(
                    $0,
                    request: attention.scopedRequestID,
                    questionID: question.id
                )
            }
        )
    }

    private func planCard(_ plan: AppServerTurnPlanPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.title).font(.caption.weight(.bold))
            ForEach(plan.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: planSymbol(step.state))
                        .foregroundStyle(planColor(step.state))
                        .frame(width: 14)
                    Text(step.text)
                        .font(.caption)
                        .foregroundStyle(step.state == .completed ? palette.dim : palette.text)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(step.accessibilityLabel)
            }
        }
        .padding(12)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func composer(_ thread: AppServerThreadPresentation) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Picker(
                "Model",
                selection: Binding(
                    get: { model.selectedFollowUpModelID },
                    set: { model.updateSelectedFollowUpModel($0) }
                )
            ) {
                Text(model.selectedThreadModelLabel).tag(Optional<String>.none)
                ForEach(model.newThreadModelOptions) { option in
                    Text(option.displayName).tag(Optional(option.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 230, alignment: .leading)
            .disabled(!model.canSelectFollowUpModel)
            .help(
                model.canSelectFollowUpModel
                    ? "Use \(model.selectedThreadModelLabel) or override the next follow-up."
                    : "This active task is running \(model.selectedThreadModelLabel)."
            )
            .accessibilityLabel("Model for next message")
            .accessibilityValue(
                model.selectedFollowUpModelID.flatMap { selectedID in
                    model.newThreadModelOptions.first(where: { $0.id == selectedID })?.displayName
                } ?? model.selectedThreadModelLabel
            )
            TextField(
                "Message this thread…",
                text: Binding(
                    get: { model.selectedDraftText },
                    set: { model.updateSelectedDraft($0) }
                )
            )
            .textFieldStyle(.plain)
            .focused($isComposerFocused)
            .disabled(!model.phase9AffordancePolicy.isComposerEnabled)
            .onSubmit { model.submitSelectedDraft() }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 9))
            .help(
                model.selectedActionError
                    ?? model.selectedActionNotice
                    ?? model.phase9AffordancePolicy.detail
            )
            if let usage = thread.tokenUsage {
                contextRing(usage)
            }
            Button {
                if model.phase9AffordancePolicy.isStopEnabled {
                    model.stopSelectedTurn()
                } else {
                    model.submitSelectedDraft()
                }
            } label: {
                Image(systemName: model.phase9AffordancePolicy.isStopEnabled ? "stop.fill" : "arrow.up")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .foregroundStyle(.black)
            .disabled(
                model.phase9AffordancePolicy.isStopEnabled
                    ? false
                    : !model.phase9AffordancePolicy.isSendEnabled
            )
            .accessibilityLabel(
                model.phase9AffordancePolicy.isStopEnabled
                    ? "Stop turn"
                    : model.phase9AffordancePolicy.isSendEnabled
                    ? "Send message"
                    : "Send message, unavailable"
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(palette.sidebar)
    }

    private func contextRing(_ usage: AppServerTokenUsagePresentation) -> some View {
        let color = usage.isWarning ? Color.yellow : accent
        return ZStack {
            Circle().stroke(palette.line, lineWidth: 3)
            Circle()
                .trim(from: 0, to: usage.ringProgress ?? 0)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(usage.percentageLabel)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(width: 34, height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usage.accessibilityLabel)
    }

    private func scrollToNewest(
        _ entries: [TranscriptEntry],
        key: String?,
        with reader: ScrollViewProxy
    ) {
        guard let lastID = entries.last?.id else { return }
        guard ShellTranscriptActivityPolicy.shouldAutoScroll(
            previousKey: lastAutoScrolledTranscriptKey,
            nextKey: key
        ) else { return }
        lastAutoScrolledTranscriptKey = key
        reader.scrollTo(lastID, anchor: .bottom)
    }

    private func timelineMeta(_ item: AppServerTimelineItemPresentation) -> some View {
        Text("\(item.statusLabel) · \(item.observedLabel)")
            .font(.caption2)
            .foregroundStyle(palette.dim)
    }

    private var integrationDiagnostic: some View {
        let connection = model.connectionPresentation
        let isFailure = model.integrationError != nil || connection?.tone == .unavailable
        let color = isFailure ? Color.red : toneColor(connection?.tone ?? .unavailable)
        return HStack(spacing: 8) {
            Image(systemName: connection?.phase == .reconnecting ? "arrow.triangle.2.circlepath" : (isFailure ? "exclamationmark.triangle.fill" : "circle.fill"))
                .font(.system(size: isFailure ? 10 : 6, weight: .semibold))
                .foregroundStyle(color)
            Text(model.integrationError == nil ? connection?.title ?? "Starting Conn" : "Integration unavailable")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if isFailure {
                Text(model.integrationError ?? connection?.detail ?? "Conn could not connect to Codex.")
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
            }
            Spacer()
            if connection?.phase == .reconnecting {
                Text("Retrying")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(color.opacity(isFailure ? 0.28 : 0.10))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
    }

    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.dotted").font(.title2).foregroundStyle(palette.dim)
            Text(model.presentation == nil ? "Starting Conn" : "No connected threads")
                .font(.subheadline.weight(.semibold))
            Text(model.presentation?.connection.scopeLabel ?? "Conn is preparing its managed-daemon connection.")
                .font(.caption)
                .foregroundStyle(palette.dim)
                .multilineTextAlignment(.center)
            HStack {
                Button { model.startNewChat() } label: {
                    Label("New thread", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .foregroundStyle(.black)
                Button { model.openCodex() } label: {
                    Label("Open Codex", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func stateDot(_ state: AppServerThreadVisualState) -> some View {
        Circle()
            .fill(visualColor(state))
            .frame(width: 7, height: 7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accessibilityLabel)
    }

    private func statusChip(
        _ title: String,
        state: AppServerThreadVisualState,
        accessibilityLabel: String
    ) -> some View {
        statusChip(title, color: visualColor(state), accessibilityLabel: accessibilityLabel)
    }

    private func statusChip(_ title: String, color: Color, accessibilityLabel: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel(accessibilityLabel)
    }

    private func visualColor(_ state: AppServerThreadVisualState) -> Color {
        switch state {
        case .running: accent
        case .waitingForApproval: .yellow
        case .needsInput: Color(red: 0.49, green: 0.83, blue: 0.99)
        case .unreviewedOutcome: .green
        case .idle: Color(red: 0.42, green: 0.45, blue: 0.50)
        case .failed: Color(red: 0.97, green: 0.44, blue: 0.44)
        case .notLoaded, .unknown: .secondary
        }
    }

    private func toneColor(_ tone: AppServerPresentationTone) -> Color {
        switch tone {
        case .neutral: palette.dim
        case .active: accent
        case .attention, .warning: .yellow
        case .success: .green
        case .failure: .red
        case .unavailable: .orange
        }
    }

    private func icon(for category: AppServerTimelineCategory) -> String {
        switch category {
        case .reasoning: "text.bubble"
        case .command: "terminal"
        case .fileChange: "doc.badge.gearshape"
        case .tool: "wrench.and.screwdriver"
        case .subagent: "person.2"
        case .webSearch: "globe"
        case .image: "photo"
        case .compaction: "arrow.down.right.and.arrow.up.left"
        case .lifecycle: "circle.dotted"
        default: "circle"
        }
    }

    private func planSymbol(_ state: AppServerTurnPlanStepVisualState) -> String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted.circle.fill"
        case .pending: "circle"
        case .unknown: "questionmark.circle"
        }
    }

    private func planColor(_ state: AppServerTurnPlanStepVisualState) -> Color {
        switch state {
        case .completed: palette.dim
        case .inProgress: accent
        case .pending, .unknown: palette.dim
        }
    }

    private func threadDragValue(_ id: String) -> String {
        "conn.thread:\(id)"
    }

    private func projectDragValue(_ id: String) -> String {
        "conn.project:\(id)"
    }

    private func threadID(from value: String?) -> String? {
        guard let value, value.hasPrefix("conn.thread:") else { return nil }
        return String(value.dropFirst("conn.thread:".count))
    }

    private func projectID(from value: String?) -> String? {
        guard let value, value.hasPrefix("conn.project:") else { return nil }
        return String(value.dropFirst("conn.project:".count))
    }

    private var palette: Palette {
        model.appearance == .dark ? .dark : .light
    }
}

private struct CompactShelfContent: View {
    let shelf: ShellCompactShelfPresentation
    let notificationBatch: ShellUserFacingNotificationBatch?
    let preferredHeight: CGFloat
    let accent: Color
    let reduceMotion: Bool
    let respondApproval: (AppServerApprovalChoice) -> Void
    let openThread: (AppServerThreadID) -> Void

    var body: some View {
        Group {
            if shelf.mode == .approval {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        AnimatedShelfWaveform(accent: accent, reduceMotion: reduceMotion)
                        shelfText
                        Spacer(minLength: 6)
                    }
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        ForEach(
                            ShellCompactApprovalPolicy.visibleChoices(from: shelf.approvalChoices),
                            id: \.self
                        ) { choice in
                            compactApprovalButton(choice)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    if notificationBatch?.showsCompletionIndicator == true {
                        ShelfCompletionIndicator()
                    } else {
                        AnimatedShelfWaveform(accent: accent, reduceMotion: reduceMotion)
                    }
                    shelfText
                    Spacer(minLength: 6)
                    ShelfCountdownRing(
                        accent: accent,
                        duration: notificationBatch?.duration
                            ?? ShellCompactShelfMotionPolicy.defaultActivityLifetime,
                        reduceMotion: reduceMotion
                    )
                    .id(notificationBatch?.id ?? shelf.id)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: preferredHeight)
        .background(Color(red: 0.018, green: 0.018, blue: 0.018))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(shelf.verb), \(shelf.detail)")
        .contentTransition(.opacity)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.22),
            value: notificationBatch?.id
        )
    }

    @ViewBuilder
    private func compactApprovalButton(_ choice: AppServerApprovalChoice) -> some View {
        let label: String = switch choice {
        case .approve: "Approve"
        case .approveForSession: "Approve for session"
        case .deny: "Deny"
        case .cancel: "Cancel"
        }
        if choice == .approve {
            Button(label) { respondApproval(choice) }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .foregroundStyle(.black)
                .controlSize(.regular)
                .frame(minHeight: 28)
        } else {
            Button(label) { respondApproval(choice) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(minHeight: 28)
        }
    }

    @ViewBuilder
    private var shelfText: some View {
        if shelf.mode == .activity, let notificationBatch {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(notificationBatch.groups) { group in
                    Button { openThread(group.threadID) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.threadTitle)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(accent)
                                .lineLimit(1)
                            ForEach(group.messages) { message in
                                Text(message.text)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(group.threadTitle), \(group.messages.count) updates")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(shelf.verb)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(shelf.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

}

private struct ShelfCompletionIndicator: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color(red: 0.31, green: 0.86, blue: 0.47))
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

private struct OrbitingConnMark: View {
    let accent: Color
    let reduceMotion: Bool
    @State private var angle = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(accent, lineWidth: 1.6)
            ZStack {
                Circle().fill(accent).frame(width: 3.5, height: 3.5).offset(y: -3.8)
                Circle().fill(accent).frame(width: 3.5, height: 3.5).offset(y: 3.8)
            }
            .rotationEffect(.degrees(reduceMotion ? 0 : angle))
        }
        .frame(width: 14, height: 14)
        .onAppear { startIfNeeded() }
        .onChange(of: reduceMotion) { _, _ in startIfNeeded() }
    }

    private func startIfNeeded() {
        angle = 0
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: ShellGraphiteChromePolicy.connMarkOrbitDuration).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

private struct AnimatedShelfWaveform: View {
    let accent: Color
    let reduceMotion: Bool
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .center, spacing: 1.8) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(accent.opacity(index == 2 ? 1 : 0.78))
                    .frame(width: 2, height: 14)
                    .scaleEffect(
                        x: 1,
                        y: reduceMotion ? [0.43, 0.71, 1, 0.71, 0.43][index]
                            : (expanded ? [0.46, 0.9, 0.58, 1, 0.5][index]
                                : [0.95, 0.5, 1, 0.55, 0.88][index])
                    )
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.52 + Double(index) * 0.055)
                            .repeatForever(autoreverses: true),
                        value: expanded
                    )
            }
        }
        .frame(width: 18, height: 16)
        .accessibilityHidden(true)
        .onAppear { expanded = !reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in expanded = !reduced }
    }
}

private struct ShelfCountdownRing: View {
    let accent: Color
    let duration: TimeInterval
    let reduceMotion: Bool
    @State private var progress = 1.0

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: reduceMotion ? 1 : progress)
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
        .onAppear {
            progress = 1
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: max(duration, 0.1))) { progress = 0 }
        }
    }
}

private struct Palette {
    let surface: Color
    let sidebar: Color
    let card: Color
    let selected: Color
    let text: Color
    let dim: Color
    let line: Color

    static let dark = Palette(
        surface: Color(red: 0.055, green: 0.058, blue: 0.066),
        sidebar: Color(red: 0.040, green: 0.043, blue: 0.050),
        card: .white.opacity(0.055),
        selected: .white.opacity(0.085),
        text: Color(red: 0.96, green: 0.96, blue: 0.97),
        dim: Color(red: 0.63, green: 0.63, blue: 0.67),
        line: .white.opacity(0.08)
    )

    static let light = Palette(
        surface: Color(red: 0.98, green: 0.98, blue: 0.985),
        sidebar: Color(red: 0.95, green: 0.95, blue: 0.96),
        card: .black.opacity(0.045),
        selected: .black.opacity(0.075),
        text: Color(red: 0.09, green: 0.09, blue: 0.105),
        dim: Color(red: 0.34, green: 0.34, blue: 0.38),
        line: .black.opacity(0.09)
    )
}
