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
