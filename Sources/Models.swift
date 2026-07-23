import UIKit
import WebKit

struct UserScript: Codable {
    var id: String
    var name: String
    var matchPattern: String
    var code: String
    var isEnabled: Bool
}

struct UserAgentItem: Codable, Equatable {
    var id: String
    var name: String
    var uaString: String
    var isCustom: Bool
}

final class UserAgentStore {
    static let shared = UserAgentStore()
    private let keyCustomItems = "browser_ua_custom_items_v4"
    private let keySelectedId = "browser_ua_selected_id_v4"

    private let defaultItems: [UserAgentItem] = [
        UserAgentItem(
            id: "default_safari",
            name: "iPhone",
            uaString: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/605.1.15",
            isCustom: false
        ),
        UserAgentItem(
            id: "default_chrome",
            name: "iPhone Chrome",
            uaString: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/125.0.6422.80 Mobile/15E148 Safari/604.1",
            isCustom: false
        ),
        UserAgentItem(
            id: "default_mac",
            name: "macOS Chrome",
            uaString: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
            isCustom: false
        )
    ]

    private init() {}

    func loadAllItems() -> [UserAgentItem] {
        var items = defaultItems
        if let data = UserDefaults.standard.data(forKey: keyCustomItems),
           let customs = try? JSONDecoder().decode([UserAgentItem].self, from: data) {
            items.append(contentsOf: customs)
        }
        return items
    }

    func addCustomItem(name: String, uaString: String) {
        var customs: [UserAgentItem] = []
        if let data = UserDefaults.standard.data(forKey: keyCustomItems),
           let decoded = try? JSONDecoder().decode([UserAgentItem].self, from: data) {
            customs = decoded
        }
        let newItem = UserAgentItem(id: UUID().uuidString, name: name, uaString: uaString, isCustom: true)
        customs.append(newItem)
        if let data = try? JSONEncoder().encode(customs) {
            UserDefaults.standard.set(data, forKey: keyCustomItems)
        }
    }

    func updateCustomItem(id: String, name: String, uaString: String) {
        if let data = UserDefaults.standard.data(forKey: keyCustomItems),
           var customs = try? JSONDecoder().decode([UserAgentItem].self, from: data) {
            if let idx = customs.firstIndex(where: { $0.id == id }) {
                customs[idx].name = name
                customs[idx].uaString = uaString
                if let data = try? JSONEncoder().encode(customs) {
                    UserDefaults.standard.set(data, forKey: keyCustomItems)
                }
            }
        }
    }

    func deleteCustomItem(id: String) {
        if let data = UserDefaults.standard.data(forKey: keyCustomItems),
           var customs = try? JSONDecoder().decode([UserAgentItem].self, from: data) {
            customs.removeAll { $0.id == id }
            if let data = try? JSONEncoder().encode(customs) {
                UserDefaults.standard.set(data, forKey: keyCustomItems)
            }
        }
        if getSelectedId() == id {
            setSelectedId(defaultItems[0].id)
        }
    }

    func getSelectedId() -> String {
        return UserDefaults.standard.string(forKey: keySelectedId) ?? defaultItems[0].id
    }

    func setSelectedId(_ id: String) {
        UserDefaults.standard.set(id, forKey: keySelectedId)
    }

    func getSelectedUA() -> String {
        let all = loadAllItems()
        let selId = getSelectedId()
        return all.first { $0.id == selId }?.uaString ?? defaultItems[0].uaString
    }

    func getSelectedItem() -> UserAgentItem {
        let all = loadAllItems()
        let selId = getSelectedId()
        return all.first { $0.id == selId } ?? defaultItems[0]
    }
}

final class EyeProtectionManager {
    static let shared = EyeProtectionManager()
    private let key = "eye_protection_enabled_v1"
    private var overlayView: UIView?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private init() {}

    func restoreState(in window: UIWindow?) {
        if isEnabled {
            applyOverlay(in: window)
        }
    }

    func toggle(in window: UIWindow?) {
        isEnabled = !isEnabled
        if isEnabled {
            applyOverlay(in: window)
        } else {
            removeOverlay()
        }
    }

