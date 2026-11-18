import AppKit
import SwiftUI

// Hallmark · component: notch indicator · genre: modern-minimal · theme: native notch
// User-directed black surface, system typography, and spring geometry.
// Pre-emit critique: P5 H4 E4 S5 R5 V4. Native controls supply focus/press/disabled states.
enum Theme {
    static let surface = Color.black
    static let primary = Color(white: 0.96)
    static let secondary = Color(white: 0.65)
    static let ready = Color(red: 0.52, green: 0.87, blue: 0.64)
    static let waiting = Color(red: 1, green: 0.75, blue: 0.35)
    static let failure = Color(red: 1, green: 0.52, blue: 0.49)
    static let working = Color(red: 0.38, green: 0.72, blue: 1.0)
    static let rowHover = Color(white: 0.10)
    static let shadow = Color.black.opacity(0.22)
    static let indicatorOutline = Color.black.opacity(0.35)
    static let label = Font.system(size: 12, weight: .medium)
    static let detail = Font.system(size: 11)
    static let count = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let spring = Animation.spring(duration: 0.24, bounce: 0.10)
    static let collapse = Animation.easeOut(duration: 0.12)
    static let reducedMotion = Animation.easeOut(duration: 0.08)
    static let maxWidth: CGFloat = 520
    static let maxHeight: CGFloat = 400
    static let detailsWidth: CGFloat = 336
    static let dropdownGap: CGFloat = 0
    static let indicatorOffset: CGFloat = 16
    static let hoverMargin: CGFloat = 24
}

struct NotchGeometry: Equatable {
    var width: CGFloat = 180
    var height: CGFloat = 32
    var physical = true

    @MainActor
    static func read(from screen: NSScreen) -> Self {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            return Self(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        }
        // Menu-bar fallback geometry on displays without a camera cutout.
        let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return Self(width: 148, height: min(menuBarHeight, 36), physical: false)
    }
}
