import BookmaniaCore
import SwiftUI

/// Presents the reader for a chapter (full screen).
struct ReaderScreen: UIViewControllerRepresentable {
    let chapter: LocalChapter
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        switch chapter.kind {
        case .epub, .mobi, .azw3:
            return TextReaderViewController(chapter: chapter, onClose: onClose)
        case .archive, .folder:
            return MessageViewController(
                title: NSLocalizedString("Picture book", comment: ""),
                message: NSLocalizedString("comic_reader_later", comment: ""),
                onClose: onClose
            )
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// A full-screen message with a close button.
final class MessageViewController: UIViewController {
    private let titleText: String
    private let message: String
    private let onClose: () -> Void

    init(title: String, message: String, onClose: @escaping () -> Void) {
        self.titleText = title
        self.message = message
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = UILabel()
        title.text = titleText
        title.font = .preferredFont(forTextStyle: .title3)
        title.numberOfLines = 0
        title.textAlignment = .center
        let body = UILabel()
        body.text = message
        body.numberOfLines = 0
        body.textAlignment = .center
        body.textColor = .secondaryLabel
        let close = UIButton(configuration: .borderedProminent())
        close.setTitle(NSLocalizedString("Close", comment: ""), for: .normal)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        [title, body, close].forEach(stack.addArrangedSubview)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
        ])
    }

    @objc private func closeTapped() { onClose() }
}
