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
    private let failureOverlayView = UIView()
    private let failureTitleLabel = UILabel()
    private let failureReasonLabel = UILabel()
    private let failureURLLabel = UILabel()
    private let failureBackButton = TouchButton(type: .system)
    private let failureReloadButton = TouchButton(type: .system)

    private let bottomPanel = UIView()
    private let addressContainer = UIView()
    private let contentBgView = UIView()
    private let siteSettingsButton = TouchButton(type: .system)
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

        DispatchQueue.main.async { [weak self] in
            EyeProtectionManager.shared.restoreState(in: self?.view.window)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        for (idx, tab) in tabs.enumerated() {
            if idx != activeTabIndex {
                tab.snapshot = nil
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        progressObservation?.invalidate()
    }

    private func resetProgress() {
        progressView.setProgress(0, animated: false)
        progressView.alpha = 0
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
        let themeBg = UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
        view.backgroundColor = themeBg

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = themeBg

        homeView.translatesAutoresizingMaskIntoConstraints = false
        homeView.backgroundColor = themeBg

        failureOverlayView.translatesAutoresizingMaskIntoConstraints = false
        failureOverlayView.backgroundColor = themeBg
        failureOverlayView.isHidden = true

        failureTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        failureTitleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        failureTitleLabel.textColor = .label
        failureTitleLabel.text = "无法连接服务器"

        failureReasonLabel.translatesAutoresizingMaskIntoConstraints = false
        failureReasonLabel.font = .systemFont(ofSize: 14, weight: .regular)
        failureReasonLabel.textColor = .secondaryLabel
        failureReasonLabel.textAlignment = .center
        failureReasonLabel.numberOfLines = 0
        failureReasonLabel.text = "服务器拒绝连接或已被网络策略/代理拦截。"

        failureURLLabel.translatesAutoresizingMaskIntoConstraints = false
        failureURLLabel.font = .systemFont(ofSize: 12, weight: .regular)
        failureURLLabel.textColor = .tertiaryLabel
        failureURLLabel.textAlignment = .center
        failureURLLabel.numberOfLines = 2

        failureBackButton.translatesAutoresizingMaskIntoConstraints = false
        var backConfig = UIButton.Configuration.filled()
        backConfig.title = "返回上一页"
        backConfig.baseBackgroundColor = .white
        backConfig.baseForegroundColor = .label
        backConfig.cornerStyle = .medium
        failureBackButton.configuration = backConfig
        failureBackButton.layer.shadowColor = UIColor.black.cgColor
        failureBackButton.layer.shadowOpacity = 0.04
        failureBackButton.layer.shadowRadius = 6
        failureBackButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        failureBackButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)

        failureReloadButton.translatesAutoresizingMaskIntoConstraints = false
        var reloadConfig = UIButton.Configuration.filled()
        reloadConfig.title = "重新加载"
        reloadConfig.baseBackgroundColor = .systemBlue
        reloadConfig.baseForegroundColor = .white
        reloadConfig.cornerStyle = .medium
        failureReloadButton.configuration = reloadConfig
        failureReloadButton.addTarget(self, action: #selector(handleRefreshTap), for: .touchUpInside)

        let btnStack = UIStackView(arrangedSubviews: [failureBackButton, failureReloadButton])
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        btnStack.axis = .horizontal
        btnStack.spacing = 12
        btnStack.distribution = .fillEqually

        failureOverlayView.addSubview(failureTitleLabel)
        failureOverlayView.addSubview(failureReasonLabel)
        failureOverlayView.addSubview(failureURLLabel)
        failureOverlayView.addSubview(btnStack)

        NSLayoutConstraint.activate([
            failureTitleLabel.centerXAnchor.constraint(equalTo: failureOverlayView.centerXAnchor),
            failureTitleLabel.centerYAnchor.constraint(equalTo: failureOverlayView.centerYAnchor, constant: -40),

            failureReasonLabel.topAnchor.constraint(equalTo: failureTitleLabel.bottomAnchor, constant: 8),
            failureReasonLabel.leadingAnchor.constraint(equalTo: failureOverlayView.leadingAnchor, constant: 32),
            failureReasonLabel.trailingAnchor.constraint(equalTo: failureOverlayView.trailingAnchor, constant: -32),

            failureURLLabel.topAnchor.constraint(equalTo: failureReasonLabel.bottomAnchor, constant: 10),
            failureURLLabel.leadingAnchor.constraint(equalTo: failureOverlayView.leadingAnchor, constant: 32),
            failureURLLabel.trailingAnchor.constraint(equalTo: failureOverlayView.trailingAnchor, constant: -32),

            btnStack.topAnchor.constraint(equalTo: failureURLLabel.bottomAnchor, constant: 24),
            btnStack.centerXAnchor.constraint(equalTo: failureOverlayView.centerXAnchor),
            btnStack.widthAnchor.constraint(equalToConstant: 240),
            btnStack.heightAnchor.constraint(equalToConstant: 40)
        ])

        bottomPanel.translatesAutoresizingMaskIntoConstraints = false
        bottomPanel.backgroundColor = themeBg
        bottomPanel.clipsToBounds = false

        addressContainer.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.backgroundColor = .clear
        addressContainer.layer.shadowColor = UIColor.black.cgColor
        addressContainer.layer.shadowOpacity = 0.05
        addressContainer.layer.shadowRadius = 8
        addressContainer.layer.shadowOffset = CGSize(width: 0, height: 2)
        addressContainer.clipsToBounds = false

        contentBgView.translatesAutoresizingMaskIntoConstraints = false
        contentBgView.backgroundColor = .white
        contentBgView.layer.cornerRadius = 19
        contentBgView.clipsToBounds = true

        let longPressAddress = UILongPressGestureRecognizer(target: self, action: #selector(handleAddressLongPress(_:)))
        longPressAddress.minimumPressDuration = 0.6
        addressContainer.addGestureRecognizer(longPressAddress)

        siteSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        siteSettingsButton.tintColor = .secondaryLabel
        siteSettingsButton.setImage(
            UIImage(
                systemName: "slider.horizontal.3",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            ),
            for: .normal
        )
        siteSettingsButton.addTarget(self, action: #selector(showSiteDomainSettings), for: .touchUpInside)

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
        navigationStack.spacing = 8

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

        contentBgView.addSubview(siteSettingsButton)
        contentBgView.addSubview(addressField)
        contentBgView.addSubview(refreshButton)
        contentBgView.addSubview(clearButton)
        contentBgView.addSubview(progressView)

        addressContainer.addSubview(contentBgView)
        bottomPanel.addSubview(addressContainer)
        bottomPanel.addSubview(navigationStack)

        view.addSubview(webContainer)
        view.addSubview(homeView)
        view.addSubview(failureOverlayView)
        view.addSubview(bottomPanel)

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

            failureOverlayView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            failureOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failureOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failureOverlayView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

            bottomPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomPanelBottomConstraint!,

            addressContainer.topAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: 6),
            addressContainer.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor, constant: 16),
            addressContainer.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor, constant: -16),
            addressContainer.heightAnchor.constraint(equalToConstant: 40),

            contentBgView.topAnchor.constraint(equalTo: addressContainer.topAnchor),
            contentBgView.bottomAnchor.constraint(equalTo: addressContainer.bottomAnchor),
            contentBgView.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor),
            contentBgView.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor),

            siteSettingsButton.leadingAnchor.constraint(equalTo: contentBgView.leadingAnchor, constant: 8),
            siteSettingsButton.centerYAnchor.constraint(equalTo: contentBgView.centerYAnchor),
            siteSettingsButton.widthAnchor.constraint(equalToConstant: 24),
            siteSettingsButton.heightAnchor.constraint(equalToConstant: 24),

            progressView.leadingAnchor.constraint(equalTo: contentBgView.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: contentBgView.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: contentBgView.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2.5),

            refreshButton.trailingAnchor.constraint(equalTo: contentBgView.trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: contentBgView.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),

            clearButton.trailingAnchor.constraint(equalTo: contentBgView.trailingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: contentBgView.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 24),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            addressField.leadingAnchor.constraint(equalTo: siteSettingsButton.trailingAnchor, constant: 6),
            addressField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -6),
            addressField.topAnchor.constraint(equalTo: contentBgView.topAnchor),
            addressField.bottomAnchor.constraint(equalTo: contentBgView.bottomAnchor),

            navigationStack.topAnchor.constraint(equalTo: addressContainer.bottomAnchor, constant: 8),
            navigationStack.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor, constant: 16),
            navigationStack.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor, constant: -16),
            navigationStack.bottomAnchor.constraint(equalTo: bottomPanel.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            navigationStack.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    @objc private func handleAddressLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let urlText = activeTab.url?.absoluteString ?? addressField.text ?? ""
        guard !urlText.isEmpty else { return }

        UIPasteboard.general.string = urlText
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()
        showToastNotice("已复制当前网址")
    }

    private func showToastNotice(_ text: String) {
        let toast = UILabel()
        toast.text = "  \(text)  "
        toast.font = .systemFont(ofSize: 13, weight: .medium)
        toast.textColor = .white
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        toast.layer.cornerRadius = 12
        toast.clipsToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.alpha = 0

        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: -12),
            toast.heightAnchor.constraint(equalToConstant: 32)
        ])

        UIView.animate(withDuration: 0.18) { toast.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            UIView.animate(withDuration: 0.2, animations: { toast.alpha = 0 }) { _ in
                toast.removeFromSuperview()
            }
        }
    }

    private func configureToolbarButton(_ button: TouchButton, imageName: String, action: Selector?) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: imageName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)

        button.configuration = configuration
        button.backgroundColor = .white
        button.layer.cornerRadius = 12
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.04
        button.layer.shadowRadius = 6
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.clipsToBounds = false
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
        gesture.minimumPressDuration = 1.5
        gesture.numberOfTouchesRequired = 2
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
    }

    private func createNewTab(loadURL url: URL?, sourceID: UUID? = nil) {
        let tab = TabItem()
        tab.sourceTabID = sourceID
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

        resetProgress()
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

        if tab.isDisplayingFailurePage {
            showFailureUI(for: tab)
        } else if let url = tab.url {
            showBrowserUI()
            addressField.text = url.host ?? url.absoluteString
        } else {
            showHomeUI()
        }

        updateUIState()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        resetProgress()

        let tab = tabs[index]
        tab.destroy()
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
                guard let self = self,
                      observedWebView == self.activeTab.webView,
                      observedWebView.isLoading,
                      self.homeView.alpha < 0.5,
                      !self.activeTab.isDisplayingFailurePage else {
                    self?.resetProgress()
                    return
                }

                self.progressView.alpha = 1
                self.progressView.setProgress(Float(observedWebView.estimatedProgress), animated: true)
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
        failureOverlayView.isHidden = true
        addressField.text = ""
        addressField.resignFirstResponder()
        resetProgress()
        updateUIState()
    }

    private func showBrowserUI() {
        homeView.alpha = 0
        webContainer.alpha = 1
        failureOverlayView.isHidden = true
        updateUIState()
    }

    private func showFailureUI(for tab: TabItem) {
        homeView.alpha = 0
        webContainer.alpha = 1
        failureOverlayView.isHidden = false
        failureURLLabel.text = tab.failedURL?.absoluteString ?? tab.url?.absoluteString ?? ""
        if let err = tab.failureError as NSError? {
            failureTitleLabel.text = "无法连接服务器"
            failureReasonLabel.text = err.localizedDescription
        }
        addressField.text = tab.failedURL?.host ?? tab.failedURL?.absoluteString ?? ""
        resetProgress()
        updateUIState()
    }

    private func updateUIState() {
        guard !tabs.isEmpty else {
            return
        }

        let isHome = homeView.alpha > 0.5

        let canGoBack = activeTab.webView.canGoBack || activeTab.isDisplayingFailurePage || activeTab.sourceTabID != nil || activeTab.previousURL != nil
        backButton.isEnabled = !isHome && canGoBack
        forwardButton.isEnabled = !isHome && activeTab.webView.canGoForward
        moreButton.isEnabled = true
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
        guard !value.isEmpty else { return nil }

        SearchHistoryStore.shared.addHistory(value)

        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return URL(string: value)
        }

        if value.contains(".") && !value.contains(" ") {
            return URL(string: "https://" + value)
        }

        if let encodedQuery = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return URL(string: "https://www.google.com/search?q=\(encodedQuery)")
        }

        return nil
    }

    private func setFullscreen(_ enabled: Bool) {
        guard isFullscreen != enabled else {
            return
        }

        dismissKeyboard()

        isFullscreen = enabled
        bottomPanel.isHidden = enabled

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

    private func updateAddressEditingAppearance() {
        let editing = addressField.isFirstResponder

        refreshButton.isHidden = editing
        clearButton.isHidden = !editing

        UIView.animate(withDuration: 0.12) {
            self.refreshButton.alpha = editing ? 0 : 1
            self.clearButton.alpha = editing ? 1 : 0
        }
    }

    func tabRequestNewTab(url: URL) {
        createNewTab(loadURL: url, sourceID: activeTab.id)
    }

    func tabRequestGoBack(_ tab: TabItem) {
        goBack()
    }

    func tabProcessTerminated(_ tab: TabItem) {
        guard !tabs.isEmpty, tab.id == activeTab.id else { return }
        resetProgress()
        let alert = UIAlertController(title: "页面被释放", message: "系统内存压力过大导致该页面已被释放，是否重新加载？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "恢复页面", style: .default) { [weak self] _ in
            self?.activeTab.webView.reload()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func tabDidUpdate(_ tab: TabItem) {
        guard !tabs.isEmpty, tab.id == activeTab.id else {
            return
        }

        if !tab.isDisplayingFailurePage {
            failureOverlayView.isHidden = true
            if let url = tab.url, !addressField.isFirstResponder {
                addressField.text = url.host ?? url.absoluteString
            }
        }

        if !tab.isLoading {
            resetProgress()
        }

        updateUIState()
    }

    func tabDidFail(_ tab: TabItem, error: Error) {
        guard !tabs.isEmpty, tab.id == activeTab.id else {
            return
        }

        showFailureUI(for: tab)
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if let url = activeTab.url {
            textField.text = url.absoluteString
        }

        textField.textAlignment = .left
        updateAddressEditingAppearance()

        UIView.animate(withDuration: 0.2) {
            self.navigationStack.alpha = 0
            self.navigationStack.isHidden = true
            self.view.layoutIfNeeded()
        }

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

        UIView.animate(withDuration: 0.2) {
            self.navigationStack.isHidden = false
            self.navigationStack.alpha = 1
            self.view.layoutIfNeeded()
        }
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
            if bottomPanelBottomConstraint?.constant != 0 {
                bottomPanelBottomConstraint?.constant = 0
                view.layoutIfNeeded()
            }
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
        let offset = max(0, overlap - 48)

        let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let options = UIView.AnimationOptions(rawValue: curve << 16)

        bottomPanelBottomConstraint?.constant = -offset

        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard addressField.isFirstResponder else {
            if bottomPanelBottomConstraint?.constant != 0 {
                bottomPanelBottomConstraint?.constant = 0
                view.layoutIfNeeded()
            }
            return
        }

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

        if activeTab.isDisplayingFailurePage {
            guard let targetURL = activeTab.failedURL else { return }
            activeTab.isDisplayingFailurePage = false
            failureOverlayView.isHidden = true
            activeTab.webView.load(URLRequest(url: targetURL))
            updateUIState()
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
        if activeTab.isDisplayingFailurePage {
            let originURL = activeTab.failureOriginURL
            let sourceID = activeTab.sourceTabID

            activeTab.clearFailureState()
            failureOverlayView.isHidden = true

            if let originURL = originURL {
                activeTab.url = originURL
                addressField.text = originURL.host ?? originURL.absoluteString
                updateUIState()
                return
            }

            if let sourceID = sourceID,
               let sourceIndex = tabs.firstIndex(where: { $0.id == sourceID }) {
                let closingIndex = activeTabIndex
                closeTab(at: closingIndex)
                switchTab(to: sourceIndex)
                return
            }

            if activeTab.webView.canGoBack {
                activeTab.webView.goBack()
                updateUIState()
                return
            }

            showHomeUI()
            return
        }

        if activeTab.webView.canGoBack {
            activeTab.webView.goBack()
        } else if let sourceID = activeTab.sourceTabID, let sourceIndex = tabs.firstIndex(where: { $0.id == sourceID }) {
            let closingIndex = activeTabIndex
            closeTab(at: closingIndex)
            switchTab(to: sourceIndex)
        } else if let prevURL = activeTab.previousURL, prevURL != activeTab.url {
            load(url: prevURL)
        } else if tabs.count > 1 {
            closeTab(at: activeTabIndex)
        } else {
            showHomeUI()
        }
    }

    @objc private func goForward() {
        activeTab.webView.goForward()
    }

    @objc private func showSiteDomainSettings() {
        dismissKeyboard()
        guard let host = activeTab.url?.host else { return }

        let settingsVC = DomainSettingsViewController(domain: host) { [weak self] in
            self?.activeTab.reloadUserScripts()
        }
        settingsVC.onExtractText = { [weak self] in
            self?.extractPageText()
        }

        let nav = UINavigationController(rootViewController: settingsVC)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    private func extractPageText() {
        activeTab.webView.evaluateJavaScript("document.body.innerText") { [weak self] result, error in
            guard let text = result as? String, !text.isEmpty else { return }
            let vc = UIViewController()
            vc.title = "网页正文内容"
            vc.view.backgroundColor = .systemBackground

            let textView = UITextView()
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.font = .systemFont(ofSize: 15)
            textView.isEditable = false
            textView.text = text

            vc.view.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: vc.view.topAnchor),
                textView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
                textView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor)
            ])

            vc.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(self?.dismissModalVC))
            let nav = UINavigationController(rootViewController: vc)
            self?.present(nav, animated: true)
        }
    }

    @objc private func dismissModalVC() {
        dismiss(animated: true)
    }

    @objc private func showPluginPanel() {
        dismissKeyboard()
        let currentUrlStr = activeTab.url?.absoluteString ?? ""
        let currentHost = activeTab.url?.host ?? ""
        let matchingScripts = UserScriptStore.shared.loadScripts().filter {
            UserScriptStore.shared.isScriptMatching(script: $0, urlString: currentUrlStr)
        }

        var items: [CustomBottomSheetItem] = []

        if matchingScripts.isEmpty {
            items.append(CustomBottomSheetItem(
                title: "未匹配到脚本",
                handler: nil
            ))
        } else {
            for script in matchingScripts {
                items.append(CustomBottomSheetItem(
                    title: script.name,
                    handler: { [weak self] in
                        self?.showScriptSubMenu(for: script)
                    }
                ))
            }
        }

        items.append(CustomBottomSheetItem(
            title: "搜索适合当前网站的脚本",
            handler: { [weak self] in
                let searchUrlStr = "https://greasyfork.org/zh-CN/scripts?q=\(currentHost)"
                if let searchUrl = URL(string: searchUrlStr) {
                    self?.load(url: searchUrl)
                }
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "用户脚本管理",
            handler: { [weak self] in
                self?.showPluginManager()
            }
        ))

        let panel = CustomBottomSheetViewController(title: "正在运行的脚本", items: items, layout: .list)
        present(panel, animated: false)
    }

    private func showScriptSubMenu(for script: UserScript) {
        var items: [CustomBottomSheetItem] = []

        let scriptCmds = activeTab.registeredCommands.filter { $0.scriptId == script.id }
        for cmd in scriptCmds {
            items.append(CustomBottomSheetItem(
                title: cmd.caption,
                handler: { [weak self] in
                    self?.activeTab.webView.evaluateJavaScript("window.__gm_invokeMenuCommand(\(cmd.cmdId))", completionHandler: nil)
                }
            ))
        }

        items.append(CustomBottomSheetItem(
            title: script.isEnabled ? "禁用该脚本" : "启用该脚本",
            handler: { [weak self] in
                var scripts = UserScriptStore.shared.loadScripts()
                if let idx = scripts.firstIndex(where: { $0.id == script.id }) {
                    scripts[idx].isEnabled = !script.isEnabled
                    UserScriptStore.shared.saveScripts(scripts)
                    self?.activeTab.reloadUserScripts()
                }
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "清除脚本缓存数据",
            isDestructive: true,
            handler: {
                ScriptDataStore.shared.clearDataForScript(scriptId: script.id)
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "编辑脚本代码",
            handler: { [weak self] in
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
            }
        ))

        let panel = CustomBottomSheetViewController(title: script.name, items: items, layout: .list)
        present(panel, animated: false)
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

        var items: [CustomBottomSheetItem] = []

        items.append(CustomBottomSheetItem(
            title: isFullscreen ? "退出全屏浏览" : "全屏浏览",
            handler: { [weak self] in
                guard let self = self else { return }
                self.setFullscreen(!self.isFullscreen)
            }
        ))

        let isEyeOn = EyeProtectionManager.shared.isEnabled
        items.append(CustomBottomSheetItem(
            title: isEyeOn ? "关闭护眼" : "护眼模式",
            handler: { [weak self] in
                EyeProtectionManager.shared.toggle(in: self?.view.window)
            }
        ))

        let currentUAItem = UserAgentStore.shared.getSelectedItem()
        items.append(CustomBottomSheetItem(
            title: "标识: \(currentUAItem.name)",
            handler: { [weak self] in
                self?.showUserAgentManager()
            }
        ))

        let isDesktop = currentUAItem.id == "default_mac"
        items.append(CustomBottomSheetItem(
            title: isDesktop ? "移动版" : "电脑版",
            handler: { [weak self] in
                let targetId = isDesktop ? "default_safari" : "default_mac"
                UserAgentStore.shared.setSelectedId(targetId)
                let newUA = UserAgentStore.shared.getSelectedUA()
                self?.activeTab.webView.customUserAgent = newUA
                self?.activeTab.webView.reload()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "清除数据与管理网站",
            isDestructive: true,
            handler: { [weak self] in
                self?.showCleanDataMenu()
            }
        ))

        let panel = CustomBottomSheetViewController(title: "选项", items: items, layout: .grid)
        present(panel, animated: false)
    }

    private func showUserAgentManager() {
        let manager = UserAgentManagerViewController()
        manager.onUASelected = { [weak self] newUA in
            self?.activeTab.webView.customUserAgent = newUA
            self?.activeTab.webView.reload()
        }
        let nav = UINavigationController(rootViewController: manager)
        present(nav, animated: true)
    }

    private func showCleanDataMenu() {
        let cleanVC = CleanDataSelectionViewController()
        cleanVC.onConfirmClean = { [weak self] options in
            self?.performCleanData(options: options)
        }
        cleanVC.onOpenWebsiteDataManager = { [weak self] in
            let manager = WebsiteDataManagerViewController()
            let nav = UINavigationController(rootViewController: manager)
            self?.present(nav, animated: true)
        }
        let nav = UINavigationController(rootViewController: cleanVC)
        present(nav, animated: true)
    }

    private func performCleanData(options: Set<CleanOption>) {
        let group = DispatchGroup()

        if options.contains(.cache) {
            group.enter()
            WebsiteCleaner.shared.cleanCacheOnly {
                group.leave()
            }
        }

        if options.contains(.loginAndData) {
            group.enter()
            WebsiteCleaner.shared.cleanUnprotectedLoginAndData {
                group.leave()
            }
        }

        if options.contains(.searchHistory) {
            SearchHistoryStore.shared.clearHistory()
        }

        if options.contains(.scriptData) {
            ScriptDataStore.shared.clearAllScriptData()
        }

        group.notify(queue: .main) { [weak self] in
            self?.showToastNotice("数据清理完成")
            self?.activeTab.webView.reload()
        }
    }
}
