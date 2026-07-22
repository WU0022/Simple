import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = BrowserViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class TabItem: NSObject, WKNavigationDelegate {
    let id = UUID()
    let webView: WKWebView
    var title: String = "主页"
    var url: URL?
    var isLoading: Bool = false
    var snapshot: UIImage?

    weak var delegate: TabItemDelegate?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        webView.backgroundColor = .systemBackground
    }

    func updateSnapshot(completion: (() -> Void)? = nil) {
        guard webView.bounds.width > 0 && webView.bounds.height > 0 else {
            completion?()
            return
        }

        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds

        webView.takeSnapshot(with: config) { [weak self] image, _ in
            self?.snapshot = image
            completion?()
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        url = webView.url
        title = webView.title ?? url?.host ?? "新标签页"
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        url = webView.url
        title = webView.title ?? url?.host ?? "新标签页"
        updateSnapshot()
        delegate?.tabDidUpdate(self)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        delegate?.tabDidFail(self, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        delegate?.tabDidFail(self, error: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let requestUrl = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = requestUrl.scheme?.lowercased() ?? ""

        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "data" || scheme == "blob" {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)
        UIApplication.shared.open(requestUrl, options: [:], completionHandler: nil)
    }
}

protocol TabItemDelegate: AnyObject {
    func tabDidUpdate(_ tab: TabItem)
    func tabDidFail(_ tab: TabItem, error: Error)
}

final class BrowserViewController: UIViewController, UITextFieldDelegate, TabItemDelegate {
    private var tabs: [TabItem] = []
    private var activeTabIndex: Int = 0

    private var activeTab: TabItem {
        tabs[activeTabIndex]
    }

    private let progressView = UIProgressView(progressViewStyle: .default)
    private let webContainer = UIView()
    private let homeView = UIView()
    private let bottomPanel = UIView()

    private let addressContainer = UIView()
    private let lockIconView = UIImageView()
    private let addressField = UITextField()
    private let inlineRefreshButton = UIButton(type: .system)

    private let navigationStack = UIStackView()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let homeButton = UIButton(type: .system)
    private let tabsButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)

    private var bottomPanelBottomConstraint: NSLayoutConstraint?
    private var progressObservation: NSKeyValueObservation?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureInterface()
        configureKeyboardDismissal()
        configureKeyboardObservers()
        createNewTab(loadURL: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        progressObservation?.invalidate()
    }

    private func configureKeyboardDismissal() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    private func configureKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval else {
            return
        }

        let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let options = UIView.AnimationOptions(rawValue: curveValue << 16)

        bottomPanelBottomConstraint?.constant = -keyboardFrame.height

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval else {
            return
        }

        let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let options = UIView.AnimationOptions(rawValue: curveValue << 16)

        bottomPanelBottomConstraint?.constant = 0

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    private func configureInterface() {
        view.backgroundColor = .systemBackground

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = .clear
        progressView.alpha = 0

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = .systemBackground

        homeView.translatesAutoresizingMaskIntoConstraints = false
        homeView.backgroundColor = .systemBackground

        bottomPanel.translatesAutoresizingMaskIntoConstraints = false
        bottomPanel.backgroundColor = .secondarySystemBackground

        addressContainer.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.backgroundColor = .white
        addressContainer.layer.cornerRadius = 20
        addressContainer.layer.shadowColor = UIColor.black.cgColor
        addressContainer.layer.shadowOpacity = 0.05
        addressContainer.layer.shadowRadius = 6
        addressContainer.layer.shadowOffset = CGSize(width: 0, height: 2)

        lockIconView.translatesAutoresizingMaskIntoConstraints = false
        lockIconView.image = UIImage(systemName: "lock.fill")
        lockIconView.tintColor = .secondaryLabel
        lockIconView.contentMode = .scaleAspectFit

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.delegate = self
        addressField.placeholder = "搜索或输入网址"
        addressField.font = .systemFont(ofSize: 15, weight: .regular)
        addressField.textColor = .label
        addressField.textAlignment = .center
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.textContentType = .URL

        inlineRefreshButton.translatesAutoresizingMaskIntoConstraints = false
        inlineRefreshButton.tintColor = .secondaryLabel
        inlineRefreshButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        inlineRefreshButton.addTarget(self, action: #selector(handleRefreshTap), for: .touchUpInside)

        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        navigationStack.axis = .horizontal
        navigationStack.alignment = .fill
        navigationStack.distribution = .fillEqually
        navigationStack.spacing = 0

        configurePillButton(backButton, icon: "chevron.backward", action: #selector(goBack))
        configurePillButton(forwardButton, icon: "chevron.forward", action: #selector(goForward))
        configurePillButton(homeButton, icon: "house", action: #selector(goHome))
        configurePillButton(tabsButton, icon: "square.on.square", action: #selector(showTabsManager))
        configurePillButton(moreButton, icon: "line.3.horizontal", action: #selector(showMoreMenu))

        navigationStack.addArrangedSubview(backButton)
        navigationStack.addArrangedSubview(forwardButton)
        navigationStack.addArrangedSubview(homeButton)
        navigationStack.addArrangedSubview(tabsButton)
        navigationStack.addArrangedSubview(moreButton)

        addressContainer.addSubview(lockIconView)
        addressContainer.addSubview(addressField)
        addressContainer.addSubview(inlineRefreshButton)

        bottomPanel.addSubview(addressContainer)
        bottomPanel.addSubview(navigationStack)

        view.addSubview(progressView)
        view.addSubview(webContainer)
        view.addSubview(homeView)
        view.addSubview(bottomPanel)

        bottomPanelBottomConstraint = bottomPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            webContainer.topAnchor.constraint(equalTo: view.topAnchor),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor),

            homeView.topAnchor.constraint(equalTo: view.topAnchor),
            homeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            homeView.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor),

            bottomPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomPanelBottomConstraint!,

            addressContainer.topAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: 8),
            addressContainer.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor, constant: 16),
            addressContainer.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor, constant: -16),
            addressContainer.heightAnchor.constraint(equalToConstant: 40),

            lockIconView.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor, constant: 14),
            lockIconView.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            lockIconView.widthAnchor.constraint(equalToConstant: 14),
            lockIconView.heightAnchor.constraint(equalToConstant: 14),

            inlineRefreshButton.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -8),
            inlineRefreshButton.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            inlineRefreshButton.widthAnchor.constraint(equalToConstant: 26),
            inlineRefreshButton.heightAnchor.constraint(equalToConstant: 26),

            addressField.leadingAnchor.constraint(equalTo: lockIconView.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: inlineRefreshButton.leadingAnchor, constant: -8),
            addressField.topAnchor.constraint(equalTo: addressContainer.topAnchor),
            addressField.bottomAnchor.constraint(equalTo: addressContainer.bottomAnchor),

            navigationStack.topAnchor.constraint(equalTo: addressContainer.bottomAnchor, constant: 6),
            navigationStack.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor, constant: 8),
            navigationStack.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor, constant: -8),
            navigationStack.bottomAnchor.constraint(equalTo: bottomPanel.safeAreaLayoutGuide.bottomAnchor, constant: -2),
            navigationStack.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func configurePillButton(_ button: UIButton, icon: String, action: Selector) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: icon)
        config.baseForegroundColor = .label
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)

        button.configuration = config
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func createNewTab(loadURL url: URL?) {
        let newTab = TabItem()
        newTab.delegate = self
        tabs.append(newTab)
        switchTab(to: tabs.count - 1)

        if let url = url {
            load(url: url)
        }
    }

    private func switchTab(to index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        activeTab.webView.removeFromSuperview()
        activeTabIndex = index

        let current = activeTab
        current.webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(current.webView)

        NSLayoutConstraint.activate([
            current.webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            current.webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            current.webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            current.webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])

        bindProgressObservation(for: current.webView)

        if let currentURL = current.url {
            showBrowserUI()
            addressField.text = currentURL.host ?? currentURL.absoluteString
        } else {
            showHomeUI()
        }

        updateUIState()
    }

    private func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        let targetTab = tabs[index]
        targetTab.webView.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            createNewTab(loadURL: nil)
        } else {
            let nextIndex = min(index, tabs.count - 1)
            switchTab(to: nextIndex)
        }
    }

    private func bindProgressObservation(for webView: WKWebView) {
        progressObservation?.invalidate()
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if webView.isLoading {
                    self.progressView.alpha = 1
                    self.progressView.setProgress(Float(webView.estimatedProgress), animated: true)
                }
            }
        }
    }

    private func load(url: URL) {
        showBrowserUI()
        addressField.text = url.host ?? url.absoluteString
        activeTab.webView.load(URLRequest(url: url))
    }

    private func showHomeUI() {
        homeView.alpha = 1
        webContainer.alpha = 0
        addressField.text = ""
        addressField.resignFirstResponder()
        progressView.alpha = 0
        updateUIState()
    }

    private func showBrowserUI() {
        homeView.alpha = 0
        webContainer.alpha = 1
        updateUIState()
    }

    private func updateUIState() {
        let isHome = homeView.alpha == 1
        backButton.isEnabled = !isHome && activeTab.webView.canGoBack
        forwardButton.isEnabled = !isHome && activeTab.webView.canGoForward
        moreButton.isEnabled = !isHome

        let refreshIcon = activeTab.isLoading ? "xmark" : "arrow.clockwise"
        inlineRefreshButton.setImage(UIImage(systemName: refreshIcon), for: .normal)

        if isHome {
            lockIconView.image = UIImage(systemName: "magnifyingglass")
        } else {
            let isSecure = activeTab.url?.scheme?.lowercased() == "https"
            lockIconView.image = UIImage(systemName: isSecure ? "lock.fill" : "lock.open.fill")
        }
    }

    private func destinationURL(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return URL(string: value)
        }

        if value.contains(".") && !value.contains(" ") {
            return URL(string: "https://\(value)")
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: value)]
        return components?.url
    }

    func tabDidUpdate(_ tab: TabItem) {
        guard tab == activeTab else { return }
        if let url = tab.url {
            addressField.text = addressField.isFirstResponder ? url.absoluteString : (url.host ?? url.absoluteString)
        }
        updateUIState()

        if !tab.isLoading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                UIView.animate(withDuration: 0.2) {
                    self?.progressView.alpha = 0
                }
            }
        }
    }

    func tabDidFail(_ tab: TabItem, error: Error) {
        guard tab == activeTab else { return }
        updateUIState()

        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }

        let alert = UIAlertController(title: "无法访问页面", message: nsError.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if let url = activeTab.url {
            textField.text = url.absoluteString
        }
        addressField.textAlignment = .left
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if let url = activeTab.url {
            textField.text = url.host ?? url.absoluteString
        }
        addressField.textAlignment = .center
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let text = textField.text, let url = destinationURL(from: text) else { return true }
        textField.resignFirstResponder()
        load(url: url)
        return true
    }

    @objc private func handleRefreshTap() {
        if homeView.alpha == 1 { return }

        if activeTab.isLoading {
            activeTab.webView.stopLoading()
        } else {
            activeTab.webView.reload()
        }
        updateUIState()
    }

    @objc private func goBack() {
        activeTab.webView.goBack()
    }

    @objc private func goForward() {
        activeTab.webView.goForward()
    }

    @objc private func goHome() {
        showHomeUI()
    }

    @objc private func showTabsManager() {
        dismissKeyboard()
        activeTab.updateSnapshot { [weak self] in
            guard let self = self else { return }

            let manager = TabGridViewController(tabs: self.tabs, activeIndex: self.activeTabIndex)
            manager.onSelectTab = { [weak self] index in
                self?.switchTab(to: index)
            }
            manager.onCloseTab = { [weak self] index in
                self?.closeTab(at: index)
            }
            manager.onNewTab = { [weak self] in
                self?.createNewTab(loadURL: nil)
            }

            let nav = UINavigationController(rootViewController: manager)
            nav.modalPresentationStyle = .pageSheet
            self.present(nav, animated: true)
        }
    }

    @objc private func showMoreMenu() {
        dismissKeyboard()
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        if let url = activeTab.url {
            alert.addAction(UIAlertAction(title: "复制链接", style: .default) { _ in
                UIPasteboard.general.url = url
            })

            alert.addAction(UIAlertAction(title: "在 Safari 打开", style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }

        alert.addAction(UIAlertAction(title: "清除缓存", style: .destructive) { [weak self] _ in
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                self?.activeTab.webView.reload()
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

final class TabGridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private var tabs: [TabItem]
    private var activeIndex: Int
    private var collectionView: UICollectionView!
    private let addButton = UIButton(type: .system)

    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    init(tabs: [TabItem], activeIndex: Int) {
        self.tabs = tabs
        self.activeIndex = activeIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "标签页"
        view.backgroundColor = .systemGroupedBackground

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 80, right: 16)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TabGridCell.self, forCellWithReuseIdentifier: "TabGridCell")

        addButton.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "plus")
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .systemBlue
        config.baseForegroundColor = .white
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        addButton.configuration = config
        addButton.layer.shadowColor = UIColor.black.cgColor
        addButton.layer.shadowOpacity = 0.15
        addButton.layer.shadowRadius = 10
        addButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        addButton.addTarget(self, action: #selector(handleNewTab), for: .touchUpInside)

        view.addSubview(collectionView)
        view.addSubview(addButton)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            addButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            addButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            addButton.widthAnchor.constraint(equalToConstant: 54),
            addButton.heightAnchor.constraint(equalToConstant: 54)
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleDone)
        )
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        tabs.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "TabGridCell", for: indexPath) as! TabGridCell
        let tab = tabs[indexPath.item]
        let isActive = indexPath.item == activeIndex

        cell.configure(tab: tab, isActive: isActive)
        cell.onClose = { [weak self] in
            self?.closeTab(at: indexPath.item)
        }

        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelectTab?(indexPath.item)
        dismiss(animated: true)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let width = (view.bounds.width - 44) / 2
        return CGSize(width: width, height: width * 1.35)
    }

    private func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        tabs.remove(at: index)
        if activeIndex == index {
            activeIndex = max(0, index - 1)
        } else if activeIndex > index {
            activeIndex -= 1
        }

        collectionView.reloadData()
        onCloseTab?(index)

        if tabs.isEmpty {
            dismiss(animated: true)
        }
    }

    @objc private func handleNewTab() {
        dismiss(animated: true) { [weak self] in
            self?.onNewTab?()
        }
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }
}

final class TabGridCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let thumbnailView = UIImageView()
    private let headerView = UIView()

    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.masksToBounds = true
        contentView.layer.borderWidth = 1

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = .secondarySystemGroupedBackground

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .label

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.backgroundColor = .systemBackground

        headerView.addSubview(titleLabel)
        headerView.addSubview(closeButton)
        contentView.addSubview(headerView)
        contentView.addSubview(thumbnailView)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            thumbnailView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(tab: TabItem, isActive: Bool) {
        titleLabel.text = tab.title
        contentView.layer.borderColor = isActive ? UIColor.systemBlue.cgColor : UIColor.clear.cgColor
        contentView.layer.borderWidth = isActive ? 2.0 : 0.0

        if let snapshot = tab.snapshot {
            thumbnailView.image = snapshot
        } else {
            thumbnailView.image = nil
        }
    }

    @objc private func handleClose() {
        onClose?()
    }
}
