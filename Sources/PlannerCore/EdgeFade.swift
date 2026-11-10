import Foundation

/// When a clipped text area draws its bottom fade. The fade marks "there is more below"; text that fits, or a view
/// scrolled to its end, keeps every line at full ink.
public enum EdgeFade {
    /// True while content continues past the bottom of the visible area by more than `tolerance` points.
    /// - Parameters:
    ///   - contentHeight: height of the scrolled document (the text view's frame).
    ///   - visibleOffset: how far the visible area is scrolled from the top.
    ///   - visibleHeight: height of the visible area.
    public static func showsBottomFade(
        contentHeight: Double, visibleOffset: Double, visibleHeight: Double,
        tolerance: Double = 0.5
    ) -> Bool {
        guard visibleHeight > 0 else { return false }
        return contentHeight - (visibleOffset + visibleHeight) > tolerance
    }
}
