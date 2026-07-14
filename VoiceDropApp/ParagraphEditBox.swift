import SwiftUI
import UIKit

// 键盘精修（设计稿 design_handoff_paragraph_edit，方向 1a 定稿）：长按段落 → 菜单里的
// 「编辑」→ 只有这一段变成带描边的可编辑框，光标落在长按命中的字符位置，系统键盘弹出，
// 改完点顶栏「完成」写回该段（RecordingDetailView.commitEdit），其余段落原地淡出。
// 这里只画「这一个编辑框」本身；进入/退出编辑态、顶栏 取消/完成、其余段落淡出都在
// RecordingDetailView 里（与长按菜单、highlightLines 复用同一套状态）。

/// 就地编辑框：白底 + 赭红描边，包住一个真正的 `UITextView`（键盘 + 精确光标落点 +
/// 键盘上方工具条都要靠 UIKit，SwiftUI 的 TextEditor 做不到 tap-to-caret 与
/// inputAccessoryView）。
struct ParagraphEditBox: View {
    @Binding var text: String
    /// 长按命中的位置——RecordingDetailView 是在原来那个只读 `Text`（零内边距）的
    /// local 坐标系里采的点。这个框的内层 `UITextView` 顶部比那个原点低 9pt（下面
    /// `topInset` 那圈 padding），水平方向的 -10 出血 + +10 内边距正好抵消、无偏移，
    /// 所以只需要把 Y 减掉 9 就能落到同一个字符上。nil = 找不到有效落点时退到段尾。
    let initialTapPoint: CGPoint?
    let onDone: () -> Void
    let onCancel: () -> Void

    private let topInset: CGFloat = 9

    var body: some View {
        ParagraphEditTextView(
            text: $text,
            initialTapPoint: initialTapPoint.map { CGPoint(x: $0.x, y: $0.y - topInset) },
            onCommit: onDone
        )
            .padding(EdgeInsets(top: topInset, leading: 10, bottom: topInset, trailing: 10))
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: 1.5))
            .padding(.horizontal, -10)
            .accessibilityAction(.escape, onCancel)
    }
}

/// `UITextView` wrapper: 16pt 正文字号、行距对齐正文段落（`lineSpacing 9`，与
/// `articleBody` 里其余段落的 `Text.lineSpacing(9)` 一致），零内边距（视觉内边距完全交给
/// 外层 `ParagraphEditBox` 的 `.padding`，这样长按落点的坐标换算不用换算两套内边距）。
private struct ParagraphEditTextView: UIViewRepresentable {
    @Binding var text: String
    let initialTapPoint: CGPoint?
    let onCommit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: 16)
        tv.textColor = UIColor(Theme.bodyRead)
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.showsVerticalScrollIndicator = false
        tv.autocorrectionType = .default
        tv.autocapitalizationType = .none
        tv.attributedText = Self.attributed(text)
        tv.inputAccessoryView = context.coordinator.makeAccessoryView(target: tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // 只在首次挂载时设焦点 + 落光标；之后 text 每敲一个字都会走一遍 updateUIView，
        // 这里绝不能重设 selectedTextRange，否则会把用户刚打的光标位置弹回长按点。
        guard !context.coordinator.didSetInitialCaret else { return }
        context.coordinator.didSetInitialCaret = true
        tv.attributedText = Self.attributed(text)
        DispatchQueue.main.async {
            tv.becomeFirstResponder()
            let point = initialTapPoint ?? CGPoint(x: tv.bounds.maxX, y: tv.bounds.maxY)
            if let position = tv.closestPosition(to: point) {
                tv.selectedTextRange = tv.textRange(from: position, to: position)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onCommit: onCommit) }

    fileprivate static func attributed(_ s: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 9
        return NSAttributedString(string: s, attributes: [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor(Theme.bodyRead),
            .paragraphStyle: style,
        ])
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let textBinding: Binding<String>
        let onCommit: () -> Void
        var didSetInitialCaret = false

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            self.textBinding = text
            self.onCommit = onCommit
        }

        /// 段落边界锁定：回车＝完成（不新建段落，不塞换行进正文，见 README 交互流程 3）。
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" { onCommit(); return false }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            textBinding.wrappedValue = textView.text
        }

        // MARK: 键盘上方工具条（inputAccessoryView）：‹ › 光标细调 + 选词

        func makeAccessoryView(target: UITextView) -> UIView {
            let bar = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
            bar.backgroundColor = UIColor(Color(hex: "F4F1EB"))
            bar.autoresizingMask = [.flexibleWidth]

            let topBorder = UIView()
            topBorder.backgroundColor = UIColor(Color(hex: "E1D9CB"))
            topBorder.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(topBorder)

            let iconColor = UIColor(Color(hex: "6F685D"))
            let left = Self.iconButton(system: "chevron.left", tint: iconColor,
                                       target: target, action: #selector(UITextView.dp_moveCaretLeft))
            let right = Self.iconButton(system: "chevron.right", tint: iconColor,
                                        target: target, action: #selector(UITextView.dp_moveCaretRight))
            let selectWord = UIButton(type: .system)
            selectWord.setTitle(String(localized: "选词"), for: .normal)
            selectWord.setTitleColor(UIColor(Theme.secondary), for: .normal)
            selectWord.titleLabel?.font = .systemFont(ofSize: 14)
            selectWord.addTarget(target, action: #selector(UITextView.dp_selectWordAtCaret), for: .touchUpInside)

            let stack = UIStackView(arrangedSubviews: [left, right, UIView(), selectWord])
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(stack)

            NSLayoutConstraint.activate([
                topBorder.topAnchor.constraint(equalTo: bar.topAnchor),
                topBorder.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                topBorder.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                topBorder.heightAnchor.constraint(equalToConstant: 1),
                stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -8),
                stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            ])
            bar.frame.size.height = 40
            return bar
        }

        private static func iconButton(system: String, tint: UIColor, target: Any?, action: Selector) -> UIButton {
            let b = UIButton(type: .system)
            let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            b.setImage(UIImage(systemName: system, withConfiguration: cfg), for: .normal)
            b.tintColor = tint
            b.addTarget(target, action: action, for: .touchUpInside)
            return b
        }
    }
}

/// 光标细调 + 选词——挂在 `UITextView` 自己身上（而不是 Coordinator），这样
/// `inputAccessoryView` 的按钮可以直接把 target 设成 textView 本身，行为始终作用在
/// 当前这一个 textView 实例上，不用另外传引用。
private extension UITextView {
    @objc func dp_moveCaretLeft() { dp_moveCaret(by: -1) }
    @objc func dp_moveCaretRight() { dp_moveCaret(by: 1) }

    func dp_moveCaret(by delta: Int) {
        guard let range = selectedTextRange else { return }
        let base = delta < 0 ? range.start : range.end
        guard let newPos = position(from: base, offset: delta) else { return }
        selectedTextRange = textRange(from: newPos, to: newPos)
    }

    /// 「选词」：把光标处的词整个选中，方便直接打字覆盖替换——不是 1c 的 AI 候选词
    /// （那个方向未采纳），只是原生「选中当前词」，系统剪切/复制/替换菜单照常可用。
    @objc func dp_selectWordAtCaret() {
        guard let range = selectedTextRange,
              let wordRange = tokenizer.rangeEnclosingPosition(range.start, with: .word, inDirection: .layout(.left))
                ?? tokenizer.rangeEnclosingPosition(range.start, with: .word, inDirection: .layout(.right))
        else { return }
        selectedTextRange = wordRange
    }
}
