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
        configureInstallerObserver()
        createNewTab(loadURL: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        progressObservation?.invalidate()
    }

    private func configureInstallerObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInstallUserScriptNotification(_:)),
            name: NSNotification.Name("InstallUserScriptNotification"),
            object: nil
        )
    }

    @objc private func handleInstallUserScriptNotification(_ notification: Notification) {
        guard let scriptURL = notification.object as? URL else { return }

        let task = URLSession.shared.dataTask(with: scriptURL) { [weak self] data, response, error in
            guard let data = data, let code = String(data: data, encoding: .utf8), !code.isEmpty else { return }
            let (parsedName, parsedMatch) = UserScriptStore.shared.parseMetadata(from: code)

            DispatchQueue.main.async {
                let alert = UIAlertController(
                    title: "安装油猴脚本",
                    message: "脚本名称: \(parsedName)\n匹配域名: \(parsedMatch)\n\n是否确定安装此油猴脚本？",
                    preferredStyle: .alert
                )

                alert.addAction(UIAlertAction(title: "安装", style: .default) { _ in
                    var scripts = UserScriptStore.shared.loadScripts()
                    let newScript = UserScript(
                        id: UUID().uuidString,
                        name: parsedName,
                        matchPattern: parsedMatch,
                        code: code,
                        isEnabled: true
                    )
                    scripts.append(newScript)
                    UserScriptStore.shared.saveScripts(scripts)
                    self?.activeTab.reloadUserScripts()
                })

                alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                self?.present(alert, animated: true)
            }
        }
        task.resume()
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
        configureToolbarButton(pluginButton, imageName: "square.3.layers.3d", action: #selector(showPluginPanel))
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

        var urlString = value
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            if urlString.contains(".") && !urlString.contains(" ") {
                urlString = "https://" + urlString
            } else {
                let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString
                return URL(string: "https://www.google.com/search?q=\(encoded)")
            }
        }

        if let encodedURLString = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encodedURLString) {
            return url
        }

        return URL(string: urlString)
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

    @objc private func showPluginPanel() {
        dismissKeyboard()
        let currentUrlStr = activeTab.url?.absoluteString ?? ""
        let currentHost = activeTab.url?.host ?? ""
        let matchingScripts = UserScriptStore.shared.loadScripts().filter {
            UserScriptStore.shared.isScriptMatching(script: $0, urlString: currentUrlStr)
        }

        let alert = UIAlertController(title: "正在运行的脚本", message: nil, preferredStyle: .actionSheet)

        if matchingScripts.isEmpty {
            let emptyAction = UIAlertAction(title: "当前页面未匹配到已启用的脚本", style: .default, handler: nil)
            emptyAction.isEnabled = false
            alert.addAction(emptyAction)
        } else {
            for script in matchingScripts {
                let statusIcon = script.isEnabled ? "🟢" : "⚪"
                alert.addAction(UIAlertAction(title: "\(statusIcon)  \(script.name)", style: .default) { [weak self] _ in
                    self?.showScriptSubMenu(for: script)
                })
            }
        }

        alert.addAction(UIAlertAction(title: "搜索适合当前网站的脚本", style: .default) { [weak self] _ in
            let searchUrlStr = "https://greasyfork.org/zh-CN/scripts?q=\(currentHost)"
            if let searchUrl = URL(string: searchUrlStr) {
                self?.load(url: searchUrl)
            }
        })

        alert.addAction(UIAlertAction(title: "用户脚本设置", style: .default) { [weak self] _ in
            self?.showPluginManager()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showScriptSubMenu(for script: UserScript) {
        let alert = UIAlertController(title: script.name, message: "匹配规则: \(script.matchPattern)", preferredStyle: .actionSheet)

        let scriptCmds = activeTab.registeredCommands.filter { $0.scriptId == script.id }
        for cmd in scriptCmds {
            alert.addAction(UIAlertAction(title: "⚙️  \(cmd.caption)", style: .default) { [weak self] _ in
                self?.activeTab.webView.evaluateJavaScript("window.__gm_invokeMenuCommand(\(cmd.cmdId))", completionHandler: nil)
            })
        }

        alert.addAction(UIAlertAction(title: script.isEnabled ? "⏸ 禁用该脚本" : "▶️ 启用该脚本", style: .default) { [weak self] _ in
            var scripts = UserScriptStore.shared.loadScripts()
            if let idx = scripts.firstIndex(where: { $0.id == script.id }) {
                scripts[idx].isEnabled = !script.isEnabled
                UserScriptStore.shared.saveScripts(scripts)
                self?.activeTab.reloadUserScripts()
            }
        })

        alert.addAction(UIAlertAction(title: "📝 编辑脚本代码", style: .default) { [weak self] _ in
            let editor = UserScriptEditorViewController(script: script)
            editor.onSave = { updatedScript in
                var scripts = UserScriptStore.shared.loadScripts()
                if let idx = scripts.firstIndex(where: { $0.id == updatedScript.id }) {
                    scripts[idx] = updatedScript
                    UserScriptStore.shared.saveScripts(scripts)
                    self?.activeTab.reloadUserScripts()
                }
            }
            let nav = UINavigationController(rootViewController: editor)
            self?.present(nav, animated: true)
        })

        alert.addAction(UIAlertAction(title: "返回上级", style: .cancel) { [weak self] _ in
            self?.showPluginPanel()
        })

        present(alert, animated: true)
    }

    @objc private func showPluginManager() {
        dismissKeyboard()
        let manager = UserScriptManagerViewController()
        manager.onScriptsUpdated = { [weak self] in
            self?.activeTab.reloadUserScripts()
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
