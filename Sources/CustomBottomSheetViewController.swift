import UIKit

final class CustomBottomSheetViewController: UIViewController {
    private let titleString: String
    private let items: [CustomBottomSheetItem]
    private let layout: CustomBottomSheetLayout

    init(title: String, items: [CustomBottomSheetItem], layout: CustomBottomSheetLayout = .list) {
        self.titleString = title
        self.items = items
        self.layout = layout
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1.0)
        setupViews()
    }

    private func setupViews() {
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.text = titleString

        let closeButton = TouchButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.tintColor = .tertiaryLabel
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        closeButton.addTarget(self, action: #selector(handleDismiss), for: .touchUpInside)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false

        if layout == .grid {
            setupGridLayout(in: scrollView)
        } else {
            setupListLayout(in: scrollView)
        }

        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),

            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    private func setupGridLayout(in scrollView: UIScrollView) {
        let mainStack = UIStackView()
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.spacing = 10

        var rowStack: UIStackView?
        for (idx, item) in items.enumerated() {
            if idx % 2 == 0 {
                rowStack = UIStackView()
                rowStack?.axis = .horizontal
                rowStack?.spacing = 10
                rowStack?.distribution = .fillEqually
                mainStack.addArrangedSubview(rowStack!)
            }

            let card = createCardButton(item: item, tag: idx, height: 48)
            rowStack?.addArrangedSubview(card)
        }

        if items.count % 2 != 0 {
            let spacer = UIView()
            rowStack?.addArrangedSubview(spacer)
        }

        scrollView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            mainStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    private func setupListLayout(in scrollView: UIScrollView) {
        let itemsStack = UIStackView()
        itemsStack.translatesAutoresizingMaskIntoConstraints = false
        itemsStack.axis = .vertical
        itemsStack.spacing = 8

        for (idx, item) in items.enumerated() {
            let card = createCardButton(item: item, tag: idx, height: 48)
            itemsStack.addArrangedSubview(card)
        }

        scrollView.addSubview(itemsStack)
        NSLayoutConstraint.activate([
            itemsStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            itemsStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            itemsStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            itemsStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            itemsStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    private func createCardButton(item: CustomBottomSheetItem, tag: Int, height: CGFloat) -> TouchButton {
        let card = TouchButton()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .white
        card.layer.cornerRadius = 16
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.04
        card.layer.shadowRadius = 8
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.clipsToBounds = false
        card.tag = tag
        card.addTarget(self, action: #selector(handleItemTap(_:)), for: .touchUpInside)

        if item.longPressHandler != nil {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleItemLongPress(_:)))
            longPress.minimumPressDuration = 0.5
            card.addGestureRecognizer(longPress)
        }

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .label
        label.text = item.title
        label.textAlignment = .center
        label.numberOfLines = 1

        card.addSubview(label)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: height),
            label.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -10)
        ])

        return card
    }

    @objc private func handleItemLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }

        let tag = gesture.view?.tag ?? 0
        guard tag < items.count else { return }
        let item = items[tag]
        guard let handler = item.longPressHandler else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        dismiss(animated: true) {
            handler()
        }
    }

    @objc private func handleItemTap(_ sender: UIButton) {
        let item = items[sender.tag]
        dismiss(animated: true) {
            item.handler?()
        }
    }

    @objc private func handleDismiss() {
        dismiss(animated: true)
    }
}
