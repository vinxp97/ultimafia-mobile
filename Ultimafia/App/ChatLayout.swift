import SwiftUI

enum ChatLayout: String, CaseIterable, Identifiable {
    case standard
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .compact: return "Compact (vertically aligned)"
        }
    }
}

enum BubbleIndicatorStyle: String, CaseIterable, Identifiable {
    case bar
    case hidden
    case overlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bar: return "Default (bar above composer)"
        case .hidden: return "Hidden"
        case .overlay: return "Overlay at top of chat"
        }
    }
}
