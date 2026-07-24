import UIKit
import WebKit

struct AdBlockSubscription: Codable, Equatable {
    var id: String
    var name: String
    var urlString: String
    var isEnabled: Bool
    var lastUpdated: Date?
    var ruleCount: Int
}

struct AdBlockCompiledSourceMetadata: Codable {
    var sourceId: String
    var version: String
    var chunkCount: Int
    var ruleCount: Int
    var cssScript: String
}

private struct AdBlockSourcePayload {
    var chunkJSONStrings: [String]
    var cssScript: String
    var ruleCount: Int
}

private struct AdBlockParsedLine {
    var networkRules: [[String: Any]]
    var domHideSelectors: [String: Set<String>]
    var domExceptionSelectors: [String: Set<String>]
    var domCustomStyles: [String: [String: String]]
}

final class AdBlockManager {
    static let shared = AdBlockManager()

    static let customSourceId = "__custom_rules__"

    private let enabledKey = "adblock_enabled_v2"
    private let subscriptionsKey = "adblock_subscriptions_v2"
    private let customRulesKey = "adblock_custom_rules_v2"
    private let metadataKey = "adblock_compiled_metadata_v2"
    private let identifierPrefix = "SimpleBrowserAdBlock"

    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var compiledListsBySource: [String: [WKContentRuleList]] = [:]
    private var cssScriptsBySource: [String: WKUserScript] = [:]
    private var metadataBySource: [String: AdBlockCompiledSourceMetadata] = [:]
    private var updatingSourceIds = Set<String>()
    private let workQueue = DispatchQueue(label: "SimpleBrowser.AdBlockCompiler", qos: .userInitiated)

