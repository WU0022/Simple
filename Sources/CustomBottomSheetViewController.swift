import UIKit

final class CustomBottomSheetViewController: UIViewController {
    private let titleString: String
    private let items: [CustomBottomSheetItem]
    private let layout: CustomBottomSheetLayout

    private let dimmingView = UIView()
    private let containerView = UIView()
    private var containerBottomConstraint: NSLayoutConstraint?

    init(title: String, items: [CustomBottomSheetItem], layout: CustomBottomSheetLayout = .list) {
        self.titleString = title
        self.items = items
        self.layout = layout
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        animateIn()
    }

    private func setupViews() {
        view.backgroundColor = .clear

        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        dimmingView.alpha = 0
        let tapDimming = UITapGestureRecognizer(target: self, action: #selector(handleDismiss))
        dimmingView.addGestureRecognizer(tapDimming)

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.backgroundColor = UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1.0)
        containerView.layer.cornerRadius = 24
        containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        containerView.clipsToBounds = true

        let handleBar = UIView()
        handleBar.translatesAutoresizingMaskIntoConstraints = false
        handleBar.backgroundColor = .systemGray4
        handleBar.layer.cornerRadius = 2.5

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

        containerView.addSubview(handleBar)
        containerView.addSubview(titleLabel)
        containerView.addSubview(closeButton)
        containerView.addSubview(contentContainer)

        view.addSubview(dimmingView)
        view.addSubview(containerView)

        containerBottomConstraint = containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 400)

        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerBottomConstraint!,

            handleBar.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            handleBar.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            handleBar.widthAnchor.constraint(equalToConstant: 36),
            handleBar.heightAnchor.constraint(equalToConstant: 5),

            titleLabel.topAnchor.constraint(equalTo: handleBar.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),

            closeButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -14),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            contentContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            contentContainer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            contentContainer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            contentContainer.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    private func animateIn() {
        containerBottomConstraint?.constant = 0
        UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseOut]) {
            self.dimmingView.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    private func setupGridLayout(in container: UIView) {
        let mainStack = UIStackView()
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.axis = .vertical
        mainStack.spacing = 8

        let gridItems = items.filter { !$0.isDestructive }
        let destructiveItems = items.filter { $0.isDestructive }

        var rowStack: UIStackView?
        for (idx, item) in gridItems.enumerated() {
            if idx % 2 == 0 {
                rowStack = UIStackView()
                rowStack?.axis = .horizontal
                rowStack?.spacing = 8
                rowStack?.distribution = .fillEqually
                mainStack.addArrangedSubview(rowStack!)
            }

            let card = createCardButton(item: item, tag: idx, height: 44)
            rowStack?.addArrangedSubview(card)
        }

        if gridItems.count % 2 != 0 {
            let spacer = UIView()
            rowStack?.addArrangedSubview(spacer)
        }

        for item in destructiveItems {
            let idx = items.firstIndex(where: { $0.title == item.title }) ?? 0
            let card = createCardButton(item: item, tag: idx, height: 44)
            mainStack.addArrangedSubview(card)
        }

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func setupListLayout(in container: UIView) {
        let itemsStack = UIStackView()
        itemsStack.translatesAutoresizingMaskIntoConstraints = false
        itemsStack.axis = .vertical
        itemsStack.spacing = 6

        for (idx, item) in items.enumerated() {
            let card = createCardButton(item: item, tag: idx, height: 44)
            itemsStack.addArrangedSubview(card)
        }

        container.addSubview(itemsStack)
        NSLayoutConstraint.activate([
            itemsStack.topAnchor.constraint(equalTo: container.topAnchor),
            itemsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            itemsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            itemsStack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func createCardButton(item: CustomBottomSheetItem, tag: Int, height: CGFloat) -> TouchButton {
        let card = TouchButton(type: .custom)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .white
        card.layer.cornerRadius = 14
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.03
        card.layer.shadowRadius = 6
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.clipsToBounds = false
        card.tag = tag
        card.addTarget(self, action: #selector(handleItemTap(_:)), for: .touchUpInside)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = item.isDestructive ? .systemRed : .label
        label.text = item.title
        label.textAlignment = .center
        label.numberOfLines = 1

        card.addSubview(label)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: height),
            label.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -8)
        ])

        return card
    }

    @objc private func handleItemTap(_ sender: UIButton) {
        let item = items[sender.tag]
        handleDismiss {
            item.handler?()
        }
    }

    @objc private func handleDismiss() {
        handleDismiss(completion: nil)
    }

    private func handleDismiss(completion: (() -> Void)?) {
        containerBottomConstraint?.constant = 400
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn], animations: {
            self.dimmingView.alpha = 0
            self.view.layoutIfNeeded()
        }) { _ in
            self.dismiss(animated: false, completion: completion)
        }
    }
}
