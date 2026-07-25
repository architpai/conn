import CoreGraphics
import ConnAppCore
import ConnUI

enum V02CandidateRegressionTestCases {
    @MainActor
    static func run(into suite: inout TestSuite) async {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let builtIn = ConnPanelFramePolicy.decide(
            displayFrame: displayFrame,
            visibleFrame: visibleFrame,
            safeAreaTop: 32,
            isBuiltIn: true,
            expanded: true,
            compactShelfPreferredHeight: 34
        )
        suite.checkEqual(
            builtIn.placement,
            .physicalNotch,
            "a built-in display with a camera safe area is notch-anchored"
        )
        suite.checkEqual(
            builtIn.frame.maxY,
            displayFrame.maxY,
            "expanded Conn stays flush with the physical notch edge"
        )

        let external = ConnPanelFramePolicy.decide(
            displayFrame: displayFrame,
            visibleFrame: visibleFrame,
            safeAreaTop: 32,
            isBuiltIn: false,
            expanded: false,
            compactShelfPreferredHeight: 34
        )
        suite.checkEqual(
            external.placement,
            .externalCapsule,
            "an external display cannot borrow built-in notch geometry"
        )
        suite.checkEqual(
            external.frame.maxY,
            visibleFrame.maxY - 8,
            "external capsule retains its menu-bar clearance"
        )

        let compactNotification = ConnPanelFramePolicy.decide(
            displayFrame: displayFrame,
            visibleFrame: visibleFrame,
            safeAreaTop: 32,
            isBuiltIn: true,
            expanded: false,
            compactShelfPreferredHeight: 92
        )
        suite.checkEqual(
            compactNotification.frame.height,
            92,
            "the integrated notification shelf needs no inter-surface height allowance"
        )
        suite.checkEqual(
            compactNotification.frame.width,
            404,
            "the physical-notch compact surface preserves safe side wings"
        )
        let notchHeader = ConnCompactHeaderLayoutPolicy.presentation(
            surface: .compact,
            placement: .physicalNotch
        )
        suite.check(
            notchHeader.showsProductName,
            "the Conn wordmark remains visible in the physical-notch left wing"
        )
        suite.check(
            !notchHeader.showsIntegrationStatus,
            "compact integration status does not render behind the physical notch"
        )
        suite.checkEqual(
            notchHeader.minimumCenterGap,
            184,
            "the compact header reserves the measured physical-notch center"
        )
        let externalHeader = ConnCompactHeaderLayoutPolicy.presentation(
            surface: .compact,
            placement: .externalCapsule
        )
        suite.check(
            externalHeader.showsIntegrationStatus,
            "external capsules retain compact Integration status wording"
        )
        suite.checkEqual(
            external.frame.width,
            350,
            "external capsules retain their compact width"
        )
        suite.checkEqual(
            ConnTranscriptAlignmentPolicy.lane(for: .userMessage),
            .trailing,
            "User messages occupy the trailing conversation lane"
        )
        suite.checkEqual(
            ConnTranscriptAlignmentPolicy.lane(for: .agentMessage),
            .leading,
            "Agent messages occupy the leading conversation lane"
        )
        suite.checkEqual(
            ConnTranscriptAlignmentPolicy.lane(for: .reasoning),
            .leading,
            "Agent reasoning remains grouped in the leading lane"
        )

        var sleepCount = 0
        var expiredIDs: [String] = []
        let lifetime = ConnCompactNotificationLifetimeController { _ in
            sleepCount += 1
        }
        suite.check(
            lifetime.present(id: "notification-1", duration: 5) {
                expiredIDs.append($0)
            },
            "a new notification starts its lifetime"
        )
        suite.check(
            !lifetime.present(id: "notification-1", duration: 5) {
                expiredIDs.append($0)
            },
            "re-publishing the same notification does not reset its lifetime"
        )
        await Task.yield()
        await Task.yield()
        suite.checkEqual(sleepCount, 1, "one notification owns one expiry sleep")
        suite.checkEqual(
            expiredIDs,
            ["notification-1"],
            "a notification disappears when its lifetime elapses"
        )

        expiredIDs.removeAll()
        _ = lifetime.present(id: "notification-2", duration: 5) {
            expiredIDs.append($0)
        }
        lifetime.dismiss()
        await Task.yield()
        await Task.yield()
        suite.check(
            expiredIDs.isEmpty,
            "manual dismissal cancels the pending expiry callback"
        )
    }
}
