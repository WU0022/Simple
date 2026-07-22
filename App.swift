import UIKit
import WebKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
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

final class BrowserViewController: UIViewController, WKNavigationDelegate, UITextFieldDelegate {
    private let homeURL = URL(string: "https://www.google.com")!
    private let webView: WKWebView
    private let addressContainer = UIView()
    private let addressField = UITextField()
    private let goButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let toolbar = UIToolbar()
    private let backButton = UIBarButtonItem()
    private let forwardButton = UIBarButtonItem()
    private let reloadButton = UIBarButtonItem()
    private let homeButton = UIBarButtonItem()
    private let shareButton = UIBarButtonItem()
    private let moreButton = UIBarButtonItem()
    private var progressObservation: NSKeyValueObservation?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureInterface()
        configureWebView()
        configureProgressObservation()
        load(url: homeURL)
    }

    deinit {
        progressObservation?.invalidate()
    }

    private func configureInterface() {
        view.backgroundColor = .systemBackground

        addressContainer.translatesAutoresizingMaskIntoConstraints = false
        addressContainer.backgroundColor = .secondarySystemBackground
        addressContainer.layer.cornerRadius = 14
        addressContainer.clipsToBounds = true

        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.delegate = self
        addressField.placeholder = "搜索或输入网址"
        addressField.font = .systemFont(ofSize: 18)
        addressField.textColor = .label
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.textContentType = .URL

        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        searchIcon.tintColor = .secondaryLabel
        searchIcon.contentMode = .center
        searchIcon.frame = CGRect(x: 0, y: 0, width: 42, height: 42)
        addressField.leftView = searchIcon
        addressField.leftViewMode = .always

        goButton.translatesAutoresizingMaskIntoConstraints = false
        goButton.setTitle("前往", for: .normal)
        goButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        goButton.addTarget(self, action: #selector(handleGo), for: .touchUpInside)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = .clear
        progressView.alpha = 0

        webView.translatesAutoresizingMaskIntoConstraints = false

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.barTintColor = .systemBackground
        toolbar.tintColor = .systemBlue
        toolbar.isTranslucent = false

        backButton.image = UIImage(systemName: "chevron.backward")
        backButton.style = .plain
        backButton.target = self
        backButton.action = #selector(goBack)

        forwardButton.image = UIImage(systemName: "chevron.forward")
        forwardButton.style = .plain
        forwardButton.target = self
        forwardButton.action = #selector(goForward)

        reloadButton.image = UIImage(systemName: "arrow.clockwise")
        reloadButton.style = .plain
        reloadButton.target = self
        reloadButton.action = #selector(reloadOrStop)

        homeButton.image = UIImage(systemName: "house")
        homeButton.style = .plain
        homeButton.target = self
        homeButton.action = #selector(goHome)

        shareButton.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.style = .plain
        shareButton.target = self
        shareButton.action = #selector(sharePage)

        moreButton.image = UIImage(systemName: "ellipsis.circle")
        moreButton.style = .plain
        moreButton.target = self
        moreButton.action = #selector(showMoreMenu)

        toolbar.setItems([
            backButton,
            flexibleSpace(),
            forwardButton,
            flexibleSpace(),
            homeButton,
            flexibleSpace(),
            reloadButton,
            flexibleSpace(),
            shareButton,
            flexibleSpace(),
            moreButton
        ], animated: false)

        view.addSubview(addressContainer)
        addressContainer.addSubview(addressField)
        view.addSubview(goButton)
        view.addSubview(progressView)
        view.addSubview(webView)
        view.addSubview(toolbar)

        NSLayoutConstraint.activate([
            addressContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            addressContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            addressContainer.heightAnchor.constraint(equalToConstant: 48),

            addressField.leadingAnchor.constraint(equalTo: addressContainer.leadingAnchor, constant: 4),
            addressField.trailingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: -8),
            addressField.topAnchor.constraint(equalTo: addressContainer.topAnchor),
            addressField.bottomAnchor.constraint(equalTo: addressContainer.bottomAnchor),

            goButton.leadingAnchor.constraint(equalTo: addressContainer.trailingAnchor, constant: 10),
            goButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            goButton.centerYAnchor.constraint(equalTo: addressContainer.centerYAnchor),
            goButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),

            progressView.topAnchor.constraint(equalTo: addressContainer.bottomAnchor, constant: 8),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 3),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 50),

            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: toolbar.topAnchor)
        ])
    }

    private func configureWebView() {
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.keyboardDismissMode = .interactive
    }

    private func configureProgressObservation() {
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.progressView.alpha = 1
                self.progressView.setProgress(Float(webView.estimatedProgress), animated: true)
            }
        }
    }

    private func flexibleSpace() -> UIBarButtonItem {
        UIBarButtonItem(systemItem: .flexibleSpace)
    }

    private func load(url: URL) {
        addressField.text = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    private func updateNavigationState() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        shareButton.isEnabled = webView.url != nil
        reloadButton.image = UIImage(systemName: webView.isLoading ? "xmark" : "arrow.clockwise")
    }

    private func destinationURL(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else {
            return nil
        }

        if value.contains(" ") || !looksLikeAddress(value) {
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: value)]
            return components?.url
        }

        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return URL(string: value)
        }

        return URL(string: "https://\(value)")
    }

    private func looksLikeAddress(_ value: String) -> Bool {
        if value.localizedCaseInsensitiveCompare("localhost") == .orderedSame {
            return true
        }

        if value.contains(".") || value.contains(":") {
            return true
        }

        return false
    }

    private func showLoadError(_ error: Error) {
        let nsError = error as NSError

        guard nsError.code != NSURLErrorCancelled else {
            return
        }

        let alert = UIAlertController(
            title: "页面无法打开",
            message: nsError.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        handleGo()
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url {
            addressField.text = url.absoluteString
        }

        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            addressField.text = url.absoluteString
        }

        updateNavigationState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.webView.isLoading else {
                return
            }

            UIView.animate(withDuration: 0.2) {
                self.progressView.alpha = 0
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        updateNavigationState()
        showLoadError(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        updateNavigationState()
        showLoadError(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    @objc private func handleGo() {
        guard let text = addressField.text, let url = destinationURL(from: text) else {
            return
        }

        addressField.resignFirstResponder()
        load(url: url)
    }

    @objc private func goBack() {
        webView.goBack()
    }

    @objc private func goForward() {
        webView.goForward()
    }

    @objc private func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }

        updateNavigationState()
    }

    @objc private func goHome() {
        load(url: homeURL)
    }

    @objc private func sharePage() {
        guard let url = webView.url else {
            return
        }

        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        present(controller, animated: true)
    }

    @objc private func showMoreMenu() {
        let controller = UIAlertController(title: "更多功能", message: nil, preferredStyle: .actionSheet)

        if let url = webView.url {
            controller.addAction(UIAlertAction(title: "在 Safari 中打开", style: .default) { _ in
                UIApplication.shared.open(url)
            })

            controller.addAction(UIAlertAction(title: "复制当前链接", style: .default) { _ in
                UIPasteboard.general.url = url
            })
        }

        controller.addAction(UIAlertAction(title: "清除浏览数据", style: .destructive) { [weak self] _ in
            self?.clearBrowsingData()
        })

        controller.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(controller, animated: true)
    }

    private func clearBrowsingData() {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        WKWebsiteDataStore.default().removeData(
            ofTypes: dataTypes,
            modifiedSince: .distantPast
        ) { [weak self] in
            self?.webView.reload()
        }
    }
}
