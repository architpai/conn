import CoreGraphics
import ConnAppCore
import ConnUI

enum V02CandidateRegressionTestCases {
    static func run(into suite: inout TestSuite) {
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
    }
}
