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

final class AdBlockManager {
    static let shared = AdBlockManager()

    static let customSourceId = "__custom_rules__"

    private let enabledKey = "adblock_enabled_v2"
    private let subscriptionsKey = "adblock_subscriptions_v2"
    private let customRulesKey = "adblock_custom_rules_v2"
    private let metadataKey = "adblock_compiled_metadata_v4"
    private let identifierPrefix = "SimpleBrowserAdBlockV4"
    private let nativeRuleChunkSize = 1500
    private let cosmeticScriptPayloadLimit = 180_000
    private let cosmeticSelectorsPerEntry = 600

    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var compiledListsBySource: [String: [WKContentRuleList]] = [:]
    private var cssScriptsBySource: [String: [WKUserScript]] = [:]
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

        for sourceId in compiledListsBySource.keys.sorted() {
            for ruleList in compiledListsBySource[sourceId] ?? [] {
                controller.add(ruleList)
            }
        }

        for sourceId in cssScriptsBySource.keys.sorted() {
            for script in cssScriptsBySource[sourceId] ?? [] {
                controller.addUserScript(script)
            }
        }
    }

    func fetchSubscription(
        _ subscription: AdBlockSubscription,
        completion: @escaping (Bool, Int, String?) -> Void
    ) {
        guard let url = URL(string: subscription.urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            completion(false, 0, "订阅地址无效")
            return
        }

        updatingSourceIds.insert(subscription.id)

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 90
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
                    completion(false, 0, error.localizedDescription)
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    completion(false, 0, "服务器未返回 HTTP 响应")
                }
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    completion(false, 0, "服务器返回 HTTP \(httpResponse.statusCode)")
                }
                return
            }

            guard let data = data, !data.isEmpty else {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    completion(false, 0, "订阅内容为空")
                }
                return
            }

            let text = String(decoding: data, as: UTF8.self)

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    completion(false, 0, "订阅内容无法识别为有效文本")
                }
                return
            }

            do {
                try text.write(
                    to: self.subscriptionFileURL(id: subscription.id),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    completion(false, 0, "订阅文件保存失败：\(error.localizedDescription)")
                }
                return
            }

            self.compileSource(id: subscription.id) { success, errorMessage in
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)

                    let compiledRules = self.ruleCount(sourceId: subscription.id)

                    if success {
                        var subscriptions = self.loadSubscriptions()

                        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                            subscriptions[index].lastUpdated = Date()
                            subscriptions[index].ruleCount = compiledRules
                            self.saveSubscriptions(subscriptions)
                        }
                    }

                    completion(success, compiledRules, errorMessage)
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
                restoreCSSScripts(metadata: metadata)
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
                    self.restoreCSSScripts(metadata: metadata)
                    self.applyRulesToAttachedWebViews()
                } else {
                    self.compileSource(id: sourceId, completion: nil)
                }
            }
        }
    }

    private func restoreCSSScripts(metadata: AdBlockCompiledSourceMetadata) {
        guard !metadata.cssScripts.isEmpty else {
            cssScriptsBySource.removeValue(forKey: metadata.sourceId)
            return
        }

        cssScriptsBySource[metadata.sourceId] = metadata.cssScripts.map {
            WKUserScript(
                source: $0,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        }
    }

    private func compileSource(
        id sourceId: String,
        completion: ((Bool, String?) -> Void)?
    ) {
        guard let text = sourceText(id: sourceId) else {
            removeSource(id: sourceId)
            completion?(true, nil)
            return
        }

        updatingSourceIds.insert(sourceId)

        workQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            let payload = self.buildSourcePayload(text: text)

            DispatchQueue.main.async {
                self.compilePayload(
                    payload,
                    sourceId: sourceId,
                    completion: completion
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
                cssScripts: payload.cssScripts
            )

            metadataBySource[sourceId] = metadata
            saveMetadata(metadataBySource)

            compiledListsBySource.removeValue(forKey: sourceId)
            restoreCSSScripts(metadata: metadata)
            updatingSourceIds.remove(sourceId)

            if let oldMetadata = oldMetadata {
                removeStoredRuleLists(metadata: oldMetadata)
            }

            applyRulesToAttachedWebViews()
            completion?(true, nil)
            return
        }

        compileChunk(
            payload.chunkJSONStrings,
            sourceId: sourceId,
            version: newVersion,
            index: 0,
            lists: []
        ) { [weak self] lists, errorMessage in
            guard let self = self else {
                return
            }

            if let errorMessage = errorMessage {
                self.updatingSourceIds.remove(sourceId)
                completion?(false, errorMessage)
                return
            }

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                version: newVersion,
                chunkCount: lists.count,
                ruleCount: payload.ruleCount,
                cssScripts: payload.cssScripts
            )

            self.metadataBySource[sourceId] = metadata
            self.saveMetadata(self.metadataBySource)

            self.compiledListsBySource[sourceId] = lists
            self.restoreCSSScripts(metadata: metadata)
            self.updatingSourceIds.remove(sourceId)

            if let oldMetadata = oldMetadata {
                self.removeStoredRuleLists(metadata: oldMetadata)
            }

            self.applyRulesToAttachedWebViews()
            completion?(true, nil)
        }
    }

    private func compileChunk(
        _ jsonStrings: [String],
        sourceId: String,
        version: String,
        index: Int,
        lists: [WKContentRuleList],
        completion: @escaping ([WKContentRuleList], String?) -> Void
    ) {
        if index >= jsonStrings.count {
            completion(lists, nil)
            return
        }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ruleListIdentifier(
                sourceId: sourceId,
                version: version,
                index: index
            ),
            encodedContentRuleList: jsonStrings[index]
        ) { [weak self] ruleList, error in
            guard let self = self else {
                return
            }

            guard let ruleList = ruleList else {
                let message = error?.localizedDescription ?? "第 \(index + 1) 个规则块编译失败"
                completion(lists, message)
                return
            }

            var nextLists = lists
            nextLists.append(ruleList)

            self.compileChunk(
                jsonStrings,
                sourceId: sourceId,
                version: version,
                index: index + 1,
                lists: nextLists,
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
        var domSelectorsByDomain: [String: Set<String>] = [:]
        var ruleCount = 0

        text.enumerateLines { line, _ in
            let result = self.parseABPLine(line)

            for rule in result.networkRules {
                currentRules.append(rule)

                if currentRules.count >= self.nativeRuleChunkSize {
                    if let json = self.jsonString(from: currentRules) {
                        chunks.append(json)
                    }
                    currentRules.removeAll(keepingCapacity: true)
                }
            }

            for (domain, selectors) in result.domSelectors {
                domSelectorsByDomain[domain, default: []].formUnion(selectors)
            }

            if !result.networkRules.isEmpty || !result.domSelectors.isEmpty {
                ruleCount += 1
            }
        }

        if !currentRules.isEmpty,
           let json = jsonString(from: currentRules) {
            chunks.append(json)
        }

        return AdBlockSourcePayload(
            chunkJSONStrings: chunks,
            cssScripts: domHidingScripts(from: domSelectorsByDomain),
            ruleCount: ruleCount
        )
    }

    private func parseABPLine(_ rawLine: String) -> AdBlockParsedLine {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !line.hasPrefix("！"),
              !line.hasPrefix("[") else {
            return AdBlockParsedLine(networkRules: [], domSelectors: [:])
        }

        if let range = line.range(of: "##") {
            let domainsText = String(line[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let selectorsText = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !selectorsText.isEmpty else {
                return AdBlockParsedLine(networkRules: [], domSelectors: [:])
            }

            let domains = normalizedDomains(from: domainsText)
            let selectorParts = splitSelectorList(selectorsText)

            var selectors = Set<String>()

            for selector in selectorParts {
                let cleaned = selector.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !cleaned.isEmpty,
                      cleaned.count <= 4096,
                      !cleaned.contains("\u{0000}") else {
                    continue
                }

                selectors.insert(cleaned)
            }

            guard !selectors.isEmpty else {
                return AdBlockParsedLine(networkRules: [], domSelectors: [:])
            }

            let key = domains.include.isEmpty
                ? "*"
                : domains.include.sorted().joined(separator: ",")

            return AdBlockParsedLine(
                networkRules: [],
                domSelectors: [key: selectors]
            )
        }

        let isException = line.hasPrefix("@@")

        if isException {
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
            return AdBlockParsedLine(networkRules: [], domSelectors: [:])
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
            domSelectors: [:]
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
        if pattern.hasPrefix("||") {
            let domain = String(pattern.dropFirst(2))
                .replacingOccurrences(of: "^", with: "")
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            return "https?://([^/]+\\.)?\(escaped)([:/].*)?"
        }

        var escaped = NSRegularExpression.escapedPattern(for: pattern)
        escaped = escaped.replacingOccurrences(of: "\\*", with: ".*")
        escaped = escaped.replacingOccurrences(of: "\\^", with: "[^A-Za-z0-9_\\-.%]")
        return ".*\(escaped).*"
    }

    private func domHidingScripts(from table: [String: Set<String>]) -> [String] {
        guard !table.isEmpty else {
            return []
        }

        var entries: [[String: Any]] = []

        for domainsText in table.keys.sorted() {
            guard let selectors = table[domainsText] else {
                continue
            }

            let domains = domainsText == "*"
                ? []
                : domainsText.split(separator: ",").map(String.init)

            var remaining = selectors.sorted()

            while !remaining.isEmpty {
                let count = min(cosmeticSelectorsPerEntry, remaining.count)
                let selectorPart = Array(remaining.prefix(count))
                remaining.removeFirst(count)

                entries.append([
                    "domains": domains,
                    "selectors": selectorPart
                ])
            }
        }

        var batches: [[[String: Any]]] = []
        var currentBatch: [[String: Any]] = []

        for entry in entries {
            var candidate = currentBatch
            candidate.append(entry)

            let candidateSize = (try? JSONSerialization.data(withJSONObject: candidate))?.count ?? 0

            if candidateSize > cosmeticScriptPayloadLimit,
               !currentBatch.isEmpty {
                batches.append(currentBatch)
                currentBatch = [entry]
            } else {
                currentBatch = candidate
            }
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }

        return batches.compactMap { batch in
            guard let data = try? JSONSerialization.data(withJSONObject: batch),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }

            return """
            (function() {
                var host = (location.hostname || '').toLowerCase();
                var rules = \(json);
                var styleId = '__simple_browser_adblock_style__';
                var style = document.getElementById(styleId);

                if (!style) {
                    style = document.createElement('style');
                    style.id = styleId;
                    style.type = 'text/css';
                    (document.head || document.documentElement).appendChild(style);
                }

                var sheet = style.sheet;

                if (!sheet) {
                    return;
                }

                for (var i = 0; i < rules.length; i++) {
                    var item = rules[i];
                    var matched = item.domains.length === 0;

                    if (!matched) {
                        for (var j = 0; j < item.domains.length; j++) {
                            var domain = item.domains[j];

                            if (host === domain || host.endsWith('.' + domain)) {
                                matched = true;
                                break;
                            }
                        }
                    }

                    if (!matched) {
                        continue;
                    }

                    for (var k = 0; k < item.selectors.length; k++) {
                        try {
                            sheet.insertRule(
                                item.selectors[k] + '{display:none !important;visibility:hidden !important;pointer-events:none !important;}',
                                sheet.cssRules.length
                            );
                        } catch (_) {
                        }
                    }
                }
            })();
            """
        }
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

struct AdBlockCompiledSourceMetadata: Codable {
    var sourceId: String
    var version: String
    var chunkCount: Int
    var ruleCount: Int
    var cssScripts: [String]
}

private struct AdBlockSourcePayload {
    var chunkJSONStrings: [String]
    var cssScripts: [String]
    var ruleCount: Int
}

private struct AdBlockParsedLine {
    var networkRules: [[String: Any]]
    var domSelectors: [String: Set<String>]
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

            AdBlockManager.shared.fetchSubscription(subscription) { [weak self] success, count, errorMessage in
                guard let self = self else {
                    return
                }

                self.loadData()

                let message = success
                    ? "更新完成，共加载 \(count) 条规则。刷新页面后生效。"
                    : (errorMessage ?? "规则更新失败，未返回具体原因")

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

            AdBlockManager.shared.fetchSubscription(subscription) { [weak self] success, count, errorMessage in
                guard let self = self else {
                    return
                }

                self.loadData()

                let message = success
                    ? "更新完成，共加载 \(count) 条规则。刷新页面后生效。"
                    : (errorMessage ?? "规则更新失败，未返回具体原因")

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
