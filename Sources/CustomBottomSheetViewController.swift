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

        let closeButton = TouchButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.tintColor = .tertiaryLabel
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        closeButton.addTarget(self, action: #selector(handleDismiss), for: .touchUpInside)

        let contentContainer = UIView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        if layout == .grid {
            setupGridLayout(in: contentContainer)
        } else {
            setupListLayout(in: contentContainer)
        }

        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),

            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            contentContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            contentContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    private func setupGridLayout(in container: UIView) {
        let mainStack = UIStackView()
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.spacing = 10

        let gridItems = items.filter { !$0.isDestructive }
        let destructiveItems = items.filter { $0.isDestructive }

        var rowStack: UIStackView?
        for (idx, item) in gridItems.enumerated() {
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

        if gridItems.count % 2 != 0 {
            let spacer = UIView()
            rowStack?.addArrangedSubview(spacer)
        }

        for item in destructiveItems {
            let idx = items.firstIndex(where: { $0.title == item.title }) ?? 0
            let card = createCardButton(item: item, tag: idx, height: 48)
            mainStack.addArrangedSubview(card)
        }

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
    }

    private func setupListLayout(in container: UIView) {
        let itemsStack = UIStackView()
        itemsStack.translatesAutoresizingMaskIntoConstraints = false
        itemsStack.axis = .vertical
        itemsStack.spacing = 8

        for (idx, item) in items.enumerated() {
            let card = createCardButton(item: item, tag: idx, height: 48)
            itemsStack.addArrangedSubview(card)
        }

        container.addSubview(itemsStack)
        NSLayoutConstraint.activate([
            itemsStack.topAnchor.constraint(equalTo: container.topAnchor),
            itemsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            itemsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            itemsStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
    }

    private func createCardButton(item: CustomBottomSheetItem, tag: Int, height: CGFloat) -> TouchButton {
        let card = TouchButton(type: .custom)
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

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = item.isDestructive ? .systemRed : .label
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
