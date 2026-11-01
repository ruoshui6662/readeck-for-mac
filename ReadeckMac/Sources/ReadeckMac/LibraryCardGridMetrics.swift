import Foundation

/// Card dimensions belong to the content, not the number of columns. Extra
/// viewport space becomes balanced outer margins rather than oversized covers.
struct LibraryCardGridMetrics {
    static let preferredCardWidth: CGFloat = 252
    static let columnSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 22
    let columns: Int
    let cardWidth: CGFloat
    let horizontalInset: CGFloat
    var gridWidth: CGFloat { CGFloat(columns) * cardWidth + CGFloat(columns - 1) * Self.columnSpacing }

    init(viewportWidth: CGFloat) {
        let viewport = viewportWidth.isFinite ? min(max(1, viewportWidth), 32_768) : 1
        horizontalInset = min(24, max(0, (viewport - 1) / 2))
        let available = max(1, viewport - 2 * horizontalInset)
        cardWidth = min(Self.preferredCardWidth, available)
        columns = max(1, Int((available + Self.columnSpacing) / (Self.preferredCardWidth + Self.columnSpacing)))
    }
}
