import SwiftUI

enum SidebarDestination {
    case chat
    case sessions
    case tools
    case skills
}

enum FileImportTarget {
    case main
    case agent(UUID)
}
