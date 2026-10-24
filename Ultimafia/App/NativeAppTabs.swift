import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// UIKit owns the Liquid Glass tab bar, its selection interaction, and each section's content
/// safe area. Every item is a section you can be in, so no item selects an empty page and the
/// bar never changes order, labels or size with state.
struct NativeAppTabs: UIViewControllerRepresentable {
    var selected: UMAppSection
    var mentionBadge: Int
    var showsBar: Bool
    /// Messages is hidden entirely while in a game (seated or spectating).
    var showsMessages: Bool = true
    var messagesBadge: Int = 0
    var play: AnyView
    var messages: AnyView = AnyView(EmptyView())
    var game: AnyView
    var you: AnyView
    var onSelect: (UMAppSection) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.apply(self)
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.apply(self)
    }

    final class Controller: UITabBarController, UITabBarControllerDelegate {
        private var pages: [UMAppSection: Page] = [:]
        private var onSelect: ((UMAppSection) -> Void)?

        override func viewDidLoad() {
            super.viewDidLoad()
            delegate = self
            view.backgroundColor = .clear
            let sections = UMAppSection.allCases
            pages = Dictionary(uniqueKeysWithValues: sections.map { section in
                let page = Page()
                page.tabBarItem = UITabBarItem(title: section.title,
                                               image: UIImage(systemName: section.symbol),
                                               tag: 0)
                return (section, page)
            })
            setViewControllers(sections.compactMap { pages[$0] }, animated: false)
        }

        private var messagesShown = true

        func apply(_ config: NativeAppTabs) {
            loadViewIfNeeded()
            onSelect = config.onSelect
            pages[.play]?.rootView = config.play
            pages[.messages]?.rootView = config.messages
            pages[.messages]?.tabBarItem.badgeValue = config.messagesBadge > 0 ? String(config.messagesBadge) : nil
            if messagesShown != config.showsMessages {
                messagesShown = config.showsMessages
                let visible = UMAppSection.allCases.filter { $0 != .messages || config.showsMessages }
                setViewControllers(visible.compactMap { pages[$0] }, animated: false)
            }
            pages[.game]?.rootView = config.game
            pages[.you]?.rootView = config.you
            pages[.game]?.tabBarItem.badgeValue = config.mentionBadge > 0 ? String(config.mentionBadge) : nil
            if let page = pages[config.selected], selectedViewController !== page {
                selectedViewController = page
            }
            if isTabBarHidden == config.showsBar {
                setTabBarHidden(!config.showsBar, animated: view.window != nil)
            }
        }

        /// Selection is always allowed. Re-selecting the visible section pops it to its root,
        /// which the model handles.
        func tabBarController(_ tabBarController: UITabBarController,
                              shouldSelect viewController: UIViewController) -> Bool {
            guard let match = pages.first(where: { $0.value === viewController }) else { return false }
            onSelect?(match.key)
            return true
        }
    }

    /// One plain page per section, each with its own hosting controller, so a section keeps its
    /// navigation state while another section is showing.
    final class Page: UIViewController {
        private let host = UIHostingController(rootView: AnyView(EmptyView()))

        var rootView: AnyView {
            get { host.rootView }
            set { host.rootView = newValue }
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            host.view.backgroundColor = .clear
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            host.didMove(toParent: self)
        }

        override var childForStatusBarStyle: UIViewController? { host }
        /// The tab controller asks the selected Page; without this the Page answered itself (never
        /// hidden) and the section's own `.statusBarHidden` (the game screen) was never consulted.
        override var childForStatusBarHidden: UIViewController? { host }
    }
}
#endif
