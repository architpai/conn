import Foundation
import ConnCodexAdapter

enum Phase6ProviderUIPolicyParityTestCases {
    static func run(into suite: inout TestSuite) {
        suite.checkEqual(SharedDesktopLabsLayoutPolicy.viewportHeight(availableHeight: 900), 560, "Labs uses its preferred height")
        suite.checkEqual(SharedDesktopLabsLayoutPolicy.viewportHeight(availableHeight: 576), 504, "Labs leaves screen clearance")
        suite.checkEqual(SharedDesktopLabsLayoutPolicy.viewportHeight(availableHeight: 400), 360, "Labs retains a usable minimum viewport")

        let options = [
            AppServerNewThreadModelOption(id: "default-id", model: "gpt-default", displayName: "Default", detail: "", isDefault: true),
            AppServerNewThreadModelOption(id: "remembered-id", model: "gpt-remembered", displayName: "Remembered", detail: "", isDefault: false),
        ]
        suite.checkEqual(
            AppServerThreadModelLabelPolicy.label(
                selection: .init(model: "gpt-default", reasoningEffort: "high"),
                options: options
            ),
            "Default · High reasoning",
            "Codex model labels retain reasoning effort"
        )
        suite.checkEqual(
            AppServerThreadModelLabelPolicy.label(selection: nil, options: options),
            "Loading model…",
            "missing Codex metadata does not borrow a prior choice"
        )
        suite.checkEqual(
            AppServerMonitoringRuntime.threadModelSelection(from: .object([
                "model": .string("gpt-default"),
                "reasoningEffort": .string("xhigh"),
                "thread": .object(["id": .string("running-thread")]),
            ])),
            .init(model: "gpt-default", reasoningEffort: "xhigh"),
            "resume metadata supplies Codex model authority"
        )
        suite.checkEqual(
            AppServerMonitoringRuntime.threadModelSelection(from: .object([
                "model": .string("gpt-default\nspoofed"),
                "reasoningEffort": .string("high"),
            ])),
            nil,
            "unsafe Codex model labels are rejected"
        )

        let threadID = AppServerThreadID(rawValue: "idle-thread")
        suite.check(
            AppServerThreadModelQualificationPolicy.shouldRequestForExpandedPresentation(
                selectedThreadID: threadID,
                knownSelections: [:]
            ),
            "expanded idle Codex threads request missing model authority"
        )
        suite.check(
            !AppServerThreadModelQualificationPolicy.shouldRequestForExpandedPresentation(
                selectedThreadID: threadID,
                knownSelections: [
                    threadID: .init(model: "gpt-default", reasoningEffort: "high"),
                ]
            ),
            "known Codex model authority is not requested again"
        )
        suite.check(
            !AppServerThreadModelQualificationPolicy.shouldRequestForExpandedPresentation(
                selectedThreadID: nil,
                knownSelections: [:]
            ),
            "missing Codex selection sends no qualification request"
        )

        let remembered = AppServerNewThreadModelSelectionPolicy.resolve(
            options: options,
            currentSelectionID: nil,
            preferredSelectionID: "remembered-id"
        )
        suite.checkEqual(remembered.selectedID, "remembered-id", "Codex restores an available remembered model")
        suite.check(!remembered.preferredModelIsUnavailable, "available remembered model needs no warning")
        let fallback = AppServerNewThreadModelSelectionPolicy.resolve(
            options: options,
            currentSelectionID: nil,
            preferredSelectionID: "retired-id"
        )
        suite.checkEqual(fallback.selectedID, "default-id", "unavailable Codex models use the server default")
        suite.check(fallback.preferredModelIsUnavailable, "Codex model fallback remains visible")
        suite.checkEqual(
            AppServerNewThreadModelSelectionPolicy.resolve(
                options: options,
                currentSelectionID: "default-id",
                preferredSelectionID: "remembered-id"
            ).selectedID,
            "default-id",
            "visible Codex model selection is not overwritten"
        )

        suite.checkEqual(AppServerNewChatWorkspacePolicy.resolveDefaultWorkspace("  /tmp/../tmp  "), "/tmp", "Codex standardizes an absolute Workspace")
        suite.checkEqual(AppServerNewChatWorkspacePolicy.resolveDefaultWorkspace("relative/project"), "relative/project", "relative Workspace remains invalid for submit validation")
        suite.checkEqual(AppServerNewChatWorkspacePolicy.resolveDefaultWorkspace("   "), "", "empty Workspace never becomes the process directory")
    }
}
