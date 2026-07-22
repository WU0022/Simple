import UIKit
import WebKit

struct UserScript: Codable {
    var id: String
    var name: String
    var matchPattern: String
    var code: String
    var isEnabled: Bool
}

final class CookieLockStore {
    static let shared = CookieLockStore()
    private let key = "locked_cookie_domains_v1"

    private init() {}

    func getLockedDomains() -> [String] {
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func isLocked(domain: String) -> Bool {
        let locked = getLockedDomains()
        let cleanDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return locked.contains { lockedDomain in
            cleanDomain == lockedDomain || cleanDomain.hasSuffix("." + lockedDomain)
        }
    }

    func toggleLock(domain: String) {
        var locked = getLockedDomains()
        let cleanDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if locked.contains(cleanDomain) {
            locked.removeAll { $0 == cleanDomain }
        } else {
            locked.append(cleanDomain)
        }
        UserDefaults.standard.set(locked, forKey: key)
    }
}

final class SearchHistoryStore {
    static let shared = SearchHistoryStore()
    private let key = "browser_search_history_v1"

    private init() {}

    func getHistory() -> [String] {
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func addHistory(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = getHistory()
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        UserDefaults.standard.set(history, forKey: key)
    }

    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

final class UserScriptStore {
    static let shared = UserScriptStore()
    private let key = "user_tampermonkey_scripts_v4"

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
        var nameMap: [String: String] = [:]
        var matches: [String] = []

        let lines = code.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { continue }
            let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard content.hasPrefix("@") else { continue }

            let components = content.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard components.count >= 2 else { continue }

            let tag = components[0]
            let val = components.dropFirst().joined(separator: " ")

            if tag.hasPrefix("@name") {
                nameMap[tag] = val
            } else if tag == "@match" || tag == "@include" {
                matches.append(val)
            }
        }

        let preferredName = nameMap["@name:zh-CN"] ?? nameMap["@name:zh"] ?? nameMap["@name:zh-TW"] ?? nameMap["@name"] ?? "未命名脚本"
        let preferredMatch = matches.first ?? "*"

        return (preferredName, preferredMatch)
    }

    func isScriptMatching(script: UserScript, urlString: String) -> Bool {
        guard script.isEnabled else { return false }
        if script.matchPattern == "*" || script.matchPattern.isEmpty { return true }
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return true }
        let pattern = script.matchPattern.lowercased()
            .replacingOccurrences(of: "*://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: "/").first ?? script.matchPattern
        let domainPattern = pattern.replacingOccurrences(of: "*.", with: "").replacingOccurrences(of: "*", with: "")
        if domainPattern.isEmpty { return true }
        return host.contains(domainPattern) || domainPattern.contains(host)
    }
}

struct RegisteredMenuCommand {
    let scriptId: String
    let cmdId: Int
    let caption: String
}

protocol TabItemDelegate: AnyObject {
    func tabDidUpdate(_ tab: TabItem)
    func tabDidFail(_ tab: TabItem, error: Error)
}

final class TabItem: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id = UUID()
    let webView: WKWebView
    var title = "主页"
    var url: URL?
    var isLoading = false
    var snapshot: UIImage?
    var registeredCommands: [RegisteredMenuCommand] = []

