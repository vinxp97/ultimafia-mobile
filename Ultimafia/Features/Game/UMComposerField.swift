import Foundation

/// Pure sizing rules for the chat composer; kept outside UIKit so the clamp behavior is testable.
enum UMComposerSizing {
    static func maximumHeight(lineHeight: CGFloat, maxLines: Int) -> CGFloat {
        ceil(lineHeight * CGFloat(max(1, maxLines)))
    }

    static func height(contentHeight: CGFloat, lineHeight: CGFloat, maxLines: Int) -> CGFloat {
        let minimum = ceil(lineHeight)
        let maximum = maximumHeight(lineHeight: lineHeight, maxLines: maxLines)
        return min(max(ceil(contentHeight), minimum), maximum)
    }

    static func shouldScroll(contentHeight: CGFloat, lineHeight: CGFloat, maxLines: Int) -> Bool {
        contentHeight > maximumHeight(lineHeight: lineHeight, maxLines: maxLines) + 0.5
    }
}

#if canImport(UIKit)
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Chat input backed by UITextView so Return never ends editing: the delegate catches "\n",
/// calls `onReturn` (send) and returns false, so the view never resigns first responder and
/// the keyboard stays up. Grows to eight lines, then scrolls. Tab (hardware) calls `onTab`.
struct UMComposerField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var enabled: Bool
    var textColor: UIColor
    var maxLength: Int
    var onReturn: () -> Void
    var onTab: () -> Bool = { false }
    /// Option+arrow game shortcuts; they take priority over text navigation while typing.
    var onShortcut: (UMGameShortcut) -> Void = { _ in }

    static let font = UIFont.preferredFont(forTextStyle: .body)
    static let maxLines = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UMComposerTextView()
        tv.onShortcut = { [weak coordinator = context.coordinator] s in coordinator?.parent.onShortcut(s) }
        tv.delegate = context.coordinator
        tv.font = Self.font
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.returnKeyType = .send
        tv.enablesReturnKeyAutomatically = false
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let label = UILabel()
        label.font = Self.font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .placeholderText
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: tv.leadingAnchor),
            label.topAnchor.constraint(equalTo: tv.topAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: tv.widthAnchor),
        ])
        context.coordinator.placeholderLabel = label
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text {
            tv.text = text
            // Chips/autofill replace the text: keep the cursor at the end.
            let end = tv.endOfDocument
            tv.selectedTextRange = tv.textRange(from: end, to: end)
        }
        tv.textColor = textColor
        tv.isEditable = enabled
        context.coordinator.placeholderLabel?.text = placeholder
        context.coordinator.placeholderLabel?.textColor = enabled ? .placeholderText : textColor
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        context.coordinator.applyAccessory(context.environment.umComposerKeyboardAccessory, to: tv)
        if isFocused, !tv.isFirstResponder, enabled, tv.window != nil {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        } else if !isFocused, tv.isFirstResponder {
            tv.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? tv.bounds.width
        guard width > 0 else { return nil }

        let font = tv.font ?? Self.font
        let inset = tv.textContainerInset
        let text = tv.text ?? ""
        let textWidth = max(1, width - inset.left - inset.right)
        // Both cases measure the same way, so an empty draft is exactly as tall as a one-line draft.
        // Sizing the empty case from the font's line height instead left the pill a pixel or two
        // shorter, and it grew the moment the first letter was typed. "Ag" is measured only for its
        // one-line height, which covers an ascender and a descender.
        let sample = text.isEmpty ? "Ag" : text
        let measured = (sample as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let contentHeight = ceil(measured.height) + inset.top + inset.bottom

        let height = UMComposerSizing.height(
            contentHeight: contentHeight,
            lineHeight: font.lineHeight,
            maxLines: Self.maxLines
        )
        let scroll = UMComposerSizing.shouldScroll(
            contentHeight: contentHeight,
            lineHeight: font.lineHeight,
            maxLines: Self.maxLines
        )
        if tv.isScrollEnabled != scroll {
            DispatchQueue.main.async { tv.isScrollEnabled = scroll }
        }
        return CGSize(width: width, height: height)
    }

    /// Text view that claims Option+arrows before UIKit's word/paragraph navigation. No
    /// discoverability titles here: the game screen's SwiftUI shortcuts list them in the
    /// Cmd-hold overlay, so they aren't shown twice.
    final class UMComposerTextView: UITextView {
        var onShortcut: ((UMGameShortcut) -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            let pairs: [(String, Selector)] = [
                (UIKeyCommand.inputLeftArrow, #selector(prevPhase)),
                (UIKeyCommand.inputRightArrow, #selector(nextPhase)),
                (UIKeyCommand.inputUpArrow, #selector(chatTop)),
                (UIKeyCommand.inputDownArrow, #selector(chatBottom)),
            ]
            let mine = pairs.map { input, action -> UIKeyCommand in
                let c = UIKeyCommand(input: input, modifierFlags: .alternate, action: action)
                c.wantsPriorityOverSystemBehavior = true
                c.attributes = .hidden
                return c
            }
            return mine + (super.keyCommands ?? [])
        }

        @objc private func prevPhase() { onShortcut?(.previousPhase) }
        @objc private func nextPhase() { onShortcut?(.nextPhase) }
        @objc private func chatTop() { onShortcut?(.chatTop) }
        @objc private func chatBottom() { onShortcut?(.chatBottom) }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: UMComposerField
        weak var placeholderLabel: UILabel?
        private var accessoryHost: UIHostingController<AnyView>?

        /// Attach, update or remove the keyboard accessory; the keyboard redraws only on a change.
        func applyAccessory(_ content: AnyView?, to tv: UITextView) {
            if let content {
                if let host = accessoryHost {
                    host.rootView = content
                    return
                }
                let host = UIHostingController(rootView: content)
                host.view.backgroundColor = .clear
                host.sizingOptions = [.intrinsicContentSize]
                host.view.autoresizingMask = [.flexibleWidth]
                let h = host.view.systemLayoutSizeFitting(CGSize(width: tv.window?.bounds.width ?? 400, height: 0)).height
                host.view.frame = CGRect(x: 0, y: 0, width: tv.window?.bounds.width ?? 400, height: max(36, h))
                accessoryHost = host
                tv.inputAccessoryView = host.view
                if tv.isFirstResponder { tv.reloadInputViews() }
                UMDiag.log("fold", "keyboard accessory attached h \(host.view.frame.height)")
            } else if accessoryHost != nil {
                accessoryHost = nil
                tv.inputAccessoryView = nil
                if tv.isFirstResponder { tv.reloadInputViews() }
                UMDiag.log("fold", "keyboard accessory removed")
            }
        }
        init(_ parent: UMComposerField) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                parent.onReturn()
                return false
            }
            if text == "\t" {
                // Hardware Tab only ever completes; never insert a literal tab, even when nothing matched.
                _ = parent.onTab()
                return false
            }
            if text.contains(where: \.isNewline) {
                // Pasted multi-line text: flatten to one line (chat messages are single-line).
                let flat = text.replacingOccurrences(of: "\r\n", with: " ")
                    .components(separatedBy: .newlines).joined(separator: " ")
                if let r = Range(range, in: textView.text ?? "") {
                    let next = (textView.text ?? "").replacingCharacters(in: r, with: flat)
                    parent.text = String(next.prefix(parent.maxLength))
                }
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            let capped = String((textView.text ?? "").prefix(parent.maxLength))
            if capped != textView.text { textView.text = capped }
            if parent.text != capped { parent.text = capped }
            placeholderLabel?.isHidden = !capped.isEmpty
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}
#elseif os(macOS)
import SwiftUI
import AppKit

/// Native Mac chat input: Return sends (Option-Return is ignored; chat lines are single-line), Tab
/// completes, Option+arrows drive the game shortcuts. Grows to eight lines, then scrolls.
struct UMComposerField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var enabled: Bool
    var textColor: NSColor
    var maxLength: Int
    var onReturn: () -> Void
    var onTab: () -> Bool = { false }
    var onShortcut: (UMGameShortcut) -> Void = { _ in }

    static let font = NSFont.preferredFont(forTextStyle: .body)
    static let maxLines = 8

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { text },
            set: { text = String($0.replacingOccurrences(of: "\n", with: " ").prefix(maxLength)) }
        ), axis: .vertical)
        .textFieldStyle(.plain)
        .font(.body)
        .lineLimit(1...Self.maxLines)
        .foregroundStyle(Color(nsColor: textColor))
        .disabled(!enabled)
        .focused($focused)
        .onKeyPress(.return, phases: .down) { _ in
            onReturn()
            return .handled
        }
        .onKeyPress(.tab, phases: .down) { _ in
            _ = onTab()
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            switch press.key {
            case .leftArrow: onShortcut(.previousPhase)
            case .rightArrow: onShortcut(.nextPhase)
            case .upArrow: onShortcut(.chatTop)
            default: onShortcut(.chatBottom)
            }
            return .handled
        }
        .onChange(of: isFocused) { _, v in if focused != v { focused = v } }
        .onChange(of: focused) { _, v in if isFocused != v { isFocused = v } }
        .onAppear { if isFocused { focused = true } }
    }
}
#endif