    private func applyOverlay(in window: UIWindow?) {
        removeOverlay()
        guard let window = window else { return }
        let overlay = UIView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        overlay.isUserInteractionEnabled = false
        window.addSubview(overlay)
        overlayView = overlay
    }

    private func removeOverlay() {
        overlayView?.removeFromSuperview()
        overlayView = nil
    }
}

final class DomainSettingsStore {
    static let shared = DomainSettingsStore()
    private init() {}

    private func makeKey(_ domain: String, _ setting: String) -> String {
        return "DOMAIN_SETTING_\(domain.lowercased())_\(setting)"
    }

    func getBool(domain: String, setting: String, defaultVal: Bool = true) -> Bool {
        let k = makeKey(domain, setting)
        if UserDefaults.standard.object(forKey: k) == nil {
            return defaultVal
        }
        return UserDefaults.standard.bool(forKey: k)
    }

    func setBool(domain: String, setting: String, value: Bool) {
        UserDefaults.standard.set(value, forKey: makeKey(domain, setting))
    }
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
            let cleanLocked = lockedDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return cleanDomain == cleanLocked || cleanDomain.hasSuffix("." + cleanLocked) || cleanLocked.hasSuffix("." + cleanDomain)
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
    private let key = "user_tampermonkey_scripts_v5"

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

        if let url = URL(string: urlString), let host = url.host {
            let scriptEnabled = DomainSettingsStore.shared.getBool(domain: host, setting: "userScripts", defaultVal: true)
            if !scriptEnabled { return false }
        }

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

final class ScriptDataStore {
    static let shared = ScriptDataStore()
    private init() {}

    private func makeKey(_ scriptId: String, _ name: String) -> String {
        return "GM_DATA_\(scriptId)_\(name)"
    }

    func getValue(scriptId: String, name: String) -> Any? {
        return UserDefaults.standard.object(forKey: makeKey(scriptId, name))
    }

    func setValue(scriptId: String, name: String, value: Any) {
        UserDefaults.standard.set(value, forKey: makeKey(scriptId, name))
    }

    func deleteValue(scriptId: String, name: String) {
        UserDefaults.standard.removeObject(forKey: makeKey(scriptId, name))
    }

