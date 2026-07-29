import CoreGraphics

public enum SharedDesktopLabsLayoutPolicy {
    public static let preferredViewportHeight: CGFloat = 560
    public static let minimumViewportHeight: CGFloat = 360
    public static let screenClearance: CGFloat = 72

    public static func viewportHeight(availableHeight: CGFloat) -> CGFloat {
        min(
            preferredViewportHeight,
            max(minimumViewportHeight, availableHeight - screenClearance)
        )
    }
}
