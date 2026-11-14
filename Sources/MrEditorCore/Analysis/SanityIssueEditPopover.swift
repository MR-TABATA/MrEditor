import AppKit

/// データの嘘発見器（Data Sanity Check）で検出された異常行の「その場修正」ポップオーバー。
///
/// 異常行一覧でダブルクリックまたは修正ボタンを押した際に展開され、
/// 該当行の生テキストをその場で編集し、Enter 1 打で本文を書き換えて自動再検証できる。
final class SanityIssueEditPopover: NSViewController, NSTextFieldDelegate {

    private let issue: SanityIssue
    private let initialText: String
    private let onSave: (String) -> Void
    private let onJump: () -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let textField = NSTextField()
    private let saveButton = NSButton(title: S.sanityReverify, target: nil, action: nil)
    private let cancelButton = NSButton(title: S.sanityCancel, target: nil, action: nil)
    private let jumpButton = NSButton(title: S.sanityJumpToBody, target: nil, action: nil)

    init(issue: SanityIssue,
         initialText: String,
         onSave: @escaping (String) -> Void,
         onJump: @escaping () -> Void) {
        self.issue = issue
        self.initialText = initialText
        self.onSave = onSave
        self.onJump = onJump
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 165))
        view = root

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.stringValue = S.sanityEditTitle(line: issue.line)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor

        let kindText: String
        switch issue.kind {
        case .columnMismatch:
            kindText = S.sanityColumnMismatchDetail(actual: issue.actual, expected: issue.expected)
        case .typeContamination:
            kindText = S.sanityTypeContamDetail(col: issue.columnName, actual: issue.actual, expected: issue.expected)
        case .extremeLength:
            kindText = S.sanityExtremeLengthDetail(actual: issue.actual)
        }
        detailLabel.stringValue = kindText

        // テキスト入力欄（1行編集・等幅フォント・Returnで保存）
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.stringValue = initialText
        textField.isEditable = true
        textField.isSelectable = true
        textField.lineBreakMode = .byClipping
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.target = self
        textField.action = #selector(saveTapped)
        textField.delegate = self

        // ボタン
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveTapped)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.bezelStyle = .rounded
        jumpButton.target = self
        jumpButton.action = #selector(jumpTapped)

        let buttonStack = NSStackView(views: [jumpButton, NSView(), cancelButton, saveButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.distribution = .fill

        root.addSubview(titleLabel)
        root.addSubview(detailLabel)
        root.addSubview(textField)
        root.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            detailLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            textField.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
            textField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            textField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            textField.heightAnchor.constraint(equalToConstant: 26),

            buttonStack.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 16),
            buttonStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            buttonStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            buttonStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            buttonStack.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textField)
        textField.selectText(nil)
    }

    @objc private func saveTapped() {
        let edited = textField.stringValue
        dismiss(nil)
        onSave(edited)
    }

    @objc private func cancelTapped() {
        dismiss(nil)
    }

    @objc private func jumpTapped() {
        dismiss(nil)
        onJump()
    }
}
