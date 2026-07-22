import UIKit
import WebKit

struct UserScript: Codable {
    var id: String
    var name: String
    var matchPattern: String
    var code: String
    var isEnabled: Bool
}

final class UserScriptStore {
    static let shared = UserScriptStore()
    private let key = "user_tampermonkey_scripts_v2"

    private init() {}

    func loadScripts() -> [UserScript] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let scripts = try? JSONDecoder().decode([UserScript].self, from: data) else {
            return []
        }
        return scripts
    }

    func saveScripts(_ scripts: [UserScript]) {
        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func parseMetadata(from code: String) -> (name: String, match: String) {
        var name = "未命名脚本"
        var match = "*"

        let lines = code.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("@name") {
                let parts = trimmed.components(separatedBy: "@name")
                if parts.count > 1 {
                    name = parts[1].trimmingCharacters(in: .whitespaces)
                }
            } else if trimmed.contains("@match") {
                let parts = trimmed.components(separatedBy: "@match")
                if parts.count > 1 {
                    match = parts[1].trimmingCharacters(in: .whitespaces)
                }
            } else if trimmed.contains("@include") {
                let parts = trimmed.components(separatedBy: "@include")
                if parts.count > 1 {
                    match = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return (name, match)
    }
}

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

final class TouchButton: UIButton {
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupFeedback()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFeedback()
    }

    private func setupFeedback() {
        addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
        addTarget(self, action: #selector(handleTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func handleTouchDown() {
        hapticGenerator.impactOccurred()
        UIView.animate(withDuration: 0.08) {
            self.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        }
    }

    @objc private func handleTouchUp() {
        UIView.animate(withDuration: 0.12) {
            self.transform = .identity
        }
    }
}

protocol TabItemDelegate: AnyObject {
    func tabDidUpdate(_ tab: TabItem)
    func tabDidFail(_ tab: TabItem, error: Error)
}

final class TabItem: NSObject, WKNavigationDelegate {
    let id = UUID()
    let webView: WKWebView
    var title = "主页"
    var url: URL?
    var isLoading = false
    var snapshot: UIImage?

    weak var delegate: TabItemDelegate?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let userContentController = WKUserContentController()

        let gmPolyfill = "window.unsafeWindow = window; window.GM_addStyle = function(css) { var style = document.createElement('style'); style.type = 'text/css'; style.appendChild(document.createTextNode(css)); (document.head || document.documentElement).appendChild(style); return style; }; window.GM_setValue = function(name, value) { localStorage.setItem('GM_' + name, JSON.stringify(value)); }; window.GM_getValue = function(name, defaultValue) { var val = localStorage.getItem('GM_' + name); return val ? JSON.parse(val) : defaultValue; }; window.GM_log = function(msg) { console.log('[Tampermonkey Log]', msg); };"
        userContentController.addUserScript(
            WKUserScript(source: gmPolyfill, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let scripts = UserScriptStore.shared.loadScripts()
        for script in scripts where script.isEnabled {
            userContentController.addUserScript(
                WKUserScript(source: script.code, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            )
        }

        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.backgroundColor = .systemBackground
        webView.isOpaque = true
    }

    func reloadUserScripts() {
        webView.configuration.userContentController.removeAllUserScripts()

        let gmPolyfill = "window.unsafeWindow = window; window.GM_addStyle = function(css) { var style = document.createElement('style'); style.type = 'text/css'; style.appendChild(document.createTextNode(css)); (document.head || document.documentElement).appendChild(style); return style; }; window.GM_setValue = function(name, value) { localStorage.setItem('GM_' + name, JSON.stringify(value)); }; window.GM_getValue = function(name, defaultValue) { var val = localStorage.getItem('GM_' + name); return val ? JSON.parse(val) : defaultValue; }; window.GM_log = function(msg) { console.log('[Tampermonkey Log]', msg); };"
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: gmPolyfill, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let scripts = UserScriptStore.shared.loadScripts()
        for script in scripts where script.isEnabled {
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: script.code, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            )
        }
    }

    func updateSnapshot(completion: (() -> Void)? = nil) {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else {
            completion?()
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds

        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
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
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        if ["http", "https", "about", "data", "blob"].contains(scheme) {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)

        if scheme == "intent", let fallbackURL = fallbackURL(from: url) {
            webView.load(URLRequest(url: fallbackURL))
            return
        }

        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func fallbackURL(from intentURL: URL) -> URL? {
        let value = intentURL.absoluteString

        guard let range = value.range(of: "S.browser_fallback_url=") else {
            return nil
        }

        let content = String(value[range.upperBound...])
        let encoded = content.components(separatedBy: ";").first ?? content
        let decoded = encoded.removingPercentEncoding ?? encoded

        return URL(string: decoded)
    }
}

final class BrowserViewController: UIViewController, UITextFieldDelegate, TabItemDelegate, UIGestureRecognizerDelegate {
    private var tabs: [TabItem] = []
    private var activeTabIndex = 0
    private var isFullscreen = false
    private var progressObservation: NSKeyValueObservation?

    private var activeTab: TabItem {
        tabs[activeTabIndex]
    }

    private let webContainer = UIView()
    private let homeView = UIView()
    private let bottomPanel = UIView()
    private let addressContainer = UIView()
    private let addressField = UITextField()
    private let refreshButton = TouchButton(type: .system)
    private let clearButton = TouchButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)

    private let navigationStack = UIStackView()
    private let backButton = TouchButton(type: .system)
    private let forwardButton = TouchButton(type: .system)
    private let pluginButton = TouchButton(type: .system)
    private let tabsButton = TouchButton(type: .system)
    private let moreButton = TouchButton(type: .system)

    private var bottomPanelBottomConstraint: NSLayoutConstraint?
    private var webTopSafeConstraint: NSLayoutConstraint?
    private var webTopFullscreenConstraint: NSLayoutConstraint?
    private var webBottomPanelConstraint: NSLayoutConstraint?
    private var webBottomFullscreenConstraint: NSLayoutConstraint?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .darkContent
    }

    override var prefersStatusBarHidden: Bool {
        isFullscreen
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        isFullscreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureInterface()
        configureKeyboardObservers()
        configureKeyboardDismissal()
        configureFullscreenExitGesture()
        createNewTab(loadURL: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        progressObservation?.invalidate()
    }

    private func configureInterface() {
        view.backgroundColor = .systemBackground

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = .systemBackground

        homeView.translatesAutoresizingMaskIntoConstraints = false
        homeView.backgroundColor = .systemBackground

        bottomPanel.translatesAutoresizingMaskIntoConstraints = false
        bottomPanel.backgroundColor = .secondarySystemBackground

        addressContainer.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.backgroundColor = .systemBackground
        addressContainer.layer.cornerRadius = 18
        addressContainer.layer.borderWidth = 0
        addressContainer.layer.shadowColor = UIColor.black.cgColor
        addressContainer.layer.shadowOpacity = 0.08
        addressContainer.layer.shadowRadius = 8
        addressContainer.layer.shadowOffset = CGSize(width: 0, height: 3)

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.delegate = self
        addressField.placeholder = "搜索或输入网址"
        addressField.font = .systemFont(ofSize: 14, weight: .regular)
        addressField.textColor = .label
        addressField.textAlignment = .center
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.clearButtonMode = .never
        addressField.textContentType = .URL
        addressField.addTarget(self, action: #selector(addressFieldDidChange), for: .editingChanged)

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.tintColor = .secondaryLabel
        refreshButton.setImage(
            UIImage(
                systemName: "arrow.clockwise",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            ),
            for: .normal
        )
        refreshButton.addTarget(self, action: #selector(handleRefreshTap), for: .touchUpInside)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.tintColor = .secondaryLabel
        clearButton.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            ),
            for: .normal
        )
        clearButton.alpha = 0
        clearButton.isHidden = true
        clearButton.addTarget(self, action: #selector(clearAddressInput), for: .touchUpInside)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = .clear
        progressView.progress = 0
        progressView.alpha = 0

        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        navigationStack.axis = .horizontal
        navigationStack.alignment = .fill
        navigationStack.distribution = .fillEqually
        navigationStack.spacing = 0

        configureToolbarButton(backButton, imageName: "chevron.left", action: #selector(goBack))
        configureToolbarButton(forwardButton, imageName: "chevron.right", action: #selector(goForward))
        configureToolbarButton(pluginButton, imageName: "puzzlepiece", action: #selector(showPluginManager))
        configureToolbarButton(tabsButton, imageName: "square.on.square", action: #selector(showTabsManager))
        configureToolbarButton(moreButton, imageName: "line.3.horizontal", action: #selector(showMoreMenu))

        navigationStack.addArrangedSubview(backButton)
        navigationStack.addArrangedSubview(forwardButton)
        navigationStack.addArrangedSubview(pluginButton)
        navigationStack.addArrangedSubview(tabsButton)
        navigationStack.addArrangedSubview(moreButton)

        addressContainer.addSubview(addressField)
        addressContainer.addSubview(refreshButton)
        addressContainer.addSubview(clearButton)

        bottomPanel.addSubview(addressContainer)
        bottomPanel.addSubview(navigationStack)

        view.addSubview(webContainer)
        view.addSubview(homeView)
        view.addSubview(bottomPanel)
        view.addSubview(progressView)

        bottomPanelBottomConstraint = bottomPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        webTopSafeConstraint = webContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        webTopFullscreenConstraint = webContainer.topAnchor.constraint(equalTo: view.topAnchor)
        webBottomPanelConstraint = webContainer.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor)
        webBottomFullscreenConstraint = webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        webTopSafeConstraint?.isActive = true
        webBottomPanelConstraint?.isActive = true

        NSLayoutConstraint.activate([
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            homeView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            homeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            homeView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

            bottomPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomPanelBottomConstraint!,

            addressContainer.topAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: 6),
            addressContainer.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor, constant: 14),
            addressContainer.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor, constant: -14),
            addressContainer.heightAnchor.constraint(equalToConstant: 36),

            refreshButton.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),

            clearButton.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 24),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            addressField.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor, constant: 16),
            addressField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -6),
            addressField.topAnchor.constraint(equalTo: addressContainer.topAnchor),
            addressField.bottomAnchor.constraint(equalTo: addressContainer.bottomAnchor),

            navigationStack.topAnchor.constraint(equalTo: addressContainer.bottomAnchor, constant: 2),
            navigationStack.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor, constant: 10),
            navigationStack.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor, constant: -10),
            navigationStack.bottomAnchor.constraint(equalTo: bottomPanel.safeAreaLayoutGuide.bottomAnchor, constant: -1),
            navigationStack.heightAnchor.constraint(equalToConstant: 38),

            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2)
        ])

        view.bringSubviewToFront(progressView)
    }

    private func configureToolbarButton(_ button: TouchButton, imageName: String, action: Selector?) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: imageName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        )
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero

        button.configuration = configuration
        if let action = action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
    }

    private func configureKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    private func configureKeyboardDismissal() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        view.addGestureRecognizer(tapGesture)
    }

    private func configureFullscreenExitGesture() {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleFullscreenExitGesture(_:)))
        gesture.minimumPressDuration = 2.0
        gesture.numberOfTouchesRequired = 2
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
    }

    private func createNewTab(loadURL url: URL?) {
        let tab = TabItem()
        tab.delegate = self
        tabs.append(tab)
        switchTab(to: tabs.count - 1)

        if let url = url {
            load(url: url)
        }
    }

    private func switchTab(to index: Int) {
        guard tabs.indices.contains(index) else {
            return
        }

        if tabs.indices.contains(activeTabIndex) {
            activeTab.webView.removeFromSuperview()
        }

        activeTabIndex = index

        let tab = activeTab
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(tab.webView)

        NSLayoutConstraint.activate([
            tab.webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            tab.webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])

        bindProgressObservation(to: tab.webView)

        if let url = tab.url {
            showBrowserUI()
            addressField.text = url.host ?? url.absoluteString
        } else {
            showHomeUI()
        }

        updateUIState()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else {
            return
        }

        let tab = tabs[index]
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabIndex = 0
            createNewTab(loadURL: nil)
            return
        }

        let nextIndex = min(index, tabs.count - 1)
        activeTabIndex = min(activeTabIndex, tabs.count - 1)
        switchTab(to: nextIndex)
    }

    private func bindProgressObservation(to webView: WKWebView) {
        progressObservation?.invalidate()

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] observedWebView, _ in
            DispatchQueue.main.async {
                guard let self, observedWebView.isLoading else {
                    return
                }

                self.progressView.alpha = 1
                self.progressView.setProgress(Float(observedWebView.estimatedProgress), animated: true)
                self.view.bringSubviewToFront(self.progressView)
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
        guard !tabs.isEmpty else {
            return
        }

        let isHome = homeView.alpha > 0.5

        backButton.isEnabled = !isHome && activeTab.webView.canGoBack
        forwardButton.isEnabled = !isHome && activeTab.webView.canGoForward
        moreButton.isEnabled = !isHome || isFullscreen
        refreshButton.isEnabled = !isHome

        let refreshImage = activeTab.isLoading ? "xmark" : "arrow.clockwise"

        refreshButton.setImage(
            UIImage(
                systemName: refreshImage,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            ),
            for: .normal
        )
    }

    private func destinationURL(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else {
            return nil
        }

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

    private func setFullscreen(_ enabled: Bool) {
        guard isFullscreen != enabled else {
            return
        }

        dismissKeyboard()

        isFullscreen = enabled
        bottomPanel.isHidden = enabled
        progressView.isHidden = enabled

        webTopSafeConstraint?.isActive = !enabled
        webTopFullscreenConstraint?.isActive = enabled
        webBottomPanelConstraint?.isActive = !enabled
        webBottomFullscreenConstraint?.isActive = enabled

        UIView.animate(withDuration: 0.2) {
            self.view.layoutIfNeeded()
        }

        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        updateUIState()
    }

    private func showLoadError(_ error: Error) {
        let nsError = error as NSError

        guard nsError.code != NSURLErrorCancelled else {
            return
        }

        let alert = UIAlertController(
            title: "无法访问页面",
            message: nsError.localizedDescription,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
            self?.activeTab.webView.reload()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        present(alert, animated: true)
    }

    private func updateAddressEditingAppearance() {
        let editing = addressField.isFirstResponder

        refreshButton.isHidden = editing
        clearButton.isHidden = !editing

        UIView.animate(withDuration: 0.12) {
            self.refreshButton.alpha = editing ? 0 : 1
            self.clearButton.alpha = editing ? 1 : 0
        }
    }

    func tabDidUpdate(_ tab: TabItem) {
        guard !tabs.isEmpty, tab.id == activeTab.id else {
            return
        }

        if let url = tab.url, !addressField.isFirstResponder {
            addressField.text = url.host ?? url.absoluteString
        }

        updateUIState()

        if !tab.isLoading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.activeTab.isLoading else {
                    return
                }

                UIView.animate(withDuration: 0.2) {
                    self.progressView.alpha = 0
                }
            }
        }
    }

    func tabDidFail(_ tab: TabItem, error: Error) {
        guard !tabs.isEmpty, tab.id == activeTab.id else {
            return
        }

        updateUIState()
        showLoadError(error)
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if let url = activeTab.url {
            textField.text = url.absoluteString
        }

        textField.textAlignment = .left
        updateAddressEditingAppearance()

        DispatchQueue.main.async {
            textField.selectAll(nil)
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if let url = activeTab.url {
            textField.text = url.host ?? url.absoluteString
        } else if textField.text?.isEmpty == true {
            textField.text = ""
        }

        textField.textAlignment = .center
        updateAddressEditingAppearance()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let text = textField.text, let url = destinationURL(from: text) else {
            return true
        }

        textField.resignFirstResponder()
        load(url: url)

        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view?.isDescendant(of: addressContainer) == true {
            return false
        }

        return true
    }

    @objc private func addressFieldDidChange() {
        updateAddressEditingAppearance()
    }

    @objc private func clearAddressInput() {
        addressField.text = ""
        addressField.becomeFirstResponder()
        updateAddressEditingAppearance()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard addressField.isFirstResponder else {
            bottomPanelBottomConstraint?.constant = 0
            view.layoutIfNeeded()
            return
        }

        guard !isFullscreen,
              let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval else {
            return
        }

        let frameInView = view.convert(keyboardFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - frameInView.minY)
        let offset = max(0, overlap - view.safeAreaInsets.bottom)

        let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let options = UIView.AnimationOptions(rawValue: curve << 16)

        bottomPanelBottomConstraint?.constant = -offset

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval else {
            bottomPanelBottomConstraint?.constant = 0
            view.layoutIfNeeded()
            return
        }

        let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let options = UIView.AnimationOptions(rawValue: curve << 16)

        bottomPanelBottomConstraint?.constant = 0

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func handleFullscreenExitGesture(_ gesture: UILongPressGestureRecognizer) {
        guard isFullscreen, gesture.state == .began else {
            return
        }

        setFullscreen(false)
    }

    @objc private func handleRefreshTap() {
        guard homeView.alpha < 0.5 else {
            return
        }

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

    @objc private func showPluginManager() {
        dismissKeyboard()
        let manager = UserScriptManagerViewController()
        manager.onScriptsUpdated = { [weak self] in
            self?.activeTab.reloadUserScripts()
            self?.activeTab.webView.reload()
        }
        let nav = UINavigationController(rootViewController: manager)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    @objc private func showTabsManager() {
        dismissKeyboard()

        activeTab.updateSnapshot { [weak self] in
            guard let self else {
                return
            }

            let manager = TabGridViewController(
                tabs: self.tabs,
                activeIndex: self.activeTabIndex
            )

            manager.onSelectTab = { [weak self] index in
                self?.switchTab(to: index)
            }

            manager.onCloseTab = { [weak self] index in
                self?.closeTab(at: index)
            }

            manager.onNewTab = { [weak self] in
                self?.createNewTab(loadURL: nil)
            }

            let navigationController = UINavigationController(rootViewController: manager)
            navigationController.modalPresentationStyle = .pageSheet
            self.present(navigationController, animated: true)
        }
    }

    @objc private func showMoreMenu() {
        dismissKeyboard()

        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        alert.addAction(
            UIAlertAction(
                title: isFullscreen ? "退出全屏浏览" : "全屏浏览",
                style: .default
            ) { [weak self] _ in
                guard let self else {
                    return
                }

                self.setFullscreen(!self.isFullscreen)
            }
        )

        alert.addAction(
            UIAlertAction(title: "油猴脚本扩展", style: .default) { [weak self] _ in
                self?.showPluginManager()
            }
        )

        if let url = activeTab.url {
            alert.addAction(UIAlertAction(title: "复制链接", style: .default) { _ in
                UIPasteboard.general.url = url
            })

            alert.addAction(UIAlertAction(title: "在 Safari 中打开", style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }

        alert.addAction(UIAlertAction(title: "清除缓存", style: .destructive) { [weak self] _ in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                self?.activeTab.webView.reload()
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

final class UserScriptManagerViewController: UITableViewController {
    private var scripts: [UserScript] = []
    var onScriptsUpdated: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "油猴脚本扩展"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ScriptCell")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(handleAddScript)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleDone)
        )

        loadData()
    }

    private func loadData() {
        scripts = UserScriptStore.shared.loadScripts()
        tableView.reloadData()
    }

    @objc private func handleAddScript() {
        let editor = UserScriptEditorViewController(script: nil)
        editor.onSave = { [weak self] newScript in
            self?.scripts.append(newScript)
            UserScriptStore.shared.saveScripts(self?.scripts ?? [])
            self?.tableView.reloadData()
            self?.onScriptsUpdated?()
        }
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        scripts.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ScriptCell", for: indexPath)
        let script = scripts[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = script.name
        content.secondaryText = "匹配: \(script.matchPattern)"
        cell.contentConfiguration = content

        let toggle = UISwitch()
        toggle.isOn = script.isEnabled
        toggle.tag = indexPath.row
        toggle.addTarget(self, action: #selector(handleToggle(_:)), for: .valueChanged)
        cell.accessoryView = toggle

        return cell
    }

    @objc private func handleToggle(_ sender: UISwitch) {
        let index = sender.tag
        scripts[index].isEnabled = sender.isOn
        UserScriptStore.shared.saveScripts(scripts)
        onScriptsUpdated?()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let script = scripts[indexPath.row]
        let editor = UserScriptEditorViewController(script: script)
        editor.onSave = { [weak self] updatedScript in
            self?.scripts[indexPath.row] = updatedScript
            UserScriptStore.shared.saveScripts(self?.scripts ?? [])
            self?.tableView.reloadData()
            self?.onScriptsUpdated?()
        }
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        if editingStyle == .delete {
            scripts.remove(at: indexPath.row)
            UserScriptStore.shared.saveScripts(scripts)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            onScriptsUpdated?()
        }
    }
}

final class UserScriptEditorViewController: UIViewController {
    private var script: UserScript?
    var onSave: ((UserScript) -> Void)?

    private let nameField = UITextField()
    private let matchField = UITextField()
    private let textView = UITextView()

    init(script: UserScript?) {
        self.script = script
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = script == nil ? "新建油猴脚本" : "编辑脚本"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存",
            style: .done,
            target: self,
            action: #selector(handleSave)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(handleCancel)
        )

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.borderStyle = .roundedRect
        nameField.placeholder = "脚本名称"
        nameField.text = script?.name ?? ""

        matchField.translatesAutoresizingMaskIntoConstraints = false
        matchField.borderStyle = .roundedRect
        matchField.placeholder = "匹配域名规则 (如 * 或 google.com)"
        matchField.text = script?.matchPattern ?? "*"

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.layer.borderWidth = 0.5
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.cornerRadius = 8
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.text = script?.code ?? "// ==UserScript==\n// @name         自定义油猴脚本\n// @match        *\n// ==/UserScript==\n\n(function() {\n    'use strict';\n})();"

        view.addSubview(nameField)
        view.addSubview(matchField)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            nameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            nameField.heightAnchor.constraint(equalToConstant: 38),

            matchField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 8),
            matchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            matchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            matchField.heightAnchor.constraint(equalToConstant: 38),

            textView.topAnchor.constraint(equalTo: matchField.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    @objc private func handleSave() {
        let codeText = textView.text ?? ""
        var nameText = nameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        var matchText = matchField.text?.trimmingCharacters(in: .whitespaces) ?? ""

        let parsed = UserScriptStore.shared.parseMetadata(from: codeText)
        if nameText.isEmpty { nameText = parsed.name }
        if matchText.isEmpty { matchText = parsed.match }

        let item = UserScript(
            id: script?.id ?? UUID().uuidString,
            name: nameText,
            matchPattern: matchText,
            code: codeText,
            isEnabled: script?.isEnabled ?? true
        )

        onSave?(item)
        dismiss(animated: true)
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }
}

final class TabGridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private var tabs: [TabItem]
    private var activeIndex: Int
    private var collectionView: UICollectionView!
    private let addButton = TouchButton(type: .system)

    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    init(tabs: [TabItem], activeIndex: Int) {
        self.tabs = tabs
        self.activeIndex = activeIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "标签页"
        view.backgroundColor = .systemGroupedBackground

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 88, right: 16)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TabGridCell.self, forCellWithReuseIdentifier: "TabGridCell")

        addButton.translatesAutoresizingMaskIntoConstraints = false

        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        )
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .systemBlue
        configuration.baseForegroundColor = .white

        addButton.configuration = configuration
        addButton.layer.shadowColor = UIColor.black.cgColor
        addButton.layer.shadowOpacity = 0.1
        addButton.layer.shadowRadius = 8
        addButton.layer.shadowOffset = CGSize(width: 0, height: 3)
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
            addButton.widthAnchor.constraint(equalToConstant: 48),
            addButton.heightAnchor.constraint(equalToConstant: 48)
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
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: "TabGridCell",
            for: indexPath
        ) as! TabGridCell

        let tab = tabs[indexPath.item]
        cell.configure(tab: tab, isActive: indexPath.item == activeIndex)

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
        guard tabs.indices.contains(index) else {
            return
        }

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
    private let headerView = UIView()
    private let thumbnailView = UIImageView()
    private let titleLabel = UILabel()
    private let closeButton = TouchButton(type: .system)

    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.masksToBounds = true

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = .secondarySystemGroupedBackground

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        thumbnailView.backgroundColor = .systemBackground

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.tintColor = .secondaryLabel
        closeButton.setImage(
            UIImage(
                systemName: "xmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            ),
            for: .normal
        )
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

        headerView.addSubview(titleLabel)
        headerView.addSubview(closeButton)

        contentView.addSubview(headerView)
        contentView.addSubview(thumbnailView)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 34),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            thumbnailView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(tab: TabItem, isActive: Bool) {
        titleLabel.text = tab.title
        thumbnailView.image = tab.snapshot
        contentView.layer.borderWidth = isActive ? 2 : 0
        contentView.layer.borderColor = isActive ? UIColor.systemBlue.cgColor : UIColor.clear.cgColor
    }

    @objc private func handleClose() {
        onClose?()
    }
}