    var isEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            applyRulesToAttachedWebViews()
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: enabledKey)
        }

        removeLegacyBuiltInSubscription()
        metadataBySource = loadMetadata()
        restorePersistedRules()
    }

    func loadSubscriptions() -> [AdBlockSubscription] {
        guard let data = UserDefaults.standard.data(forKey: subscriptionsKey),
              let items = try? JSONDecoder().decode([AdBlockSubscription].self, from: data) else {
            return []
        }
        return items
    }

    func saveSubscriptions(_ subscriptions: [AdBlockSubscription]) {
        guard let data = try? JSONEncoder().encode(subscriptions) else {
            return
        }
        UserDefaults.standard.set(data, forKey: subscriptionsKey)
    }

    func getCustomRules() -> String {
        UserDefaults.standard.string(forKey: customRulesKey) ?? ""
    }

    func saveCustomRules(_ rules: String, completion: ((Bool) -> Void)? = nil) {
        UserDefaults.standard.set(rules, forKey: customRulesKey)
        compileSource(id: Self.customSourceId) { success, _ in
            completion?(success)
        }
    }

    func updateSubscription(id: String, name: String, urlString: String) {
        var subscriptions = loadSubscriptions()

        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else {
            return
        }

        subscriptions[index].name = name
        subscriptions[index].urlString = urlString
        saveSubscriptions(subscriptions)
    }

    func addSubscription(name: String, urlString: String) -> AdBlockSubscription {
        let subscription = AdBlockSubscription(
            id: UUID().uuidString,
            name: name,
            urlString: urlString,
            isEnabled: true,
            lastUpdated: nil,
            ruleCount: 0
        )

        var subscriptions = loadSubscriptions()
        subscriptions.append(subscription)
        saveSubscriptions(subscriptions)

        return subscription
    }

    func deleteSubscription(id: String) {
        var subscriptions = loadSubscriptions()
        subscriptions.removeAll { $0.id == id }
        saveSubscriptions(subscriptions)
        removeSource(id: id)
    }

    func isUpdating(sourceId: String) -> Bool {
        updatingSourceIds.contains(sourceId)
    }

    func ruleCount(sourceId: String) -> Int {
        metadataBySource[sourceId]?.ruleCount ?? 0
    }

    func attach(to webView: WKWebView) {
        attachedWebViews.add(webView)
        applyRules(to: webView)
    }

    func detach(from webView: WKWebView) {
        attachedWebViews.remove(webView)
    }

    func applyRules(to webView: WKWebView) {
        let controller = webView.configuration.userContentController

        controller.removeAllContentRuleLists()
        controller.removeAllUserScripts()

        guard isEnabled else {
            return
        }

        for lists in compiledListsBySource.values {
            for ruleList in lists {
                controller.add(ruleList)
            }
        }

        for script in cssScriptsBySource.values {
            controller.addUserScript(script)
        }
    }

    func fetchSubscription(
        _ subscription: AdBlockSubscription,
        completion: @escaping (Bool, Int, String?) -> Void
    ) {
        guard let url = URL(string: subscription.urlString) else {
            completion(false, 0, "无效的 URL 地址")
            return
        }

        updatingSourceIds.insert(subscription.id)

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )

        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                return
            }

            if let error = error {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    completion(false, 0, "网络请求错误：\(error.localizedDescription)")
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let data = data,
                  !data.isEmpty else {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    completion(false, 0, "规则文件下载失败或为空")
                }
                return
            }

            self.workQueue.async {
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .ascii)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""

                guard !text.isEmpty else {
                    DispatchQueue.main.async {
                        self.updatingSourceIds.remove(subscription.id)
                        completion(false, 0, "文本解码失败")
                    }
                    return
                }

                let fileURL = self.subscriptionFileURL(id: subscription.id)

                do {
                    try text.write(to: fileURL, atomically: true, encoding: .utf8)
                } catch {
                    DispatchQueue.main.async {
                        self.updatingSourceIds.remove(subscription.id)
                        completion(false, 0, "保存规则文件失败")
                    }
                    return
                }

                self.compileSource(id: subscription.id) { success, compileErr in
                    DispatchQueue.main.async {
                        self.updatingSourceIds.remove(subscription.id)

                        guard success else {
                            completion(false, 0, compileErr ?? "规则无法成功生成挂载表")
                            return
                        }

                        let compiledRules = self.ruleCount(sourceId: subscription.id)

                        var subscriptions = self.loadSubscriptions()
                        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                            subscriptions[index].lastUpdated = Date()
                            subscriptions[index].ruleCount = compiledRules
                            self.saveSubscriptions(subscriptions)
                        }

                        completion(true, compiledRules, nil)
                    }
                }
            }
        }.resume()
    }

    private func removeLegacyBuiltInSubscription() {
        var subscriptions = loadSubscriptions()
        let legacyIds = Set(["easylist_china", "easylist", "default_easylist"])

        let removedIds = subscriptions
            .filter { legacyIds.contains($0.id) }
            .map(\.id)

        subscriptions.removeAll { legacyIds.contains($0.id) }
        saveSubscriptions(subscriptions)

        for id in removedIds {
            try? FileManager.default.removeItem(at: subscriptionFileURL(id: id))
            removeSource(id: id)
        }
    }

    private func restorePersistedRules() {
        let sourceIds = Array(metadataBySource.keys)

        for sourceId in sourceIds {
            guard let metadata = metadataBySource[sourceId] else {
                continue
            }

            if metadata.chunkCount == 0 {
                restoreCSSScript(metadata: metadata)
                continue
            }

            let group = DispatchGroup()
            var lists: [WKContentRuleList] = []

            for index in 0..<metadata.chunkCount {
                group.enter()

                WKContentRuleListStore.default().lookUpContentRuleList(
                    forIdentifier: ruleListIdentifier(
                        sourceId: sourceId,
                        version: metadata.version,
                        index: index
                    )
                ) { ruleList, _ in
                    if let ruleList = ruleList {
                        lists.append(ruleList)
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) { [weak self] in
                guard let self = self else {
                    return
                }

                if lists.count == metadata.chunkCount {
                    self.compiledListsBySource[sourceId] = lists
                    self.restoreCSSScript(metadata: metadata)
                    self.applyRulesToAttachedWebViews()
                } else {
                    self.compileSource(id: sourceId, completion: nil)
                }
            }
        }
    }

    private func restoreCSSScript(metadata: AdBlockCompiledSourceMetadata) {
        guard !metadata.cssScript.isEmpty else {
            cssScriptsBySource.removeValue(forKey: metadata.sourceId)
            return
        }

        cssScriptsBySource[metadata.sourceId] = WKUserScript(
            source: metadata.cssScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private func compileSource(
        id sourceId: String,
        completion: ((Bool, String?) -> Void)?
    ) {
        updatingSourceIds.insert(sourceId)

        var completed = false
        let safeCompletion: (Bool, String?) -> Void = { [weak self] success, err in
            guard !completed else { return }
            completed = true
            DispatchQueue.main.async {
                self?.updatingSourceIds.remove(sourceId)
                completion?(success, err)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 45.0) {
            safeCompletion(false, "编译规则超时")
        }

        workQueue.async { [weak self] in
            guard let self = self else {
                safeCompletion(false, "已释放")
                return
            }

            guard let text = self.sourceText(id: sourceId) else {
                DispatchQueue.main.async {
                    self.removeSource(id: sourceId)
                    safeCompletion(true, nil)
                }
                return
            }

            let payload = self.buildSourcePayload(text: text)

            DispatchQueue.main.async {
                self.compilePayload(
                    payload,
                    sourceId: sourceId,
                    completion: safeCompletion
                )
            }
        }
    }

    private func compilePayload(
        _ payload: AdBlockSourcePayload,
        sourceId: String,
        completion: ((Bool, String?) -> Void)?
    ) {
        let oldMetadata = metadataBySource[sourceId]
        let newVersion = UUID().uuidString

        guard !payload.chunkJSONStrings.isEmpty else {
            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                version: newVersion,
                chunkCount: 0,
                ruleCount: payload.ruleCount,
                cssScript: payload.cssScript
            )

            metadataBySource[sourceId] = metadata
            saveMetadata(metadataBySource)

            compiledListsBySource.removeValue(forKey: sourceId)
            restoreCSSScript(metadata: metadata)
            updatingSourceIds.remove(sourceId)

            if let oldMetadata = oldMetadata {
                removeStoredRuleLists(metadata: oldMetadata)
            }

            applyRulesToAttachedWebViews()
            completion?(true, nil)
            return
        }

        compileChunks(
            payload.chunkJSONStrings,
            sourceId: sourceId,
            version: newVersion,
            index: 0,
            compiledLists: []
        ) { [weak self] lists in
            guard let self = self else {
                completion?(false, "解析器被释放")
                return
            }

            let totalActiveRuleCount = payload.ruleCount

            guard !lists.isEmpty || !payload.cssScript.isEmpty else {
                self.updatingSourceIds.remove(sourceId)
                completion?(false, "未能成功编译有效规则")
                return
            }

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                version: newVersion,
                chunkCount: lists.count,
                ruleCount: totalActiveRuleCount,
                cssScript: payload.cssScript
            )

            self.metadataBySource[sourceId] = metadata
            self.saveMetadata(self.metadataBySource)

            self.compiledListsBySource[sourceId] = lists
            self.restoreCSSScript(metadata: metadata)
            self.updatingSourceIds.remove(sourceId)

            if let oldMetadata = oldMetadata {
                self.removeStoredRuleLists(metadata: oldMetadata)
            }

            self.applyRulesToAttachedWebViews()
            completion?(true, nil)
        }
    }

    private func compileChunks(
        _ jsonStrings: [String],
        sourceId: String,
        version: String,
        index: Int,
        compiledLists: [WKContentRuleList],
        completion: @escaping ([WKContentRuleList]) -> Void
    ) {
        guard index < jsonStrings.count else {
            completion(compiledLists)
            return
        }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ruleListIdentifier(
                sourceId: sourceId,
                version: version,
                index: compiledLists.count
            ),
            encodedContentRuleList: jsonStrings[index]
        ) { [weak self] ruleList, _ in
            guard let self = self else {
                completion(compiledLists)
                return
            }

            var nextLists = compiledLists
            if let ruleList = ruleList {
                nextLists.append(ruleList)
            }

            self.compileChunks(
                jsonStrings,
                sourceId: sourceId,
                version: version,
                index: index + 1,
                compiledLists: nextLists,
                completion: completion
            )
        }
    }

    private func removeSource(id sourceId: String) {
        let oldMetadata = metadataBySource.removeValue(forKey: sourceId)
        compiledListsBySource.removeValue(forKey: sourceId)
        cssScriptsBySource.removeValue(forKey: sourceId)
        updatingSourceIds.remove(sourceId)
        saveMetadata(metadataBySource)

        if let oldMetadata = oldMetadata {
            removeStoredRuleLists(metadata: oldMetadata)
        }

        applyRulesToAttachedWebViews()
    }

    private func removeStoredRuleLists(metadata: AdBlockCompiledSourceMetadata) {
        guard metadata.chunkCount > 0 else {
            return
        }

        for index in 0..<metadata.chunkCount {
            WKContentRuleListStore.default().removeContentRuleList(
                forIdentifier: ruleListIdentifier(
                    sourceId: metadata.sourceId,
                    version: metadata.version,
                    index: index
                ),
                completionHandler: nil
            )
        }
    }

    private func applyRulesToAttachedWebViews() {
        for webView in attachedWebViews.allObjects {
            applyRules(to: webView)
        }
    }

    private func sourceText(id sourceId: String) -> String? {
        if sourceId == Self.customSourceId {
            let text = getCustomRules()
            return text.isEmpty ? nil : text
        }

        let fileURL = subscriptionFileURL(id: sourceId)
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private func buildSourcePayload(text: String) -> AdBlockSourcePayload {
        var chunks: [String] = []
        var currentRules: [[String: Any]] = []
        var domHideTable: [String: Set<String>] = [:]
        var domExceptionTable: [String: Set<String>] = [:]
        var domStyleTable: [String: [String: String]] = [:]
        var ruleCount = 0
        let maxRulesLimit = 50000

        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            if ruleCount >= maxRulesLimit { break }

            let result = parseABPLine(line)

            for rule in result.networkRules {
                currentRules.append(rule)

                if currentRules.count >= 4000 {
                    if let json = jsonString(from: currentRules) {
                        chunks.append(json)
                    }
                    currentRules.removeAll(keepingCapacity: true)
                }
            }

            for (domain, selectors) in result.domHideSelectors {
                domHideTable[domain, default: []].formUnion(selectors)
            }

            for (domain, selectors) in result.domExceptionSelectors {
                domExceptionTable[domain, default: []].formUnion(selectors)
            }

            for (domain, styles) in result.domCustomStyles {
                var currentStyles = domStyleTable[domain, default: [:]]
                for (selector, css) in styles {
                    currentStyles[selector] = css
                }
                domStyleTable[domain] = currentStyles
            }

            if !result.networkRules.isEmpty || !result.domHideSelectors.isEmpty || !result.domExceptionSelectors.isEmpty || !result.domCustomStyles.isEmpty {
                ruleCount += 1
            }
        }

        if !currentRules.isEmpty, let json = jsonString(from: currentRules) {
            chunks.append(json)
        }

        return AdBlockSourcePayload(
            chunkJSONStrings: chunks,
            cssScript: domHidingScript(
                hideTable: domHideTable,
                exceptionTable: domExceptionTable,
                styleTable: domStyleTable
            ),
            ruleCount: ruleCount
        )
    }

    private func isSupportedByContentBlockerJSON(_ selector: String) -> Bool {
        if selector.contains(":has(") ||
           selector.contains(":matches(") ||
           selector.contains(":where(") ||
           selector.contains(":xpath(") ||
           selector.contains(":style(") {
            return false
        }

        if selector.range(of: #"\[[^\]]+\s+[iI]\s*\]"#, options: .regularExpression) != nil {
            return false
        }

        return true
    }

    private func parseABPLine(_ rawLine: String) -> AdBlockParsedLine {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !line.hasPrefix("！"),
              !line.hasPrefix("[") else {
            return AdBlockParsedLine(networkRules: [], domHideSelectors: [:], domExceptionSelectors: [:], domCustomStyles: [:])
        }

        if line.contains("#@#") {
            let range = line.range(of: "#@#")!
            let domainsText = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let selectorsText = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !selectorsText.isEmpty else {
                return AdBlockParsedLine(networkRules: [], domHideSelectors: [:], domExceptionSelectors: [:], domCustomStyles: [:])
            }

            let domains = normalizedDomains(from: domainsText)
            let selectorParts = splitSelectorList(selectorsText)
            let key = domains.include.isEmpty ? "*" : domains.include.joined(separator: ",")

            return AdBlockParsedLine(
                networkRules: [],
                domHideSelectors: [:],
                domExceptionSelectors: [key: Set(selectorParts)],
                domCustomStyles: [:]
            )
        }

        if line.contains("##") {
            let range = line.range(of: "##")!
            let domainsText = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let selectorsText = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !selectorsText.isEmpty else {
                return AdBlockParsedLine(networkRules: [], domHideSelectors: [:], domExceptionSelectors: [:], domCustomStyles: [:])
            }

            let domains = normalizedDomains(from: domainsText)
            let selectorParts = splitSelectorList(selectorsText)

            var standardSelectors: [String] = []
            var domSelectors: [String] = []
            var customStyles: [String: String] = [:]

            for sel in selectorParts {
                let cleaned = sel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }

                if let styleRange = cleaned.range(of: ":style(") {
                    let baseSel = String(cleaned[..<styleRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let styleContent = String(cleaned[styleRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " )"))
                    if !baseSel.isEmpty && !styleContent.isEmpty {
                        customStyles[baseSel] = styleContent
                    }
                    continue
                }

                domSelectors.append(cleaned)

                if isSupportedByContentBlockerJSON(cleaned) {
                    standardSelectors.append(cleaned)
                }
            }

            var networkRules: [[String: Any]] = []

            if !standardSelectors.isEmpty {
                var trigger: [String: Any] = [
                    "url-filter": ".*",
                    "url-filter-is-case-sensitive": false
                ]

                if !domains.include.isEmpty {
                    trigger["if-domain"] = domains.include
                } else if !domains.exclude.isEmpty {
                    trigger["unless-domain"] = domains.exclude
                }

                networkRules.append([
                    "trigger": trigger,
                    "action": [
                        "type": "css-display-none",
                        "selector": standardSelectors.joined(separator: ", ")
                    ]
                ])
            }

            var domHideDict: [String: Set<String>] = [:]
            var domCustomStyleDict: [String: [String: String]] = [:]
            let key = domains.include.isEmpty ? "*" : domains.include.joined(separator: ",")

            if !domSelectors.isEmpty {
                domHideDict[key] = Set(domSelectors)
            }
            if !customStyles.isEmpty {
                domCustomStyleDict[key] = customStyles
            }

            return AdBlockParsedLine(
                networkRules: networkRules,
                domHideSelectors: domHideDict,
                domExceptionSelectors: [:],
                domCustomStyles: domCustomStyleDict
            )
        }

        var isException = false
        if line.hasPrefix("@@") {
            isException = true
            line = String(line.dropFirst(2))
        }

        let pieces = line.split(
            separator: "$",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )

        let rawPattern = String(pieces[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawPattern.isEmpty else {
            return AdBlockParsedLine(networkRules: [], domHideSelectors: [:], domExceptionSelectors: [:], domCustomStyles: [:])
        }

        let options = pieces.count > 1
            ? String(pieces[1]).split(separator: ",").map(String.init)
            : []

        var includeDomains: [String] = []
        var excludeDomains: [String] = []
        var resourceTypes: [String] = []
        var loadTypes: [String] = []

        for optionValue in options {
            let option = optionValue.trimmingCharacters(in: .whitespacesAndNewlines)

            if option.hasPrefix("domain=") {
                let domainsText = String(option.dropFirst(7))
                let domains = normalizedDomains(from: domainsText, separator: "|")
                includeDomains.append(contentsOf: domains.include)
                excludeDomains.append(contentsOf: domains.exclude)
            } else if option == "script" {
                resourceTypes.append("script")
            } else if option == "image" {
                resourceTypes.append("image")
            } else if option == "stylesheet" {
                resourceTypes.append("style-sheet")
            } else if option == "font" {
                resourceTypes.append("font")
            } else if option == "media" {
                resourceTypes.append("media")
            } else if option == "xmlhttprequest" || option == "xhr" {
                resourceTypes.append("raw")
            } else if option == "subdocument" {
                resourceTypes.append("document")
            } else if option == "popup" {
                resourceTypes.append("popup")
            } else if option == "websocket" ||
                        option == "ping" ||
                        option == "other" ||
                        option == "fetch" ||
                        option == "csp" ||
                        option == "csp-report" {
                resourceTypes.append("raw")
            } else if option == "third-party" || option == "3p" {
                loadTypes.append("third-party")
            } else if option == "~third-party" || option == "1p" || option == "first-party" {
                loadTypes.append("first-party")
            }
        }

        var trigger: [String: Any] = [
            "url-filter": urlFilterPattern(from: rawPattern),
            "url-filter-is-case-sensitive": false
        ]

        if !includeDomains.isEmpty {
            trigger["if-domain"] = Array(Set(includeDomains))
        } else if !excludeDomains.isEmpty {
            trigger["unless-domain"] = Array(Set(excludeDomains))
        }

        if !resourceTypes.isEmpty {
            trigger["resource-type"] = Array(Set(resourceTypes))
        }

        if !loadTypes.isEmpty {
            trigger["load-type"] = Array(Set(loadTypes))
        }

        return AdBlockParsedLine(
            networkRules: [[
                "trigger": trigger,
                "action": [
                    "type": isException ? "ignore-previous-rules" : "block"
                ]
            ]],
            domHideSelectors: [:],
            domExceptionSelectors: [:],
            domCustomStyles: [:]
        )
    }

    private func normalizedDomains(
        from text: String,
        separator: Character = ","
    ) -> (include: [String], exclude: [String]) {
        var include: [String] = []
        var exclude: [String] = []

        for rawValue in text.split(separator: separator) {
            let value = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))

            guard !value.isEmpty else {
                continue
            }

            if value.hasPrefix("~") {
                let domain = String(value.dropFirst())
                if !domain.isEmpty {
                    exclude.append(domain)
                }
            } else {
                include.append(value)
            }
        }

        return (include, exclude)
    }

    private func urlFilterPattern(from pattern: String) -> String {
        var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("/") && text.hasSuffix("/") && text.count > 2 {
            return String(text.dropFirst().dropLast())
        }

        var startAnchor = false
        var endAnchor = false

        if text.hasPrefix("|") && !text.hasPrefix("||") {
            startAnchor = true
            text = String(text.dropFirst())
        }

        if text.hasSuffix("|") {
            endAnchor = true
            text = String(text.dropLast())
        }

        if text.hasPrefix("||") {
            let domain = String(text.dropFirst(2)).replacingOccurrences(of: "^", with: "")
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            return "https?://([^/]+\\.)?\(escaped)([:/].*)?"
        }

        var escaped = NSRegularExpression.escapedPattern(for: text)
        escaped = escaped.replacingOccurrences(of: "\\*", with: ".*")
        escaped = escaped.replacingOccurrences(of: "\\^", with: "[^A-Za-z0-9_\\-.%]")

        let prefix = startAnchor ? "^" : ".*"
        let suffix = endAnchor ? "$" : ".*"

        return "\(prefix)\(escaped)\(suffix)"
    }

    private func domHidingScript(
        hideTable: [String: Set<String>],
        exceptionTable: [String: Set<String>],
        styleTable: [String: [String: String]]
    ) -> String {
        guard !hideTable.isEmpty || !exceptionTable.isEmpty || !styleTable.isEmpty else {
            return ""
        }

        var hidePayload: [[String: Any]] = []
        for (domainsText, selectors) in hideTable {
            hidePayload.append([
                "domains": domainsText == "*" ? [] : domainsText.split(separator: ",").map(String.init),
                "selectors": Array(selectors)
            ])
        }

        var exceptionPayload: [[String: Any]] = []
        for (domainsText, selectors) in exceptionTable {
            exceptionPayload.append([
                "domains": domainsText == "*" ? [] : domainsText.split(separator: ",").map(String.init),
                "selectors": Array(selectors)
            ])
        }

        var stylePayload: [[String: Any]] = []
        for (domainsText, styleMap) in styleTable {
            stylePayload.append([
                "domains": domainsText == "*" ? [] : domainsText.split(separator: ",").map(String.init),
                "styles": styleMap
            ])
        }

        let hideJSON = (try? JSONSerialization.data(withJSONObject: hidePayload)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let exceptionJSON = (try? JSONSerialization.data(withJSONObject: exceptionPayload)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let styleJSON = (try? JSONSerialization.data(withJSONObject: stylePayload)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return """
        (function() {
            var host = (location.hostname || '').toLowerCase();
            var hideRules = \(hideJSON);
            var exceptionRules = \(exceptionJSON);
            var styleRules = \(styleJSON);

            var selectors = [];
            var exceptions = [];

            for (var i = 0; i < hideRules.length; i++) {
                var item = hideRules[i];
                if (item.domains.length === 0) {
                    selectors = selectors.concat(item.selectors);
                    continue;
                }
                for (var j = 0; j < item.domains.length; j++) {
                    var domain = item.domains[j];
                    if (host === domain || host.endsWith('.' + domain)) {
                        selectors = selectors.concat(item.selectors);
                        break;
                    }
                }
            }

            for (var i = 0; i < exceptionRules.length; i++) {
                var item = exceptionRules[i];
                if (item.domains.length === 0) {
                    exceptions = exceptions.concat(item.selectors);
                    continue;
                }
                for (var j = 0; j < item.domains.length; j++) {
                    var domain = item.domains[j];
                    if (host === domain || host.endsWith('.' + domain)) {
                        exceptions = exceptions.concat(item.selectors);
                        break;
                    }
                }
            }

            function applyRules() {
                var style = document.getElementById('__simple_browser_adblock_style__');
                if (!style) {
                    style = document.createElement('style');
                    style.id = '__simple_browser_adblock_style__';
                    style.type = 'text/css';
                    (document.head || document.documentElement).appendChild(style);
                }

                var cssContent = '';
                if (selectors.length > 0) {
                    cssContent += selectors.join(', ') + ' { display: none !important; visibility: hidden !important; pointer-events: none !important; }\\n';
                }
                if (exceptions.length > 0) {
                    cssContent += exceptions.join(', ') + ' { display: revert !important; visibility: visible !important; pointer-events: auto !important; }\\n';
                }

                for (var i = 0; i < styleRules.length; i++) {
                    var item = styleRules[i];
                    var matched = item.domains.length === 0;
                    if (!matched) {
                        for (var j = 0; j < item.domains.length; j++) {
                            var d = item.domains[j];
                            if (host === d || host.endsWith('.' + d)) {
                                matched = true;
                                break;
                            }
                        }
                    }
                    if (matched) {
                        for (var sel in item.styles) {
                            cssContent += sel + ' { ' + item.styles[sel] + ' }\\n';
                        }
                    }
                }

                style.textContent = cssContent;
            }

            applyRules();
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', applyRules, { once: true });
            }
        })();
        """
    }

    private func jsonString(from rules: [[String: Any]]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func splitSelectorList(_ text: String) -> [String] {
        var output: [String] = []
        var current = ""
        var parenthesesDepth = 0
        var bracketsDepth = 0

        for character in text {
            if character == "(" {
                parenthesesDepth += 1
            } else if character == ")" {
                parenthesesDepth = max(0, parenthesesDepth - 1)
            } else if character == "[" {
                bracketsDepth += 1
            } else if character == "]" {
                bracketsDepth = max(0, bracketsDepth - 1)
            }

            if character == "," && parenthesesDepth == 0 && bracketsDepth == 0 {
                let value = current.trimmingCharacters(in: .whitespacesAndNewlines)

                if !value.isEmpty {
                    output.append(value)
                }

                current = ""
            } else {
                current.append(character)
            }
        }

        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)

        if !value.isEmpty {
            output.append(value)
        }

        return output
    }

    private func ruleListIdentifier(
        sourceId: String,
        version: String,
        index: Int
    ) -> String {
        let safeSourceId = sourceId.replacingOccurrences(of: "-", with: "")
        let safeVersion = version.replacingOccurrences(of: "-", with: "")
        return "\(identifierPrefix).\(safeSourceId).\(safeVersion).\(index)"
    }

    private func subscriptionFileURL(id: String) -> URL {
        let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        return directory.appendingPathComponent("adblock_subscription_\(id).txt")
    }

    private func loadMetadata() -> [String: AdBlockCompiledSourceMetadata] {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let metadata = try? JSONDecoder().decode(
                [String: AdBlockCompiledSourceMetadata].self,
                from: data
              ) else {
            return [:]
        }

        return metadata
    }

    private func saveMetadata(_ metadata: [String: AdBlockCompiledSourceMetadata]) {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return
        }

        UserDefaults.standard.set(data, forKey: metadataKey)
    }
}

final class AdBlockManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var subscriptions: [AdBlockSubscription] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    var onRulesChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "广告拦截"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))

        setupInterface()
        loadData()
    }

    private func setupInterface() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AdBlockCell")

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadData() {
        subscriptions = AdBlockManager.shared.loadSubscriptions()
        tableView.reloadData()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return 3
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        if section == 1 { return subscriptions.count + 1 }
        return 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return "总开关" }
        if section == 1 { return "规则订阅" }
        if section == 2 { return "自定义规则" }
        return nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "AdBlockCell")

        if indexPath.section == 0 {
            cell.textLabel?.text = "启用广告拦截"

            let toggle = UISwitch()
            toggle.isOn = AdBlockManager.shared.isEnabled
            toggle.addTarget(self, action: #selector(handleMasterToggle(_:)), for: .valueChanged)

            cell.accessoryView = toggle
            cell.selectionStyle = .none
            return cell
        }

        if indexPath.section == 1 {
            if indexPath.row < subscriptions.count {
                let subscription = subscriptions[indexPath.row]
                cell.textLabel?.text = subscription.name

                if AdBlockManager.shared.isUpdating(sourceId: subscription.id) {
                    cell.detailTextLabel?.text = "更新中…"
                    cell.accessoryType = .none
                } else if let date = subscription.lastUpdated {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MM-dd HH:mm"
                    cell.detailTextLabel?.text = "\(subscription.ruleCount) 条 | \(formatter.string(from: date))"
                    cell.accessoryType = .disclosureIndicator
                } else {
                    cell.detailTextLabel?.text = "尚未更新"
                    cell.accessoryType = .disclosureIndicator
                }
            } else {
                cell.textLabel?.text = "添加新订阅链接…"
                cell.textLabel?.textColor = .systemBlue
                cell.detailTextLabel?.text = nil
                cell.accessoryType = .none
            }

            return cell
        }

        let sourceId = AdBlockManager.customSourceId
        let count = AdBlockManager.shared.ruleCount(sourceId: sourceId)

        cell.textLabel?.text = "编辑自定义过滤规则"

        if AdBlockManager.shared.isUpdating(sourceId: sourceId) {
            cell.detailTextLabel?.text = "自定义规则更新中…"
        } else {
            cell.detailTextLabel?.text = "自定义规则：\(count) 条"
        }

        cell.accessoryType = .disclosureIndicator
        return cell
    }

    @objc private func handleMasterToggle(_ sender: UISwitch) {
        AdBlockManager.shared.isEnabled = sender.isOn
        onRulesChanged?()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 1 {
            if indexPath.row < subscriptions.count {
                let subscription = subscriptions[indexPath.row]
                showSubscriptionDetail(subscription)
            } else {
                showAddSubscriptionAlert()
            }
        } else if indexPath.section == 2 {
            let customVC = CustomRuleEditorViewController()
            customVC.onSaved = { [weak self] in
                self?.loadData()
                self?.onRulesChanged?()
            }
            navigationController?.pushViewController(customVC, animated: true)
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1,
              indexPath.row < subscriptions.count else {
            return nil
        }

        let subscription = subscriptions[indexPath.row]

        guard !AdBlockManager.shared.isUpdating(sourceId: subscription.id) else {
            return nil
        }

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            guard let self = self else {
                completion(false)
                return
            }

            self.subscriptions.removeAll { $0.id == subscription.id }
            tableView.deleteRows(at: [indexPath], with: .automatic)

            AdBlockManager.shared.deleteSubscription(id: subscription.id)
            completion(true)
        }

        let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            self?.showEditSubscriptionAlert(subscription)
            completion(true)
        }

        editAction.backgroundColor = .systemBlue

        return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
    }

    private func showEditSubscriptionAlert(_ subscription: AdBlockSubscription) {
        let alert = UIAlertController(title: "编辑规则订阅", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "订阅名称"
            tf.text = subscription.name
        }
        alert.addTextField { tf in
            tf.placeholder = "订阅 URL"
            tf.text = subscription.urlString
        }

        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let urlStr = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !urlStr.isEmpty else { return }

            AdBlockManager.shared.updateSubscription(id: subscription.id, name: name, urlString: urlStr)
            self?.loadData()
            self?.onRulesChanged?()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showSubscriptionDetail(_ subscription: AdBlockSubscription) {
        let alert = UIAlertController(title: subscription.name, message: subscription.urlString, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "立即更新规则", style: .default) { [weak self] _ in
            guard let self = self else {
                return
            }

            self.loadData()

            AdBlockManager.shared.fetchSubscription(subscription) { [weak self] success, count, compileErr in
                guard let self = self else {
                    return
                }

                self.loadData()

                let message: String
                if success {
                    message = "更新完成，共加载 \(count) 条规则。刷新页面后生效。"
                } else {
                    message = compileErr ?? "规则更新失败，请检查网络链接"
                }

                let result = UIAlertController(
                    title: success ? "规则更新完成" : "规则更新失败",
                    message: message,
                    preferredStyle: .alert
                )

                result.addAction(UIAlertAction(title: "确定", style: .default))
                self.present(result, animated: true)
                self.onRulesChanged?()
            }
        })

        alert.addAction(UIAlertAction(title: "删除订阅", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.subscriptions.removeAll { $0.id == subscription.id }
            AdBlockManager.shared.deleteSubscription(id: subscription.id)
            self.loadData()
            self.onRulesChanged?()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showAddSubscriptionAlert() {
        let alert = UIAlertController(title: "添加规则订阅", message: "请输入规则订阅地址", preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "订阅名称 (如: EasyList)" }
        alert.addTextField { tf in tf.placeholder = "URL (https://...)" }

        alert.addAction(UIAlertAction(title: "添加并更新", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let urlStr = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !urlStr.isEmpty else { return }

            let subscription = AdBlockManager.shared.addSubscription(name: name, urlString: urlStr)
            self?.loadData()

            AdBlockManager.shared.fetchSubscription(subscription) { [weak self] success, count, compileErr in
                guard let self = self else {
                    return
                }

                self.loadData()

                let message: String
                if success {
                    message = "更新完成，共加载 \(count) 条规则。刷新页面后生效。"
                } else {
                    message = compileErr ?? "规则更新失败，请检查网络链接"
                }

                let result = UIAlertController(
                    title: success ? "规则更新完成" : "规则更新失败",
                    message: message,
                    preferredStyle: .alert
                )

                result.addAction(UIAlertAction(title: "确定", style: .default))
                self.present(result, animated: true)
                self.onRulesChanged?()
            }
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}

final class CustomRuleEditorViewController: UIViewController {
    private let textView = UITextView()
    var onSaved: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "自定义过滤规则"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(handleSave))

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.text = AdBlockManager.shared.getCustomRules()

        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    @objc private func handleSave() {
        let rules = textView.text ?? ""

        navigationItem.rightBarButtonItem?.isEnabled = false

        AdBlockManager.shared.saveCustomRules(rules) { [weak self] success in
            guard let self = self else {
                return
            }

            self.navigationItem.rightBarButtonItem?.isEnabled = true

            if success {
                self.onSaved?()
                self.navigationController?.popViewController(animated: true)
            }
        }
    }
}
