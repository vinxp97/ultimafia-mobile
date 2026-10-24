#if os(iOS)
import SwiftUI
import UIKit

/// Horizontal swipe on the chat transcript to page between phases. A UIKit pan recognizer is
/// attached to the transcript's own UIScrollView (found from a transparent background view, like
/// `UMTranscriptScrollBridge`), so it can refuse to begin unless the drag is clearly sideways:
/// vertical scrolling, long presses and taps on rows never reach it. Once it does begin it cancels
/// the scroll view's in-flight pan, so a sideways page never also nudges the chat up or down.
struct UMPhaseSwipeBridge: UIViewRepresentable {
    var enabled: Bool
    var onChange: (CGFloat) -> Void
    var onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIView(context: Context) -> SwipeView {
        let v = SwipeView()
        update(v)
        return v
    }
    func updateUIView(_ v: SwipeView, context: Context) { update(v) }
    private func update(_ v: SwipeView) {
        v.enabled = enabled
        v.onChange = onChange
        v.onEnd = onEnd
    }

    final class SwipeView: UIView, UIGestureRecognizerDelegate {
        var enabled = true
        var onChange: ((CGFloat) -> Void)?
        var onEnd: ((CGFloat, CGFloat) -> Void)?
        private weak var scroll: UIScrollView?
        private lazy var pan: UIPanGestureRecognizer = {
            let p = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            p.delegate = self
            p.maximumNumberOfTouches = 1
            // iPad trackpad / Magic Keyboard: a two-finger sideways scroll pages too.
            p.allowedScrollTypesMask = .continuous
            p.cancelsTouchesInView = true
            return p
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                scroll?.removeGestureRecognizer(pan)
                scroll = nil
                return
            }
            var node = superview
            while let view = node, !(view is UIScrollView) { node = view.superview }
            guard let found = node as? UIScrollView, found !== scroll else { return }
            scroll?.removeGestureRecognizer(pan)
            found.addGestureRecognizer(pan)
            scroll = found
        }

        /// Sideways only: at least 1.6x more horizontal than vertical movement once the pan's own
        /// slop has passed, and not from the screen's leading edge (left to the system / any
        /// navigation back swipe).
        override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === pan else { return super.gestureRecognizerShouldBegin(g) }
            guard enabled, let scroll, let window else { return false }
            let t = pan.translation(in: scroll)
            let v = pan.velocity(in: scroll)
            let start = pan.location(in: window).x - t.x
            if start < 20 { return false }
            let dx = abs(t.x) > 1 ? abs(t.x) : abs(v.x)
            let dy = abs(t.x) > 1 ? abs(t.y) : abs(v.y)
            return dx > dy * 1.6
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Live with the scroll view's pan until this one begins (then it is cancelled below).
            other === scroll?.panGestureRecognizer
        }

        @objc private func handle(_ p: UIPanGestureRecognizer) {
            guard let scroll else { return }
            switch p.state {
            case .began:
                // Cancel the vertical pan that started with the same touch, so a sideways swipe
                // never also drags the chat.
                scroll.panGestureRecognizer.isEnabled = false
                scroll.panGestureRecognizer.isEnabled = true
            case .changed:
                onChange?(p.translation(in: scroll).x)
            case .ended:
                onEnd?(p.translation(in: scroll).x, p.velocity(in: scroll).x)
            case .cancelled, .failed:
                onEnd?(0, 0)
            default:
                break
            }
        }
    }
}
#endif
