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

class TouchButton: UIButton {
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)
    var hitTestInsets: UIEdgeInsets = .zero

    convenience init(type buttonType: UIButton.ButtonType) {
        self.init(frame: .zero)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupFeedback()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFeedback()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if hitTestInsets == .zero {
            return super.point(inside: point, with: event)
        }
        let enlargedBounds = bounds.inset(by: hitTestInsets)
        return enlargedBounds.contains(point)
    }

    private func setupFeedback() {
        addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
        addTarget(self, action: #selector(handleTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func handleTouchDown() {
        hapticGenerator.impactOccurred()
        UIView.animate(withDuration: 0.08) {
            self.transform = CGAffineTransform(scaleX: 0.90, y: 0.90)
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

    private let editingDimmingView = UIView()

    private let bottomPanel = UIView()
    private let addressShadowView = UIView()
    private let addressContainer = UIView()
    private let lockButton = TouchButton(type: .system)
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        EyeProtectionManager.shared.restoreState(in: view.window)
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

    private func makeSpacedThreeLinesIcon() -> UIImage {
        let size = CGSize(width: 20, height: 18)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setLineWidth(1.8)
            cg.setLineCap(.round)
            cg.setStrokeColor(UIColor.black.cgColor)

            let yOffsets: [CGFloat] = [2.0, 9.0, 16.0]
            for y in yOffsets {
                cg.move(to: CGPoint(x: 1.5, y: y))
                cg.addLine(to: CGPoint(x: 18.5, y: y))
            }
            cg.strokePath()
        }
        return img.withRenderingMode(.alwaysTemplate)
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

        editingDimmingView.translatesAutoresizingMaskIntoConstraints = false
        editingDimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        editingDimmingView.alpha = 0
        editingDimmingView.isHidden = true
        let dimmingTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        editingDimmingView.addGestureRecognizer(dimmingTap)

        bottomPanel.translatesAutoresizingMaskIntoConstraints = false
        bottomPanel.backgroundColor = themeBg
        bottomPanel.clipsToBounds = false

        addressShadowView.translatesAutoresizingMaskIntoConstraints = false
        addressShadowView.backgroundColor = .white
        addressShadowView.layer.cornerRadius = 22
        addressShadowView.layer.shadowColor = UIColor.black.cgColor
        addressShadowView.layer.shadowOpacity = 0.05
        addressShadowView.layer.shadowRadius = 8
        addressShadowView.layer.shadowOffset = CGSize(width: 0, height: 2)
        addressShadowView.clipsToBounds = false

        addressContainer.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.backgroundColor = .white
        addressContainer.layer.cornerRadius = 22
        addressContainer.clipsToBounds = true

        let longPressAddress = UILongPressGestureRecognizer(target: self, action: #selector(handleAddressLongPress(_:)))
        longPressAddress.minimumPressDuration = 0.4
        addressContainer.addGestureRecognizer(longPressAddress)

        lockButton.translatesAutoresizingMaskIntoConstraints = false
        lockButton.tintColor = .secondaryLabel
        lockButton.setImage(
            UIImage(
                systemName: "lock.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            ),
            for: .normal
        )
        lockButton.hitTestInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
        lockButton.addTarget(self, action: #selector(showSiteDomainSettings), for: .touchUpInside)

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.delegate = self
        addressField.placeholder = "搜索或输入网址"
        addressField.font = .systemFont(ofSize: 14, weight: .regular)
        addressField.textColor = .label
        addressField.textAlignment = .left
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
        configureToolbarButton(moreButton, imageName: "line.3.horizontal", action: #selector(showMoreMenu))
        configureToolbarButton(tabsButton, imageName: "square.on.square", action: #selector(showTabsManager))
        configureToolbarButton(pluginButton, imageName: "square.3.layers.3d", action: #selector(showPluginPanel))

        let longPressMore = UILongPressGestureRecognizer(target: self, action: #selector(handleMoreButtonLongPress(_:)))
        longPressMore.minimumPressDuration = 0.4
        moreButton.addGestureRecognizer(longPressMore)

        navigationStack.addArrangedSubview(backButton)
        navigationStack.addArrangedSubview(forwardButton)
        navigationStack.addArrangedSubview(moreButton)
        navigationStack.addArrangedSubview(tabsButton)
        navigationStack.addArrangedSubview(pluginButton)

        addressContainer.addSubview(lockButton)
        addressContainer.addSubview(addressField)
        addressContainer.addSubview(refreshButton)
        addressContainer.addSubview(clearButton)
        addressContainer.addSubview(progressView)

        bottomPanel.addSubview(addressShadowView)
        bottomPanel.addSubview(addressContainer)
        bottomPanel.addSubview(navigationStack)

        view.addSubview(webContainer)
        view.addSubview(homeView)
        view.addSubview(failureOverlayView)
        view.addSubview(editingDimmingView)
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

            editingDimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            editingDimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editingDimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editingDimmingView.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor),

            bottomPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomPanelBottomConstraint!,

            addressContainer.topAnchor.constraint(equalTo: bottomPanel.topAnchor, constant: 6),
            addressContainer.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor, constant: 16),
            addressContainer.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor, constant: -16),
            addressContainer.heightAnchor.constraint(equalToConstant: 44),

            addressShadowView.topAnchor.constraint(equalTo: addressContainer.topAnchor),
            addressShadowView.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor),
            addressShadowView.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor),
            addressShadowView.bottomAnchor.constraint(equalTo: addressContainer.bottomAnchor),

            lockButton.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor, constant: 12),
            lockButton.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            lockButton.widthAnchor.constraint(equalToConstant: 24),
            lockButton.heightAnchor.constraint(equalToConstant: 24),

            addressField.leadingAnchor.constraint(equalTo: lockButton.trailingAnchor, constant: 6),
            addressField.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -6),
            addressField.topAnchor.constraint(equalTo: addressContainer.topAnchor),
            addressField.bottomAnchor.constraint(equalTo: addressContainer.bottomAnchor),

            progressView.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: addressContainer.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2.5),

            refreshButton.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -12),
            refreshButton.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),

            clearButton.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -12),
            clearButton.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 24),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            navigationStack.topAnchor.constraint(equalTo: addressContainer.bottomAnchor, constant: 8),
            navigationStack.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor, constant: 16),
            navigationStack.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor, constant: -16),
            navigationStack.bottomAnchor.constraint(equalTo: bottomPanel.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            navigationStack.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    @objc private func handleMoreButtonLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showCleanDataMenu()
    }

    @objc private func handleAddressLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let urlText = activeTab.url?.absoluteString.removingPercentEncoding ?? activeTab.url?.absoluteString ?? addressField.text ?? ""
        guard !urlText.isEmpty else { return }

        UIPasteboard.general.string = urlText
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
        if imageName == "line.3.horizontal" {
            configuration.image = makeSpacedThreeLinesIcon()
        } else {
            configuration.image = UIImage(
                systemName: imageName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            )
        }
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)

        button.configuration = configuration
        button.backgroundColor = .clear
        button.layer.cornerRadius = 0
        button.layer.shadowOpacity = 0
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
        gesture.minimumPressDuration = 2.0
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
            let rawString = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            let hostString = url.host?.removingPercentEncoding ?? url.host ?? rawString
            addressField.text = hostString
        } else {
            showHomeUI()
        }

        updateUIState()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        resetProgress()

        let isClosingActiveTab = (index == activeTabIndex)
        let tab = tabs[index]
        tab.destroy()
        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabIndex = 0
            createNewTab(loadURL: nil)
            return
        }

        if isClosingActiveTab {
            activeTabIndex = min(index, tabs.count - 1)
            switchTab(to: activeTabIndex)
        } else {
            if index < activeTabIndex {
                activeTabIndex -= 1
            }
            updateUIState()
        }
    }

    private func closeAllTabs() {
        resetProgress()
        for tab in tabs {
            tab.destroy()
        }
        tabs.removeAll()
        activeTabIndex = 0
        createNewTab(loadURL: nil)
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
        addressField.text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
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
        let targetURL = tab.failedURL ?? tab.url
        failureURLLabel.text = targetURL?.absoluteString.removingPercentEncoding ?? targetURL?.absoluteString ?? ""
        if let err = tab.failureError as NSError? {
            failureTitleLabel.text = "无法连接服务器"
            failureReasonLabel.text = err.localizedDescription
        }
        let hostStr = targetURL?.host?.removingPercentEncoding ?? targetURL?.host ?? (targetURL?.absoluteString.removingPercentEncoding ?? targetURL?.absoluteString ?? "")
        addressField.text = hostStr
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
            if let url = URL(string: value) {
                return url
            }
            if let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: encoded) {
                return url
            }
            return nil
        }

        if value.contains(".") && !value.contains(" ") {
            let prefixed = "https://" + value
            if let url = URL(string: prefixed) {
                return url
            }
            if let encoded = prefixed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: encoded) {
                return url
            }
        }

        return SearchEngineStore.shared.currentEngine.searchURL(query: value)
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
                let rawString = url.absoluteString.removingPercentEncoding ?? url.absoluteString
                let hostString = url.host?.removingPercentEncoding ?? url.host ?? rawString
                addressField.text = hostString
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
            textField.text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        }

        navigationStack.isHidden = true
        updateAddressEditingAppearance()

        editingDimmingView.isHidden = false
        UIView.animate(withDuration: 0.2) {
            self.editingDimmingView.alpha = 1
        }

        DispatchQueue.main.async {
            textField.selectAll(nil)
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if let url = activeTab.url {
            let rawString = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            textField.text = url.host?.removingPercentEncoding ?? url.host ?? rawString
        } else if textField.text?.isEmpty == true {
            textField.text = ""
        }

        navigationStack.isHidden = false
        updateAddressEditingAppearance()

        UIView.animate(withDuration: 0.2, animations: {
            self.editingDimmingView.alpha = 0
        }) { _ in
            self.editingDimmingView.isHidden = true
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
        let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let options = UIView.AnimationOptions(rawValue: curve << 16)

        bottomPanelBottomConstraint?.constant = -overlap

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
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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

            if let currentURL = activeTab.webView.url, currentURL.absoluteString != "about:blank", currentURL != activeTab.failedURL {
                activeTab.url = currentURL
                let rawString = currentURL.absoluteString.removingPercentEncoding ?? currentURL.absoluteString
                addressField.text = currentURL.host?.removingPercentEncoding ?? currentURL.host ?? rawString
                updateUIState()
                return
            }

            if activeTab.webView.canGoBack {
                activeTab.webView.goBack()
                updateUIState()
                return
            }

            if let originURL = originURL {
                load(url: originURL)
                return
            }

            if let sourceID = sourceID,
               let sourceIndex = tabs.firstIndex(where: { $0.id == sourceID }) {
                let closingIndex = activeTabIndex
                closeTab(at: closingIndex)
                switchTab(to: sourceIndex)
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
            guard let self = self else { return }
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

            vc.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(self.dismissModalVC))
            let nav = UINavigationController(rootViewController: vc)
            self.present(nav, animated: true)
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
        if #available(iOS 15.0, *) {
            if let presentation = panel.sheetPresentationController {
                presentation.detents = [.medium(), .large()]
                presentation.prefersGrabberVisible = true
                presentation.preferredCornerRadius = 24
            }
        }
        present(panel, animated: true)
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
            isDestructive: false,
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
        if #available(iOS 15.0, *) {
            if let presentation = panel.sheetPresentationController {
                presentation.detents = [.medium(), .large()]
                presentation.prefersGrabberVisible = true
                presentation.preferredCornerRadius = 24
            }
        }
        present(panel, animated: true)
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
            guard let self = self else {
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

            manager.onClearAllTabs = { [weak self] in
                self?.closeAllTabs()
            }

            manager.onNewTab = { [weak self] in
                self?.createNewTab(loadURL: nil)
            }

            let navigationController = UINavigationController(rootViewController: manager)
            navigationController.modalPresentationStyle = .pageSheet
            self.present(navigationController, animated: true)
        }
    }

    private func showEyeProtectionLevelPicker() {
        let alert = UIAlertController(title: "护眼模式强度", message: nil, preferredStyle: .actionSheet)

        for level in EyeProtectionManager.Level.allCases {
            alert.addAction(UIAlertAction(title: level.title, style: .default) { [weak self] _ in
                EyeProtectionManager.shared.setLevel(level, in: self?.view.window)
            })
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showSearchEnginePicker() {
        let alert = UIAlertController(title: "选择默认搜索引擎", message: nil, preferredStyle: .actionSheet)
        for engine in SearchEngine.allCases {
            let isCurrent = engine == SearchEngineStore.shared.currentEngine
            let title = isCurrent ? "\(engine.name) ✓" : engine.name
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                SearchEngineStore.shared.currentEngine = engine
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
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
            },
            longPressHandler: { [weak self] in
                self?.showEyeProtectionLevelPicker()
            }
        ))

        let currentEngine = SearchEngineStore.shared.currentEngine
        items.append(CustomBottomSheetItem(
            title: "搜索引擎: \(currentEngine.name)",
            handler: { [weak self] in
                self?.showSearchEnginePicker()
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
                guard let self = self else { return }
                let targetId = isDesktop ? "default_safari" : "default_mac"
                UserAgentStore.shared.setSelectedId(targetId)
                let newUA = UserAgentStore.shared.getSelectedUA()
                self.activeTab.webView.customUserAgent = newUA
                self.activeTab.webView.configuration.defaultWebpagePreferences.preferredContentMode = isDesktop ? .mobile : .desktop
                self.activeTab.webView.reloadFromOrigin()
            }
        ))

        items.append(CustomBottomSheetItem(
            title: "清除数据与管理网站",
            isDestructive: false,
            handler: { [weak self] in
                self?.showCleanDataMenu()
            }
        ))

        let panel = CustomBottomSheetViewController(title: "选项", items: items, layout: .grid)
        if #available(iOS 15.0, *) {
            if let presentation = panel.sheetPresentationController {
                presentation.detents = [.medium(), .large()]
                presentation.prefersGrabberVisible = true
                presentation.preferredCornerRadius = 24
            }
        }
        present(panel, animated: true)
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
        cleanVC.onConfirmClean = { [weak self] options, completion in
            guard let self = self else {
                completion()
                return
            }
            self.performCleanData(options: options, completion: completion)
        }
        cleanVC.onOpenWebsiteDataManager = { [weak self] in
            let manager = WebsiteDataManagerViewController()
            let nav = UINavigationController(rootViewController: manager)
            self?.present(nav, animated: true)
        }
        let nav = UINavigationController(rootViewController: cleanVC)
        present(nav, animated: true)
    }

    private func performCleanData(options: Set<CleanOption>, completion: @escaping () -> Void) {
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
            self?.activeTab.webView.reload()
            completion()
        }
    }
}