    func clearDataForScript(scriptId: String) {
        let prefix = "GM_DATA_\(scriptId)_"
        for (k, _) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    func clearAllScriptData() {
        let prefix = "GM_DATA_"
        for (k, _) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    func getAllValuesJSON(scriptId: String) -> String {
        let prefix = "GM_DATA_\(scriptId)_"
        var dict: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix(prefix) {
                let name = String(k.dropFirst(prefix.count))
                dict[name] = v
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}

final class WebsiteCleaner {
    static let shared = WebsiteCleaner()
    private init() {}

    func cleanCacheOnly(completion: (() -> Void)? = nil) {
        let cacheTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeFetchCache
        ]
        WKWebsiteDataStore.default().removeData(ofTypes: cacheTypes, modifiedSince: .distantPast) {
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func cleanUnprotectedLoginAndData(completion: (() -> Void)? = nil) {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: dataTypes) { records in
            let unprotected = records.filter { !CookieLockStore.shared.isLocked(domain: $0.displayName) }
            WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, for: unprotected) {
                DispatchQueue.main.async {
                    completion?()
                }
            }
        }
    }

    func cleanSingleDomain(record: WKWebsiteDataRecord, cacheOnly: Bool, completion: (() -> Void)? = nil) {
        let isProtected = CookieLockStore.shared.isLocked(domain: record.displayName)
        let types: Set<String>
        if cacheOnly || isProtected {
            types = [
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeOfflineWebApplicationCache,
                WKWebsiteDataTypeFetchCache
            ]
        } else {
            types = WKWebsiteDataStore.allWebsiteDataTypes()
        }
        WKWebsiteDataStore.default().removeData(ofTypes: types, for: [record]) {
            DispatchQueue.main.async {
                completion?()
            }
        }
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
    var isDisplayingFailurePage = false
    var previousURL: URL?

    private var hasInjectedScriptsForCurrentPage = false
    private var navigationActionURL: URL?
    weak var delegate: TabItemDelegate?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsPictureInPictureMediaPlayback = true

        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.customUserAgent = UserAgentStore.shared.getSelectedUA()

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
        destroy()
    }

    func destroy() {
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
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        webView.removeFromSuperview()
        snapshot = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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

    func loadErrorPage(for targetURL: URL?, error: Error) {
        let nsError = error as NSError
        guard nsError.domain != "WebKitErrorDomain" && nsError.code != NSURLErrorCancelled && nsError.code != 102 else { return }

        isDisplayingFailurePage = true
        failedURL = targetURL ?? webView.url
        url = failedURL
        title = "无法连接服务器"

        var titleStr = "无法连接服务器"
        var reasonStr = "服务器拒绝连接或已被网络策略/代理拦截。"
        if nsError.code == NSURLErrorNotConnectedToInternet {
            titleStr = "未连接网络"
            reasonStr = "请检查网络连接。"
        } else if nsError.code == NSURLErrorCannotFindHost {
            titleStr = "找不到服务器"
            reasonStr = "域名解析失败。"
        } else if nsError.code == NSURLErrorTimedOut {
            titleStr = "连接超时"
            reasonStr = "网络响应超时。"
        }

        let urlStr = failedURL?.absoluteString ?? ""
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: #f8f9fa; color: #212529; margin: 0; padding: 60px 24px; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 60vh; text-align: center; }
            h1 { font-size: 22px; font-weight: 600; margin: 0 0 12px 0; color: #1a1a1a; }
            p { font-size: 14px; color: #6c757d; margin: 0 0 16px 0; max-width: 320px; line-height: 1.5; }
            .url-box { font-size: 13px; color: #adb5bd; word-break: break-all; margin-bottom: 32px; max-width: 300px; }
            .btn-group { display: flex; gap: 12px; }
            .btn { background-color: #ffffff; color: #495057; border: 1px solid #ced4da; padding: 10px 24px; font-size: 14px; font-weight: 500; border-radius: 8px; cursor: pointer; display: inline-block; -webkit-tap-highlight-color: transparent; }
            .btn-primary { background-color: #007aff; color: #ffffff; border: none; }
            .btn:active { opacity: 0.7; }
        </style>
        </head>
        <body>
            <h1>\(titleStr)</h1>
            <p>\(reasonStr)</p>
            <div class="url-box">\(urlStr)</div>
            <div class="btn-group">
                <button class="btn" onclick="window.webkit.messageHandlers.GM.postMessage({action: 'goBackAction'})">返回上一页</button>
                <button class="btn btn-primary" onclick="location.reload()">重新加载</button>
            </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: failedURL)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let targetURL = navigationAction.request.url {
            delegate?.tabRequestNewTab(url: targetURL)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        isDisplayingFailurePage = false
        hasInjectedScriptsForCurrentPage = false
        registeredCommands.removeAll()
        delegate?.tabDidUpdate(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let currentURL = webView.url, !currentURL.absoluteString.contains("about:blank") {
            if previousURL != currentURL {
                previousURL = url
            }
            url = currentURL
        }
        title = webView.title ?? url?.host ?? "新标签页"
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
        if !hasInjectedScriptsForCurrentPage {
            hasInjectedScriptsForCurrentPage = true
            injectAndRunUserScripts()
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
        loadErrorPage(for: webView.url ?? navigationActionURL, error: error)
        delegate?.tabDidFail(self, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        loadErrorPage(for: webView.url ?? navigationActionURL, error: error)
        delegate?.tabDidFail(self, error: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let targetURL = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        navigationActionURL = targetURL

        if targetURL.path.hasSuffix(".user.js") || targetURL.absoluteString.hasSuffix(".user.js") {
            decisionHandler(.cancel)
            NotificationCenter.default.post(name: NSNotification.Name("InstallUserScriptNotification"), object: targetURL)
            return
        }

        let scheme = targetURL.scheme?.lowercased() ?? ""

        if ["http", "https", "about", "data", "blob"].contains(scheme) {
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                delegate?.tabRequestNewTab(url: targetURL)
                return
            }

            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)

        if scheme == "intent", let fallbackURL = fallbackURL(from: targetURL) {
            webView.load(URLRequest(url: fallbackURL))
            return
        }

        UIApplication.shared.open(targetURL, options: [:], completionHandler: nil)
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
