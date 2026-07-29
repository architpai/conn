import CoreGraphics
import ConnAppCore

package struct ConnCompactHeaderPresentation: Equatable, Sendable {
    package let showsProductName: Bool
    package let showsIntegrationStatus: Bool
    package let minimumCenterGap: CGFloat
}

package enum ConnCompactHeaderLayoutPolicy {
    package static let physicalNotchPanelWidth: CGFloat = 404
    package static let externalPanelWidth: CGFloat = 350
    package static let physicalNotchMinimumCenterGap: CGFloat = 184
    package static let panelHorizontalInset: CGFloat = 12

    package static func presentation(
        surface: ShellSurfaceState,
        placement: ShellPanelPlacement
    ) -> ConnCompactHeaderPresentation {
        if surface == .compact, placement == .physicalNotch {
            return .init(
                showsProductName: true,
                showsIntegrationStatus: false,
                minimumCenterGap: physicalNotchMinimumCenterGap
            )
        }
        return .init(
            showsProductName: true,
            showsIntegrationStatus: true,
            minimumCenterGap: 8
        )
    }

    package static func compactPanelWidth(
        placement: ShellPanelPlacement
    ) -> CGFloat {
        placement == .physicalNotch
            ? physicalNotchPanelWidth
            : externalPanelWidth
    }

    package static func compactContentWidth(
        placement: ShellPanelPlacement
    ) -> CGFloat {
        compactPanelWidth(placement: placement) - panelHorizontalInset
    }
}

package enum ConnCompactNotificationIndicator: Equatable, Sendable {
    case animatedWaveform
    case completion
}

package enum ConnCompactNotificationLayoutPolicy {
    package static let usesStackedMessageHierarchy = true
    package static let messageLineLimit: Int? = 2
    package static let headerHeight: CGFloat = 40

    package static func contentWidth(
        placement: ShellPanelPlacement
    ) -> CGFloat {
        ConnCompactHeaderLayoutPolicy.compactContentWidth(
            placement: placement
        )
    }

    package static func indicator(
        isFinal: Bool
    ) -> ConnCompactNotificationIndicator {
        isFinal ? .completion : .animatedWaveform
    }

    package static func rowHeight(
        messageTexts: [String],
        placement: ShellPanelPlacement
    ) -> CGFloat {
        let availableTextWidth = max(
            120,
            contentWidth(placement: placement) - 79
        )
        let approximateCharactersPerLine = max(
            20,
            Int((availableTextWidth / 5.4).rounded(.down))
        )
        let contentHeight = messageTexts.reduce(CGFloat.zero) {
            partialHeight,
            text in
            let measuredVisualLines = text.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).reduce(0) { count, paragraph in
                count + max(
                    1,
                    Int(ceil(
                        Double(paragraph.count)
                            / Double(approximateCharactersPerLine)
                    ))
                )
            }
            let visualLines = min(
                measuredVisualLines,
                messageLineLimit ?? measuredVisualLines
            )
            return partialHeight + 12 + 3 + CGFloat(visualLines) * 13
        }
        let interMessageSpacing = CGFloat(max(0, messageTexts.count - 1)) * 8
        return max(52, contentHeight + interMessageSpacing + 14)
    }
}
