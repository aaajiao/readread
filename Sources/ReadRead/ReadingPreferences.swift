import CoreGraphics
import Foundation

/// The reading view's settings (`font_size`, `auto_follow`) and the panel's size (`panel_width`,
/// `panel_height`) in the same store as the voices.
@MainActor
struct ReadingPreferences {
    nonisolated static let fontSizeKey = "font_size"
    nonisolated static let autoFollowKey = "auto_follow"
    nonisolated static let panelWidthKey = "panel_width"
    nonisolated static let panelHeightKey = "panel_height"

    /// Body text size in points; headings and the title are a little larger.
    nonisolated static let defaultFontSize = 13.0
    nonisolated static let fontSizeRange: ClosedRange<Double> = 11...28
    nonisolated static let fontSizeStep = 1.0

    /// The panel's size: the v0.3.0 size by default, resizable within these bounds.
    nonisolated static let defaultPanelSize = CGSize(width: 380, height: 560)
    nonisolated static let minimumPanelSize = CGSize(width: 340, height: 420)
    nonisolated static let maximumPanelSize = CGSize(width: 900, height: 1200)

    let defaults: any PreferencesStore

    var fontSize: Double {
        get {
            guard let value = (defaults.object(forKey: Self.fontSizeKey) as? NSNumber)?.doubleValue,
                  value.isFinite else { return Self.defaultFontSize }
            return Self.clampedFontSize(value)
        }
        nonmutating set { defaults.set(Self.clampedFontSize(newValue), forKey: Self.fontSizeKey) }
    }

    /// The view follows the sentence being read (default on).
    var autoFollow: Bool {
        get { (defaults.object(forKey: Self.autoFollowKey) as? NSNumber)?.boolValue ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.autoFollowKey) }
    }

    /// The size the panel had when last resized, kept within the bounds.
    var panelSize: CGSize {
        get {
            guard let width = (defaults.object(forKey: Self.panelWidthKey) as? NSNumber)?.doubleValue,
                  let height = (defaults.object(forKey: Self.panelHeightKey) as? NSNumber)?.doubleValue else {
                return Self.defaultPanelSize
            }
            return Self.clampedPanelSize(CGSize(width: width, height: height))
        }
        nonmutating set {
            let size = Self.clampedPanelSize(newValue)
            defaults.set(Double(size.width.rounded()), forKey: Self.panelWidthKey)
            defaults.set(Double(size.height.rounded()), forKey: Self.panelHeightKey)
        }
    }

    nonisolated static func clampedFontSize(_ size: Double) -> Double {
        guard size.isFinite else { return defaultFontSize }
        return min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, size.rounded()))
    }

    nonisolated static func clampedPanelSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite else { return defaultPanelSize }
        return CGSize(width: min(maximumPanelSize.width, max(minimumPanelSize.width, size.width)),
                      height: min(maximumPanelSize.height, max(minimumPanelSize.height, size.height)))
    }
}

/// Where the panel goes: under the status item, centred on it, inside the screen's visible frame,
/// at most as large as that frame allows.
enum PanelPlacement {
    static let margin: CGFloat = 8
    static let gapBelowMenuBar: CGFloat = 4

    static func frame(size: CGSize, under button: CGRect, in visible: CGRect) -> CGRect {
        let width = min(size.width, max(ReadingPreferences.minimumPanelSize.width, visible.width - 2 * margin))
        let height = min(size.height, max(ReadingPreferences.minimumPanelSize.height,
                                          button.minY - gapBelowMenuBar - visible.minY - margin))
        var x = button.midX - width / 2
        x = max(visible.minX + margin, min(x, visible.maxX - width - margin))
        let y = button.minY - gapBelowMenuBar - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
