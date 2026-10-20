import CoreGraphics

/// Where `Bubbl.present(_:region:)` lays out the notification screen's card: centred inside the
/// screen minus these insets (in points, from the screen's edges, the safe area ignored). The
/// screen's window still covers the whole screen, so taps outside the card land on the dimmed
/// background, not on the app behind. For a foldable or a split layout, say, where the card
/// belongs on one pane.
public struct BubblPresentationRegion: Equatable, Sendable {
    public var leading: CGFloat
    public var top: CGFloat
    public var trailing: CGFloat
    public var bottom: CGFloat
    /// The card's widest, in points; the default (480) when nil.
    public var maxWidth: CGFloat?
    /// The dimmed background's opacity, 0 to 1; the default look when nil.
    public var scrimOpacity: Double?

    public init(leading: CGFloat = 0, top: CGFloat = 0, trailing: CGFloat = 0, bottom: CGFloat = 0,
                maxWidth: CGFloat? = nil, scrimOpacity: Double? = nil) {
        self.leading = leading
        self.top = top
        self.trailing = trailing
        self.bottom = bottom
        self.maxWidth = maxWidth
        self.scrimOpacity = scrimOpacity
    }
}
