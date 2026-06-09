import Foundation
import CoreGraphics

struct ChatLayoutState: Equatable {
    var isRightSidebarVisible = false
    var rightSidebarWidth: CGFloat = 360

    mutating func toggleRightSidebar() {
        isRightSidebarVisible.toggle()
    }

    mutating func setRightSidebarWidth(_ width: CGFloat, maxWidth: CGFloat) {
        rightSidebarWidth = min(max(width, 220), max(220, maxWidth))
    }
}

struct ToolMessageContentDisclosureState: Equatable {
    var isExpanded = false

    var lineLimit: Int? {
        isExpanded ? nil : 1
    }

    var indicatorText: String {
        isExpanded ? "▾" : "▸"
    }

    mutating func toggle() {
        isExpanded.toggle()
    }
}
