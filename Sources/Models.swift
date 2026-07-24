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

struct RegisteredMenuCommand {
    let scriptId: String
    let cmdId: Int
    let caption: String
}

enum CleanOption: Int, Hashable, CaseIterable {
    case cache = 0
    case loginAndData = 1
    case searchHistory = 2
    case scriptData = 3
}

enum CustomBottomSheetLayout {
    case grid
    case list
}

enum SearchEngine: String, CaseIterable, Codable {
    case google = "google"
    case bing = "bing"
    case yandex = "yandex"

    var name: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .yandex: return "Yandex"
        }
    }

    func searchURL(query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        switch self {
        case .google:
            return URL(string: "https://www.google.com/search?q=\(encoded)")
        case .bing:
            return URL(string: "https://www.bing.com/search?q=\(encoded)")
        case .yandex:
            return URL(string: "https://yandex.com/search/?text=\(encoded)")
        }
    }
}

final class SearchEngineStore {
    static let shared = SearchEngineStore()
    private let key = "browser_selected_search_engine_v1"
    private init() {}

    var currentEngine: SearchEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let engine = SearchEngine(rawValue: raw) else {
                return .google
            }
            return engine
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

struct CustomBottomSheetItem {
    let title: String
    var isDestructive: Bool = false
    let handler: (() -> Void)?
    let longPressHandler: (() -> Void)?

    init(
        title: String,
        isDestructive: Bool = false,
        handler: (() -> Void)?,
        longPressHandler: (() -> Void)? = nil
    ) {
        self.title = title
        self.isDestructive = isDestructive
        self.handler = handler
        self.longPressHandler = longPressHandler
    }
}

struct HistoryItem: Codable, Equatable {
    var id: String
    var title: String
    var urlString: String
    var timestamp: Date
}

final class HistoryStore {
    static let shared = HistoryStore()
    private let key = "browser_browsing_history_v2"
    private init() {}

    func getHistory() -> [HistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([HistoryItem].self, from: data) else {
            return []
        }
        return items
    }

    func addHistory(title: String, urlString: String) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedURL.contains("about:blank") else { return }

        var items = getHistory()
        items.removeAll { $0.urlString == trimmedURL }

        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (URL(string: trimmedURL)?.host ?? trimmedURL) : title
        let newItem = HistoryItem(id: UUID().uuidString, title: displayTitle, urlString: trimmedURL, timestamp: Date())
        items.insert(newItem, at: 0)

        if items.count > 500 {
            items = Array(items.prefix(500))
        }

        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func removeHistory(id: String) {
        var items = getHistory()
        items.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

struct SavedTabInfo: Codable {
    var urlString: String?
    var title: String
}

struct SavedTabState: Codable {
    var tabs: [SavedTabInfo]
    var activeIndex: Int
}

final class TabStateStore {
    static let shared = TabStateStore()
    private let key = "browser_saved_tabs_state_v1"
    private init() {}

    func saveState(tabs: [SavedTabInfo], activeIndex: Int) {
        let state = SavedTabState(tabs: tabs, activeIndex: activeIndex)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func loadState() -> SavedTabState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(SavedTabState.self, from: data) else {
            return nil
        }
        return state
    }

    func clearState() {
        UserDefaults.standard.removeObject(forKey: key)
    }
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

    private let enabledKey = "eye_protection_enabled_v1"
    private let levelKey = "eye_protection_level_v2"
    private var overlayView: UIView?

    enum Level: Int, CaseIterable {
        case low = 0
        case medium = 1
        case high = 2

        var alpha: CGFloat {
            switch self {
            case .low:
                return 0.245
            case .medium:
                return 0.35
            case .high:
                return 0.455
            }
        }

        var title: String {
            switch self {
            case .low:
                return "低强度"
            case .medium:
                return "中强度"
            case .high:
                return "高强度"
            }
        }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    var level: Level {
        get {
            Level(rawValue: UserDefaults.standard.integer(forKey: levelKey)) ?? .medium
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: levelKey)
        }
    }

    private init() {}

    func restoreState(in window: UIWindow?) {
        guard isEnabled else { return }
        applyOverlay(in: window)
    }

    func toggle(in window: UIWindow?) {
        isEnabled.toggle()
        if isEnabled {
            applyOverlay(in: window)
        } else {
            removeOverlay()
        }
    }

    func setLevel(_ newLevel: Level, in window: UIWindow?) {
        level = newLevel
        isEnabled = true
        applyOverlay(in: window)
    }

    private func applyOverlay(in window: UIWindow?) {
        removeOverlay()
        guard let window = window else { return }
        let overlay = UIView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(level.alpha)
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
        return host == domainPattern || host.hasSuffix("." + domainPattern)
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
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: allTypes) { records in
            let unprotected = records.filter { !CookieLockStore.shared.isLocked(domain: $0.displayName) }
            guard !unprotected.isEmpty else {
                DispatchQueue.main.async { completion?() }
                return
            }
            WKWebsiteDataStore.default().removeData(ofTypes: cacheTypes, for: unprotected) {
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    func cleanUnprotectedLoginAndData(completion: (() -> Void)? = nil) {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: allTypes) { records in
            let unprotected = records.filter { !CookieLockStore.shared.isLocked(domain: $0.displayName) }
            guard !unprotected.isEmpty else {
                DispatchQueue.main.async { completion?() }
                return
            }
            WKWebsiteDataStore.default().removeData(ofTypes: allTypes, for: unprotected) {
                DispatchQueue.main.async { completion?() }
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
