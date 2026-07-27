import UIKit
import WebKit

protocol TabItemDelegate: AnyObject {
    func tabDidUpdate(_ tab: TabItem)
    func tabDidFail(_ tab: TabItem, error: Error)
    func tabRequestNewTab(url: URL)
    func tabProcessTerminated(_ tab: TabItem)
    func tabRequestGoBack(_ tab: TabItem)
}

final class TabItem: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id = UUID()
    let webView: WKWebView
    var title = "主页"
    var url: URL?
    var isLoading = false
    var snapshot: UIImage?
    var registeredCommands: [RegisteredMenuCommand] = []

    var sourceTabID: UUID?
    var failedURL: URL?
    var failureError: Error?
    var isDisplayingFailurePage = false
    var previousURL: URL?
    var failureOriginURL: URL?
    private var pendingRestoreURL: URL?

    private var hasInjectedScriptsForCurrentPage = false
    private var isLoadingFailureDocument = false
    private var navigationActionURL: URL?
    weak var delegate: TabItemDelegate?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true

        let selectedItem = UserAgentStore.shared.getSelectedItem()
        let isDesktop = selectedItem.category == .desktop || selectedItem.id == "default_mac"
        configuration.defaultWebpagePreferences.preferredContentMode = isDesktop ? .desktop : .mobile

        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.customUserAgent = UserAgentStore.shared.getSelectedUA()

        AdBlockManager.shared.attach(to: webView)
        userContentController.add(self, name: "GM")
        userContentController.add(self, name: "VideoHelper")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.isOpaque = true
    }

    deinit {
        destroy()
    }

    func destroy() {
        AdBlockManager.shared.detach(from: webView)
        delegate = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.evaluateJavaScript("""
        (function(){
            try {
                var media = document.querySelectorAll('audio, video');
                for(var i=0; i<media.length; i++){
                    media[i].pause();
                    media[i].src = '';
                    media[i].load();
                }
            } catch(e){}
        })();
        """, completionHandler: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "GM")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "VideoHelper")
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        webView.removeFromSuperview()
        snapshot = nil
    }

    func clearFailureState() {
        isDisplayingFailurePage = false
        failedURL = nil
        failureError = nil
        failureOriginURL = nil
    }

    func restoreSession(url: URL?, title: String) {
        self.url = url
        self.title = title.isEmpty ? (url?.host ?? "新标签页") : title
        self.pendingRestoreURL = url
        self.isDisplayingFailurePage = false
        self.failedURL = nil
        self.failureError = nil
        self.failureOriginURL = nil
    }

    func consumePendingRestoreURL() -> URL? {
        let url = pendingRestoreURL
        pendingRestoreURL = nil
        return url
    }

    func sessionURL() -> URL? {
        if isDisplayingFailurePage {
            return failedURL ?? url
        }
        return pendingRestoreURL ?? url
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "VideoHelper", let body = message.body as? [String: Any], let action = body["action"] as? String {
            if action == "openCustomPlayer", let urlStr = body["url"] as? String, let videoURL = URL(string: urlStr) {
                DispatchQueue.main.async {
                    let playerVC = CustomVideoPlayerViewController(videoURL: videoURL, title: self.title)
                    if let topVC = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                        var presenter = topVC
                        while let presented = presenter.presentedViewController {
                            presenter = presented
                        }
                        presenter.present(playerVC, animated: true)
                    }
                }
            }
            return
        }

        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }

        if action == "goBackAction" {
            delegate?.tabRequestGoBack(self)
        } else if action == "registerMenuCommand", let cmdId = body["id"] as? Int, let caption = body["caption"] as? String {
            let scriptId = (body["scriptId"] as? String) ?? ""
            registeredCommands.removeAll { $0.cmdId == cmdId || ($0.scriptId == scriptId && $0.caption == caption) }
            registeredCommands.append(RegisteredMenuCommand(scriptId: scriptId, cmdId: cmdId, caption: caption))
        } else if action == "unregisterMenuCommand", let cmdId = body["id"] as? Int {
            registeredCommands.removeAll { $0.cmdId == cmdId }
        } else if action == "setValue", let scriptId = body["scriptId"] as? String, let name = body["name"] as? String, let value = body["value"] {
            ScriptDataStore.shared.setValue(scriptId: scriptId, name: name, value: value)
        } else if action == "deleteValue", let scriptId = body["scriptId"] as? String, let name = body["name"] as? String {
            ScriptDataStore.shared.deleteValue(scriptId: scriptId, name: name)
        } else if action == "xhr", let reqId = body["id"] as? String, let urlString = body["url"] as? String, let targetURL = URL(string: urlString) {
            let method = (body["method"] as? String) ?? "GET"
            var request = URLRequest(url: targetURL)
            request.httpMethod = method

            if let headers = body["headers"] as? [String: String] {
                for (k, v) in headers {
                    request.setValue(v, forHTTPHeaderField: k)
                }
            }

            if let dataString = body["data"] as? String {
                request.httpBody = dataString.data(using: .utf8)
            }

            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        let errData = (try? JSONSerialization.data(withJSONObject: [error.localizedDescription], options: [])) ?? Data()
                        let errJSON = String(data: errData, encoding: .utf8) ?? "[\"\"]"
                        let unwrappedErr = String(errJSON.dropFirst().dropLast())
                        self?.webView.evaluateJavaScript("window.__gm_handleXhrError('\(reqId)', \(unwrappedErr))", completionHandler: nil)
                        return
                    }

                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                    let responseText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let jsonTextData = try? JSONSerialization.data(withJSONObject: [responseText], options: [])
                    let jsonText = jsonTextData.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                    let unwrappedText = String(jsonText.dropFirst().dropLast())

                    self?.webView.evaluateJavaScript("window.__gm_handleXhrResponse('\(reqId)', \(statusCode), \(unwrappedText))", completionHandler: nil)
                }
            }
            task.resume()
        }
    }

    private func applyDesktopViewAdaptationIfNeeded() {
        let selectedItem = UserAgentStore.shared.getSelectedItem()
        let isDesktop = selectedItem.category == .desktop || selectedItem.id == "default_mac"
        guard isDesktop else { return }

        let js = """
        (function() {
            try {
                var meta = document.querySelector('meta[name="viewport"]');
                if (!meta) {
                    meta = document.createElement('meta');
                    meta.name = 'viewport';
                    (document.head || document.documentElement).appendChild(meta);
                }
                var screenW = window.screen.width || 390;
                var targetW = 1024;
                var scale = (screenW / targetW).toFixed(2);
                meta.content = 'width=' + targetW + ', initial-scale=' + scale + ', minimum-scale=0.1, maximum-scale=5.0, user-scalable=yes';

                var styleId = '__desktop_overflow_fix__';
                if (!document.getElementById(styleId)) {
                    var style = document.createElement('style');
                    style.id = styleId;
                    style.type = 'text/css';
                    style.innerHTML = `
                        html { overflow-x: auto !important; }
                        body { max-width: 100% !important; overflow-x: auto !important; }
                        video, iframe, object, embed { max-width: 100% !important; }
                        .player-container, #player, .video-player, .html5-video-player { max-width: 100% !important; }
                    `;
                    (document.head || document.documentElement).appendChild(style);
                }
            } catch(e) {}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func injectInlineVideoHelper() {
        let currentHost = url?.host ?? ""
        let isPopoutEnabled = DomainSettingsStore.shared.getBool(domain: currentHost, setting: "videoPopout", defaultVal: true)
        guard isPopoutEnabled else { return }

        let js = """
        (function() {
            try {
                var btnId = '__sniff_floating_btn__';

                function extractVideoSrc(v) {
                    if (v.currentSrc && v.currentSrc.indexOf('blob:') !== 0) return v.currentSrc;
                    if (v.src && v.src.indexOf('blob:') !== 0) return v.src;
                    var sources = v.querySelectorAll('source');
                    for (var i = 0; i < sources.length; i++) {
                        var s = sources[i].src;
                        if (s && s.indexOf('blob:') !== 0) return s;
                    }
                    return null;
                }

                function createFloatingBtn(src) {
                    if (document.getElementById(btnId)) return;
                    var btn = document.createElement('div');
                    btn.id = btnId;
                    btn.innerHTML = `
                        <svg width="22" height="22" viewBox="0 0 24 24" fill="white" style="margin-left: 3px; pointer-events: none;"><path d="M8 5v14l11-7z"/></svg>
                        <div style="position: absolute; top: 1px; right: 1px; width: 10px; height: 10px; background-color: #FF3B30; border-radius: 50%; pointer-events: none;"></div>
                    `;
                    btn.style.cssText = `
                        position: fixed;
                        right: 16px;
                        bottom: 120px;
                        width: 50px;
                        height: 50px;
                        border-radius: 50%;
                        background: #4299E1;
                        box-shadow: 0 4px 14px rgba(0,0,0,0.3);
                        z-index: 999999;
                        display: flex;
                        align-items: center;
                        justify-content: center;
                        cursor: pointer;
                        user-select: none;
                        -webkit-user-select: none;
                        -webkit-tap-highlight-color: transparent;
                    `;

                    var isDragging = false;
                    var startX, startY, initialX, initialY;

                    btn.addEventListener('touchstart', function(e) {
                        var touch = e.touches[0];
                        startX = touch.clientX;
                        startY = touch.clientY;
                        var rect = btn.getBoundingClientRect();
                        initialX = rect.left;
                        initialY = rect.top;
                        isDragging = false;
                    }, {passive: true});

                    btn.addEventListener('touchmove', function(e) {
                        var touch = e.touches[0];
                        var dx = touch.clientX - startX;
                        var dy = touch.clientY - startY;
                        if (Math.abs(dx) > 5 || Math.abs(dy) > 5) {
                            isDragging = true;
                        }
                        if (isDragging) {
                            btn.style.left = (initialX + dx) + 'px';
                            btn.style.top = (initialY + dy) + 'px';
                            btn.style.right = 'auto';
                            btn.style.bottom = 'auto';
                        }
                    }, {passive: true});

                    btn.addEventListener('touchend', function(e) {
                        if (!isDragging) {
                            try {
                                window.webkit.messageHandlers.VideoHelper.postMessage({
                                    action: 'openCustomPlayer',
                                    url: src
                                });
                            } catch(err) {}
                        }
                    });

                    (document.body || document.documentElement).appendChild(btn);
                }

                function sniffVideos() {
                    var videos = document.querySelectorAll('video');
                    for (var i = 0; i < videos.length; i++) {
                        var src = extractVideoSrc(videos[i]);
                        if (src) {
                            createFloatingBtn(src);
                            break;
                        }
                    }
                }

                sniffVideos();

                var observer = new MutationObserver(function() {
                    sniffVideos();
                });

                observer.observe(document.documentElement || document.body, {
                    childList: true,
                    subtree: true
                });
            } catch(e) {}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func injectAndRunUserScripts() {
        applyDesktopViewAdaptationIfNeeded()
        injectInlineVideoHelper()

        let currentUrlStr = url?.absoluteString ?? ""
        let matchingScripts = UserScriptStore.shared.loadScripts().filter {
            UserScriptStore.shared.isScriptMatching(script: $0, urlString: currentUrlStr)
        }

        let gmPolyfillBase = """
        if (!window.__gm_polyfilled__) {
            window.__gm_polyfilled__ = true;
            window.unsafeWindow = window;
            window.__gm_menu_commands__ = window.__gm_menu_commands__ || {};

            window.__gm_invokeMenuCommand = function(id) {
                var fn = window.__gm_menu_commands__[id];
                if (typeof fn === 'function') { fn(); }
            };
            window.GM_addStyle = function(css) {
                var style = document.createElement('style');
                style.type = 'text/css';
                style.appendChild(document.createTextNode(css));
                (document.head || document.documentElement).appendChild(style);
                return style;
            };
            window.GM_log = function(msg) {
                console.log('[Tampermonkey]', msg);
            };
            window.GM_xmlhttpRequest = function(opts) {
                var id = 'xhr_' + Math.random().toString(36).substr(2, 9);
                window.__gm_xhr_callbacks__ = window.__gm_xhr_callbacks__ || {};
                window.__gm_xhr_callbacks__[id] = opts;
                try {
                    window.webkit.messageHandlers.GM.postMessage({
                        action: 'xhr',
                        id: id,
                        method: opts.method || 'GET',
                        url: opts.url,
                        headers: opts.headers || {},
                        data: opts.data || null,
                        timeout: opts.timeout || 0
                    });
                } catch(e) {
                    if (opts.onerror) opts.onerror({ status: 0, responseText: e.toString() });
                }
            };
            window.__gm_handleXhrResponse = function(id, status, text) {
                var opts = window.__gm_xhr_callbacks__[id];
                if (!opts) return;
                delete window.__gm_xhr_callbacks__[id];
                var res = {
                    status: status,
                    statusText: status === 200 ? 'OK' : 'Error',
                    responseText: text,
                    response: text,
                    readyState: 4,
                    finalUrl: opts.url
                };
                if (opts.onload) opts.onload(res);
                if (opts.onreadystatechange) opts.onreadystatechange(res);
            };
            window.__gm_handleXhrError = function(id, errorText) {
                var opts = window.__gm_xhr_callbacks__[id];
                if (!opts) return;
                delete window.__gm_xhr_callbacks__[id];
                var res = { status: 0, statusText: errorText, responseText: errorText, response: errorText, readyState: 4 };
                if (opts.onerror) opts.onerror(res);
            };
        }
        """

        var fullJS = gmPolyfillBase + "\n"
        for script in matchingScripts {
            let valuesJSON = ScriptDataStore.shared.getAllValuesJSON(scriptId: script.id)
            fullJS += """
            (function(scriptId, initialValues) {
                var values = initialValues || {};
                var GM_setValue = function(name, val) {
                    values[name] = val;
                    try {
                        window.webkit.messageHandlers.GM.postMessage({
                            action: 'setValue',
                            scriptId: scriptId,
                            name: name,
                            value: val
                        });
                    } catch(e) {}
                };
                var GM_getValue = function(name, defaultValue) {
                    return (name in values) ? values[name] : defaultValue;
                };
                var GM_deleteValue = function(name) {
                    delete values[name];
                    try {
                        window.webkit.messageHandlers.GM.postMessage({
                            action: 'deleteValue',
                            scriptId: scriptId,
                            name: name
                        });
                    } catch(e) {}
                };
                var GM_registerMenuCommand = function(caption, commandFunc) {
                    var id = Math.floor(Math.random() * 1000000);
                    window.__gm_menu_commands__[id] = commandFunc;
                    try {
                        window.webkit.messageHandlers.GM.postMessage({
                            action: 'registerMenuCommand',
                            id: id,
                            scriptId: scriptId,
                            caption: caption
                        });
                    } catch(e) {}
                    return id;
                };
                var GM_unregisterMenuCommand = function(id) {
                    delete window.__gm_menu_commands__[id];
                    try {
                        window.webkit.messageHandlers.GM.postMessage({
                            action: 'unregisterMenuCommand',
                            id: id
                        });
                    } catch(e) {}
                };
                var GM_xmlhttpRequest = window.GM_xmlhttpRequest;
                var GM = {
                    getValue: function(k, d) { return Promise.resolve(GM_getValue(k, d)); },
                    setValue: function(k, v) { GM_setValue(k, v); return Promise.resolve(); },
                    deleteValue: function(k) { GM_deleteValue(k); return Promise.resolve(); },
                    xmlHttpRequest: function(opts) {
                        return new Promise(function(resolve, reject) {
                            var origOnload = opts.onload;
                            var origOnerror = opts.onerror;
                            opts.onload = function(res) {
                                if (origOnload) origOnload(res);
                                resolve(res);
                            };
                            opts.onerror = function(res) {
                                if (origOnerror) origOnerror(res);
                                reject(res);
                            };
                            GM_xmlhttpRequest(opts);
                        });
                    },
                    addStyle: window.GM_addStyle,
                    registerMenuCommand: function(c, f) { return Promise.resolve(GM_registerMenuCommand(c, f)); }
                };

                try {
                    \(script.code)
                } catch(e) {
                    console.error('[UserScript Error]', e);
                }
            })('\(script.id)', \(valuesJSON));
            \n
            """
        }

        webView.evaluateJavaScript(fullJS, completionHandler: nil)
    }

    func reloadUserScripts() {
        hasInjectedScriptsForCurrentPage = false
        registeredCommands.removeAll()
        webView.reload()
    }

    func updateSnapshot(completion: (() -> Void)? = nil) {
        guard webView.bounds.width > 0, webView.bounds.height > 0, !webView.isLoading else {
            completion?()
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds

        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            if let image = image {
                self?.snapshot = image
            }
            completion?()
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let targetURL = navigationAction.request.url {
            delegate?.tabRequestNewTab(url: targetURL)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        if !isLoadingFailureDocument {
            isDisplayingFailurePage = false
        }
        hasInjectedScriptsForCurrentPage = false
        registeredCommands.removeAll()
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if !isDisplayingFailurePage, let currentURL = webView.url, !currentURL.absoluteString.contains("about:blank") {
            if previousURL != currentURL {
                previousURL = url
            }
            url = currentURL
            title = webView.title ?? url?.host ?? "新标签页"
        }
        applyDesktopViewAdaptationIfNeeded()
        injectInlineVideoHelper()
        if !hasInjectedScriptsForCurrentPage {
            hasInjectedScriptsForCurrentPage = true
            injectAndRunUserScripts()
        }
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if !isDisplayingFailurePage {
            url = webView.url
            title = webView.title ?? url?.host ?? "新标签页"
        }
        applyDesktopViewAdaptationIfNeeded()
        injectInlineVideoHelper()
        if !hasInjectedScriptsForCurrentPage {
            hasInjectedScriptsForCurrentPage = true
            injectAndRunUserScripts()
        }
        DispatchQueue.main.async { [weak webView] in
            webView?.setNeedsLayout()
            webView?.layoutIfNeeded()
        }
        updateSnapshot()
        delegate?.tabDidUpdate(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        delegate?.tabProcessTerminated(self)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        if shouldIgnoreNavigationError(error) {
            delegate?.tabDidUpdate(self)
            return
        }
        isDisplayingFailurePage = true
        failedURL = navigationActionURL ?? webView.url
        failureError = error
        delegate?.tabDidFail(self, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        if shouldIgnoreNavigationError(error) {
            delegate?.tabDidUpdate(self)
            return
        }
        isDisplayingFailurePage = true
        failedURL = navigationActionURL ?? webView.url
        failureError = error
        delegate?.tabDidFail(self, error: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let targetURL = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }

        navigationActionURL = targetURL

        let selectedItem = UserAgentStore.shared.getSelectedItem()
        let isDesktopMode = selectedItem.category == .desktop || selectedItem.id == "default_mac"
        preferences.preferredContentMode = isDesktopMode ? .desktop : .mobile

        let scheme = targetURL.scheme?.lowercased() ?? ""

        if ["http", "https"].contains(scheme),
           navigationAction.targetFrame != nil,
           targetURL != url {
            failureOriginURL = url
        }

        if targetURL.path.hasSuffix(".user.js") || targetURL.absoluteString.hasSuffix(".user.js") {
            decisionHandler(.cancel, preferences)
            NotificationCenter.default.post(
                name: NSNotification.Name("InstallUserScriptNotification"),
                object: targetURL
            )
            return
        }

        if ["http", "https", "about", "data", "blob"].contains(scheme) {
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel, preferences)
                delegate?.tabRequestNewTab(url: targetURL)
                return
            }

            decisionHandler(.allow, preferences)
            return
        }

        decisionHandler(.cancel, preferences)

        if scheme == "intent", let fallbackURL = fallbackURL(from: targetURL) {
            webView.load(URLRequest(url: fallbackURL))
            return
        }

        UIApplication.shared.open(targetURL, options: [:], completionHandler: nil)
    }

    private func shouldIgnoreNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            return true
        }

        if nsError.domain == WKError.errorDomain {
            if nsError.code == WKError.Code.webContentProcessTerminated.rawValue {
                return true
            }
        }

        return false
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
