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
    private let metadataKey = "adblock_compiled_metadata_v5"
    private let identifierPrefix = "SimpleBrowserAdBlockV5"
    private let nativeRuleChunkSize = 5000
    private let maximumCosmeticRulesPerSource = 400

    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var compiledListsBySource: [String: [WKContentRuleList]] = [:]
    private var cosmeticScriptsBySource: [String: WKUserScript] = [:]
    private var metadataBySource: [String: AdBlockCompiledSourceMetadata] = [:]
    private var updatingSourceIds = Set<String>()
    private let parseQueue = DispatchQueue(label: "SimpleBrowser.AdBlockParser", qos: .userInitiated)

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
        deactivateSource(id: id)
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

        for sourceId in cosmeticScriptsBySource.keys.sorted() {
            if let script = cosmeticScriptsBySource[sourceId] {
                controller.addUserScript(script)
            }
        }
    }

    func fetchSubscription(
        _ subscription: AdBlockSubscription,
        completion: @escaping (Bool, Int, String?) -> Void
    ) {
        guard !updatingSourceIds.contains(subscription.id) else {
            completion(false, 0, "该订阅正在更新，请等待当前任务结束")
            return
        }

        guard let url = URL(string: subscription.urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            completion(false, 0, "订阅地址无效")
            return
        }

        updatingSourceIds.insert(subscription.id)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 1800
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 120
        )

        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Version/17.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        URLSession(configuration: configuration).dataTask(with: request) { [weak self] data, response, error in
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
                    completion(false, 0, "订阅内容不是有效文本")
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

            self.compileSource(id: subscription.id) { success, message in
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)

                    let count = self.ruleCount(sourceId: subscription.id)

                    if success {
                        var subscriptions = self.loadSubscriptions()

                        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                            subscriptions[index].lastUpdated = Date()
                            subscriptions[index].ruleCount = count
                            self.saveSubscriptions(subscriptions)
                        }
                    }

                    completion(success, count, message)
                }
            }
        }.resume()
    }

    private func restorePersistedRules() {
        for sourceId in metadataBySource.keys.sorted() {
            guard let metadata = metadataBySource[sourceId] else {
                continue
            }

            if metadata.ruleListIdentifiers.isEmpty {
                restoreCosmeticScript(metadata: metadata)
                continue
            }

            let group = DispatchGroup()
            var restored = Array<WKContentRuleList?>(repeating: nil, count: metadata.ruleListIdentifiers.count)

            for (index, identifier) in metadata.ruleListIdentifiers.enumerated() {
                group.enter()

                WKContentRuleListStore.default().lookUpContentRuleList(
                    forIdentifier: identifier
                ) { ruleList, _ in
                    restored[index] = ruleList
                    group.leave()
                }
            }

            group.notify(queue: .main) { [weak self] in
                guard let self = self else {
                    return
                }

                let lists = restored.compactMap { $0 }

                guard lists.count == metadata.ruleListIdentifiers.count else {
                    self.compileSource(id: sourceId, completion: nil)
                    return
                }

                self.compiledListsBySource[sourceId] = lists
                self.restoreCosmeticScript(metadata: metadata)
                self.applyRulesToAttachedWebViews()
            }
        }
    }

    private func compileSource(
        id sourceId: String,
        completion: ((Bool, String?) -> Void)?
    ) {
        guard !updatingSourceIds.contains(sourceId) || sourceId == Self.customSourceId else {
            completion?(false, "该规则源正在更新")
            return
        }

        guard let text = sourceText(id: sourceId) else {
            deactivateSource(id: sourceId)
            completion?(true, nil)
            return
        }

        updatingSourceIds.insert(sourceId)

        parseQueue.async { [weak self] in
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
        let version = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        guard !payload.networkChunks.isEmpty else {
            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: [],
                ruleCount: payload.ruleCount,
                skippedRuleCount: payload.skippedRuleCount,
                cosmeticRules: payload.cosmeticRules
            )

            metadataBySource[sourceId] = metadata
            saveMetadata(metadataBySource)

            compiledListsBySource.removeValue(forKey: sourceId)
            restoreCosmeticScript(metadata: metadata)
            updatingSourceIds.remove(sourceId)
            applyRulesToAttachedWebViews()

            let message = payload.skippedRuleCount > 0
                ? "已更新，跳过 \(payload.skippedRuleCount) 条不兼容规则"
                : nil

            completion?(true, message)
            return
        }

        compileChunks(
            payload.networkChunks,
            sourceId: sourceId,
            version: version,
            index: 0,
            lists: [],
            identifiers: [],
            skippedChunks: 0
        ) { [weak self] lists, identifiers, skippedChunks in
            guard let self = self else {
                return
            }

            guard !lists.isEmpty else {
                self.updatingSourceIds.remove(sourceId)
                completion?(false, "所有网络规则块均无法编译")
                return
            }

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                ruleListIdentifiers: identifiers,
                ruleCount: payload.ruleCount,
                skippedRuleCount: payload.skippedRuleCount + skippedChunks * self.nativeRuleChunkSize,
                cosmeticRules: payload.cosmeticRules
            )

            self.metadataBySource[sourceId] = metadata
            self.saveMetadata(self.metadataBySource)

            self.compiledListsBySource[sourceId] = lists
            self.restoreCosmeticScript(metadata: metadata)
            self.updatingSourceIds.remove(sourceId)
            self.applyRulesToAttachedWebViews()

            let skipped = metadata.skippedRuleCount
            let message = skipped > 0
                ? "已更新，跳过约 \(skipped) 条不兼容规则"
                : nil

            completion?(true, message)
        }
    }

    private func compileChunks(
        _ chunks: [String],
        sourceId: String,
        version: String,
        index: Int,
        lists: [WKContentRuleList],
        identifiers: [String],
        skippedChunks: Int,
        completion: @escaping ([WKContentRuleList], [String], Int) -> Void
    ) {
        guard index < chunks.count else {
            completion(lists, identifiers, skippedChunks)
            return
        }

        let identifier = "\(identifierPrefix).\(sourceId.replacingOccurrences(of: "-", with: "")).\(version).\(index)"

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: chunks[index]
        ) { [weak self] ruleList, _ in
            guard let self = self else {
                return
            }

            var nextLists = lists
            var nextIdentifiers = identifiers
            var nextSkippedChunks = skippedChunks

            if let ruleList = ruleList {
                nextLists.append(ruleList)
                nextIdentifiers.append(identifier)
            } else {
                nextSkippedChunks += 1
            }

            self.compileChunks(
                chunks,
                sourceId: sourceId,
                version: version,
                index: index + 1,
                lists: nextLists,
                identifiers: nextIdentifiers,
                skippedChunks: nextSkippedChunks,
                completion: completion
            )
        }
    }

    private func deactivateSource(id sourceId: String) {
        metadataBySource.removeValue(forKey: sourceId)
        compiledListsBySource.removeValue(forKey: sourceId)
        cosmeticScriptsBySource.removeValue(forKey: sourceId)
        updatingSourceIds.remove(sourceId)
        saveMetadata(metadataBySource)
        applyRulesToAttachedWebViews()
    }

    private func restoreCosmeticScript(metadata: AdBlockCompiledSourceMetadata) {
        guard !metadata.cosmeticRules.isEmpty else {
            cosmeticScriptsBySource.removeValue(forKey: metadata.sourceId)
            return
        }

        guard let data = try? JSONEncoder().encode(metadata.cosmeticRules),
              let json = String(data: data, encoding: .utf8) else {
            cosmeticScriptsBySource.removeValue(forKey: metadata.sourceId)
            return
        }

        let source = """
        (function() {
            var rules = \(json);
            var host = (location.hostname || '').toLowerCase();

            function matchesDomain(rule) {
                if (!rule.domains || rule.domains.length === 0) {
                    return true;
                }

                for (var i = 0; i < rule.domains.length; i++) {
                    var domain = rule.domains[i];

                    if (host === domain || host.endsWith('.' + domain)) {
                        return true;
                    }
                }

                return false;
            }

            function hideElement(element) {
                if (!element) {
                    return;
                }

                element.style.setProperty('display', 'none', 'important');
                element.style.setProperty('visibility', 'hidden', 'important');
                element.style.setProperty('pointer-events', 'none', 'important');
            }

            function applyRule(rule) {
                if (!matchesDomain(rule)) {
                    return;
                }

                if (rule.id && !rule.tag && (!rule.classNames || rule.classNames.length === 0) && (!rule.classContains || rule.classContains.length === 0)) {
                    hideElement(document.getElementById(rule.id));
                    return;
                }

                var elements = document.getElementsByTagName(rule.tag || '*');

                for (var i = 0; i < elements.length; i++) {
                    var element = elements[i];

                    if (rule.id && element.id !== rule.id) {
                        continue;
                    }

                    var matched = true;

                    if (rule.classNames && rule.classNames.length > 0) {
                        for (var j = 0; j < rule.classNames.length; j++) {
                            if (!element.classList || !element.classList.contains(rule.classNames[j])) {
                                matched = false;
                                break;
                            }
                        }
                    }

                    if (!matched) {
                        continue;
                    }

                    if (rule.classContains && rule.classContains.length > 0) {
                        var classText = String(element.getAttribute('class') || '');

                        for (var k = 0; k < rule.classContains.length; k++) {
                            if (classText.indexOf(rule.classContains[k]) === -1) {
                                matched = false;
                                break;
                            }
                        }
                    }

                    if (matched) {
                        hideElement(element);
                    }
                }
            }

            function applyAll() {
                for (var i = 0; i < rules.length; i++) {
                    try {
                        applyRule(rules[i]);
                    } catch (_) {
                    }
                }
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', applyAll, { once: true });
            } else {
                applyAll();
            }
        })();
        """

        cosmeticScriptsBySource[metadata.sourceId] = WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    private func sourceText(id sourceId: String) -> String? {
        if sourceId == Self.customSourceId {
            let text = getCustomRules()
            return text.isEmpty ? nil : text
        }

        return try? String(
            contentsOf: subscriptionFileURL(id: sourceId),
            encoding: .utf8
        )
    }

    private func buildSourcePayload(text: String) -> AdBlockSourcePayload {
        var networkChunks: [String] = []
        var currentRules: [[String: Any]] = []
        var cosmeticRules: [AdBlockCosmeticRule] = []
        var ruleCount = 0
        var skippedRuleCount = 0

        text.enumerateLines { line, _ in
            let result = self.parseRule(line)

            if let networkRule = result.networkRule {
                currentRules.append(networkRule)
                ruleCount += 1

                if currentRules.count >= self.nativeRuleChunkSize {
                    if let json = self.jsonString(from: currentRules) {
                        networkChunks.append(json)
                    }
                    currentRules.removeAll(keepingCapacity: true)
                }
            }

            if let cosmeticRule = result.cosmeticRule {
                ruleCount += 1

                if cosmeticRules.count < self.maximumCosmeticRulesPerSource {
                    cosmeticRules.append(cosmeticRule)
                } else {
                    skippedRuleCount += 1
                }
            }

            if result.isUnsupported {
                skippedRuleCount += 1
            }
        }

        if !currentRules.isEmpty,
           let json = jsonString(from: currentRules) {
            networkChunks.append(json)
        }

        return AdBlockSourcePayload(
            networkChunks: networkChunks,
            cosmeticRules: cosmeticRules,
            ruleCount: ruleCount,
            skippedRuleCount: skippedRuleCount
        )
    }

    private func parseRule(_ rawLine: String) -> AdBlockParsedLine {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !line.hasPrefix("！"),
              !line.hasPrefix("[") else {
            return AdBlockParsedLine(networkRule: nil, cosmeticRule: nil, isUnsupported: false)
        }

        if line.contains("#@#") || line.contains("##+js") || line.contains("#%#") {
            return AdBlockParsedLine(networkRule: nil, cosmeticRule: nil, isUnsupported: true)
        }

        if let range = line.range(of: "##") {
            let domainText = String(line[..<range.lowerBound])
            let selector = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let cosmeticRule = parseCosmeticRule(
                selector: selector,
                domains: normalizedDomains(from: domainText).include
            ) else {
                return AdBlockParsedLine(networkRule: nil, cosmeticRule: nil, isUnsupported: true)
            }

            return AdBlockParsedLine(
                networkRule: nil,
                cosmeticRule: cosmeticRule,
                isUnsupported: false
            )
        }

        let isException = line.hasPrefix("@@")

        if isException {
            line = String(line.dropFirst(2))
        }

        let parts = line.split(
            separator: "$",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )

        let rawPattern = String(parts[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawPattern.isEmpty,
              !rawPattern.hasPrefix("/") else {
            return AdBlockParsedLine(networkRule: nil, cosmeticRule: nil, isUnsupported: true)
        }

        let options = parts.count > 1
            ? String(parts[1]).split(separator: ",").map(String.init)
            : []

        var includeDomains: [String] = []
        var excludeDomains: [String] = []
        var resourceTypes: [String] = []
        var loadTypes: [String] = []

        for rawOption in options {
            let option = rawOption.trimmingCharacters(in: .whitespacesAndNewlines)

            if option.hasPrefix("domain=") {
                let domains = normalizedDomains(
                    from: String(option.dropFirst(7)),
                    separator: "|"
                )
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
            } else if option.hasPrefix("~") ||
                        option == "important" ||
                        option == "badfilter" ||
                        option.hasPrefix("redirect") ||
                        option.hasPrefix("rewrite") ||
                        option.hasPrefix("removeparam") ||
                        option.hasPrefix("csp") {
                return AdBlockParsedLine(networkRule: nil, cosmeticRule: nil, isUnsupported: true)
            }
        }

        let filter = urlFilterPattern(from: rawPattern)

        guard !filter.isEmpty,
              (try? NSRegularExpression(pattern: filter)) != nil else {
            return AdBlockParsedLine(networkRule: nil, cosmeticRule: nil, isUnsupported: true)
        }

        var trigger: [String: Any] = [
            "url-filter": filter,
            "url-filter-is-case-sensitive": false
        ]

        if !includeDomains.isEmpty {
            trigger["if-domain"] = Array(Set(includeDomains)).sorted()
        } else if !excludeDomains.isEmpty {
            trigger["unless-domain"] = Array(Set(excludeDomains)).sorted()
        }

        if !resourceTypes.isEmpty {
            trigger["resource-type"] = Array(Set(resourceTypes)).sorted()
        }

        if !loadTypes.isEmpty {
            trigger["load-type"] = Array(Set(loadTypes)).sorted()
        }

        return AdBlockParsedLine(
            networkRule: [
                "trigger": trigger,
                "action": [
                    "type": isException ? "ignore-previous-rules" : "block"
                ]
            ],
            cosmeticRule: nil,
            isUnsupported: false
        )
    }

    private func parseCosmeticRule(
        selector: String,
        domains: [String]
    ) -> AdBlockCosmeticRule? {
        guard !selector.isEmpty,
              selector.count <= 512,
              !selector.contains(":"),
              !selector.contains(">"),
              !selector.contains("+"),
              !selector.contains("~"),
              !selector.contains(","),
              !selector.contains("\u{0000}") else {
            return nil
        }

        let classAttributePattern = #"\[class\*=(?:"([^"]*)"|'([^']*)')\]"#

        guard let regex = try? NSRegularExpression(pattern: classAttributePattern) else {
            return nil
        }

        let nsRange = NSRange(selector.startIndex..<selector.endIndex, in: selector)
        let matches = regex.matches(in: selector, range: nsRange)

        var classContains: [String] = []

        for match in matches {
            let firstRange = match.range(at: 1)
            let secondRange = match.range(at: 2)

            if firstRange.location != NSNotFound,
               let range = Range(firstRange, in: selector) {
                classContains.append(String(selector[range]))
            } else if secondRange.location != NSNotFound,
                      let range = Range(secondRange, in: selector) {
                classContains.append(String(selector[range]))
            }
        }

        let remaining = regex.stringByReplacingMatches(
            in: selector,
            range: nsRange,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if remaining.hasPrefix("#") {
            let id = String(remaining.dropFirst())

            guard isSafeIdentifier(id) else {
                return nil
            }

            return AdBlockCosmeticRule(
                domains: domains,
                tag: nil,
                id: id,
                classNames: [],
                classContains: classContains
            )
        }

        if remaining.hasPrefix(".") {
            let className = String(remaining.dropFirst())

            guard isSafeIdentifier(className) else {
                return nil
            }

            return AdBlockCosmeticRule(
                domains: domains,
                tag: nil,
                id: nil,
                classNames: [className],
                classContains: classContains
            )
        }

        if remaining.contains("#") {
            let parts = remaining.split(separator: "#", maxSplits: 1).map(String.init)

            guard parts.count == 2,
                  isSafeTag(parts[0]),
                  isSafeIdentifier(parts[1]) else {
                return nil
            }

            return AdBlockCosmeticRule(
                domains: domains,
                tag: parts[0].lowercased(),
                id: parts[1],
                classNames: [],
                classContains: classContains
            )
        }

        if remaining.contains(".") {
            let parts = remaining.split(separator: ".", maxSplits: 1).map(String.init)

            guard parts.count == 2,
                  isSafeTag(parts[0]),
                  isSafeIdentifier(parts[1]) else {
                return nil
            }

            return AdBlockCosmeticRule(
                domains: domains,
                tag: parts[0].lowercased(),
                id: nil,
                classNames: [parts[1]],
                classContains: classContains
            )
        }

        if remaining.isEmpty {
            guard !classContains.isEmpty else {
                return nil
            }

            return AdBlockCosmeticRule(
                domains: domains,
                tag: nil,
                id: nil,
                classNames: [],
                classContains: classContains
            )
        }

        guard isSafeTag(remaining) else {
            return nil
        }

        return AdBlockCosmeticRule(
            domains: domains,
            tag: remaining.lowercased(),
            id: nil,
            classNames: [],
            classContains: classContains
        )
    }

    private func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }

        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )

        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func isSafeTag(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }

        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
        )

        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
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

            guard !domain.isEmpty else {
                return ""
            }

            let escaped = NSRegularExpression.escapedPattern(for: domain)
            return "https?://([^/]+\\.)?\(escaped)([:/].*)?"
        }

        var escaped = NSRegularExpression.escapedPattern(for: pattern)
        escaped = escaped.replacingOccurrences(of: "\\*", with: ".*")
        escaped = escaped.replacingOccurrences(of: "\\^", with: "[^A-Za-z0-9_\\-.%]")
        return ".*\(escaped).*"
    }

    private func jsonString(from rules: [[String: Any]]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func subscriptionFileURL(id: String) -> URL {
        let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        return directory.appendingPathComponent(
            "adblock_subscription_\(id).txt"
        )
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

    private func saveMetadata(
        _ metadata: [String: AdBlockCompiledSourceMetadata]
    ) {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return
        }

        UserDefaults.standard.set(data, forKey: metadataKey)
    }
}