    weak var delegate: TabItemDelegate?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        userContentController.add(self, name: "GM")

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.backgroundColor = .systemBackground
        webView.isOpaque = true
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "GM")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }

        if action == "registerMenuCommand", let cmdId = body["id"] as? Int, let caption = body["caption"] as? String {
            let scriptId = (body["scriptId"] as? String) ?? ""
            registeredCommands.removeAll { $0.cmdId == cmdId || ($0.scriptId == scriptId && $0.caption == caption) }
            registeredCommands.append(RegisteredMenuCommand(scriptId: scriptId, cmdId: cmdId, caption: caption))
        } else if action == "unregisterMenuCommand", let cmdId = body["id"] as? Int {
            registeredCommands.removeAll { $0.cmdId == cmdId }
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
                        let errEscaped = error.localizedDescription.replacingOccurrences(of: "'", with: "\\'")
                        self?.webView.evaluateJavaScript("window.__gm_handleXhrError('\(reqId)', '\(errEscaped)')", completionHandler: nil)
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

    func injectAndRunUserScripts() {
        let currentUrlStr = url?.absoluteString ?? ""
        let matchingScripts = UserScriptStore.shared.loadScripts().filter {
            UserScriptStore.shared.isScriptMatching(script: $0, urlString: currentUrlStr)
        }

        let gmPolyfill = """
        if (!window.__gm_polyfilled__) {
            window.__gm_polyfilled__ = true;
            window.unsafeWindow = window;
            window.__gm_menu_commands__ = window.__gm_menu_commands__ || {};
            
            (function() {
                var downX = 0, downY = 0;
                window.addEventListener('pointerdown', function(e) { downX = e.clientX; downY = e.clientY; }, true);
                window.addEventListener('pointermove', function(e) {
                    if (Math.abs(e.clientX - downX) < 4 && Math.abs(e.clientY - downY) < 4) {
                        e.stopPropagation();
                    }
                }, true);
            })();

            window.GM_registerMenuCommand = function(caption, commandFunc, scriptId) {
                var id = Math.floor(Math.random() * 1000000);
                window.__gm_menu_commands__[id] = commandFunc;
                try {
                    window.webkit.messageHandlers.GM.postMessage({
                        action: 'registerMenuCommand',
                        id: id,
                        caption: caption,
                        scriptId: scriptId || window.__current_running_script_id__ || ''
                    });
                } catch(e) {}
                return id;
            };
            window.GM_unregisterMenuCommand = function(id) {
                delete window.__gm_menu_commands__[id];
                try {
                    window.webkit.messageHandlers.GM.postMessage({
                        action: 'unregisterMenuCommand',
                        id: id
                    });
                } catch(e) {}
            };
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
            window.GM_setValue = function(name, value) {
                localStorage.setItem('GM_' + name, JSON.stringify(value));
            };
            window.GM_getValue = function(name, defaultValue) {
                var val = localStorage.getItem('GM_' + name);
                return val !== null ? JSON.parse(val) : defaultValue;
            };
            window.GM_deleteValue = function(name) {
                localStorage.removeItem('GM_' + name);
            };
            window.GM_log = function(msg) {
                console.log('[Tampermonkey]', msg);
            };
            window.__gm_xhr_callbacks__ = window.__gm_xhr_callbacks__ || {};
            window.GM_xmlhttpRequest = function(opts) {
                var id = 'xhr_' + Math.random().toString(36).substr(2, 9);
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
                if (opts.onload) {
                    opts.onload({
                        status: status,
                        responseText: text,
                        readyState: 4
                    });
                }
            };
            window.__gm_handleXhrError = function(id, errorText) {
                var opts = window.__gm_xhr_callbacks__[id];
                if (!opts) return;
                delete window.__gm_xhr_callbacks__[id];
                if (opts.onerror) {
                    opts.onerror({ status: 0, responseText: errorText });
                }
            };
        }
        """

        var fullJS = gmPolyfill + "\n"
        for script in matchingScripts {
            fullJS += "window.__current_running_script_id__ = '\(script.id)';\n"
            fullJS += "try { \n" + script.code + "\n } catch(e) { console.error('[UserScript Error]', e); }\n"
        }

        webView.evaluateJavaScript(fullJS, completionHandler: nil)
    }

    func reloadUserScripts() {
        registeredCommands.removeAll()
        injectAndRunUserScripts()
        webView.reload()
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

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        registeredCommands.removeAll()
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        url = webView.url
        title = webView.title ?? url?.host ?? "新标签页"
        injectAndRunUserScripts()
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        url = webView.url
        title = webView.title ?? url?.host ?? "新标签页"
        injectAndRunUserScripts()
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

        if url.path.hasSuffix(".user.js") || url.absoluteString.hasSuffix(".user.js") {
            decisionHandler(.cancel)
            NotificationCenter.default.post(name: NSNotification.Name("InstallUserScriptNotification"), object: url)
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