struct AdBlockCompiledSourceMetadata: Codable {
    var sourceId: String
    var ruleListIdentifiers: [String]
    var ruleCount: Int
    var skippedRuleCount: Int
    var cosmeticRules: [AdBlockCosmeticRule]
}

private struct AdBlockSourcePayload {
    var networkChunks: [String]
    var cosmeticRules: [AdBlockCosmeticRule]
    var ruleCount: Int
    var skippedRuleCount: Int
}

private struct AdBlockParsedLine {
    var networkRule: [String: Any]?
    var cosmeticRule: AdBlockCosmeticRule?
    var isUnsupported: Bool
}

private struct AdBlockCosmeticRule: Codable {
    var domains: [String]
    var tag: String?
    var id: String?
    var classNames: [String]
    var classContains: [String]
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

                let message: String

                if success {
                    if let errorMessage = errorMessage, !errorMessage.isEmpty {
                        message = "更新完成，共加载 \(count) 条规则。\n\(errorMessage)\n刷新页面后生效。"
                    } else {
                        message = "更新完成，共加载 \(count) 条规则。刷新页面后生效。"
                    }
                } else {
                    message = errorMessage ?? "规则更新失败，未返回具体原因"
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

            AdBlockManager.shared.fetchSubscription(subscription) { [weak self] success, count, errorMessage in
                guard let self = self else {
                    return
                }

                self.loadData()

                let message: String

                if success {
                    if let errorMessage = errorMessage, !errorMessage.isEmpty {
                        message = "更新完成，共加载 \(count) 条规则。\n\(errorMessage)\n刷新页面后生效。"
                    } else {
                        message = "更新完成，共加载 \(count) 条规则。刷新页面后生效。"
                    }
                } else {
                    message = errorMessage ?? "规则更新失败，未返回具体原因"
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
