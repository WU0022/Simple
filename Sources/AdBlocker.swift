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
    private let metadataKey = "adblock_compiled_metadata_v7"
    private let identifierPrefix = "SimpleBrowserAdBlockV7"
    private let nativeRuleChunkSize = 1500
    private let maximumNativeRulesPerSource = 150000
    private let maximumCosmeticRulesPerSource = 150000
    private let cosmeticScriptPayloadLimit = 180000

    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var compiledListsBySource: [String: [WKContentRuleList]] = [:]
    private var cosmeticScriptsBySource: [String: [WKUserScript]] = [:]
    private var metadataBySource: [String: AdBlockCompiledSourceMetadata] = [:]
    private var updatingSourceIds = Set<String>()
    private var updateStatusBySource: [String: String] = [:]
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

    func saveCustomRules(
        _ rules: String,
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        guard !updatingSourceIds.contains(Self.customSourceId) else {
            completion?(false, "自定义规则正在保存")
            return
        }

        UserDefaults.standard.set(rules, forKey: customRulesKey)
        setUpdateStatus(
            sourceId: Self.customSourceId,
            status: "正在解析自定义规则…"
        )

        compileSource(id: Self.customSourceId) { [weak self] success, message in
            self?.setUpdateStatus(
                sourceId: Self.customSourceId,
                status: nil
            )
            completion?(success, message)
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

    func updateStatus(sourceId: String) -> String? {
        updateStatusBySource[sourceId]
    }

    private func setUpdateStatus(
        sourceId: String,
        status: String?
    ) {
        if let status = status {
            updateStatusBySource[sourceId] = status
        } else {
            updateStatusBySource.removeValue(forKey: sourceId)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("AdBlockStatusChanged"),
                object: nil
            )
        }
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
            for script in cosmeticScriptsBySource[sourceId] ?? [] {
                controller.addUserScript(script)
            }
        }
    }

    private func applyRulesToAttachedWebViews() {
        for webView in attachedWebViews.allObjects {
            applyRules(to: webView)
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
        setUpdateStatus(
            sourceId: subscription.id,
            status: "正在下载订阅…"
        )

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
                    self.setUpdateStatus(
                        sourceId: subscription.id,
                        status: nil
                    )
                    completion(false, 0, error.localizedDescription)
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    self.setUpdateStatus(
                        sourceId: subscription.id,
                        status: nil
                    )
                    completion(false, 0, "服务器未返回 HTTP 响应")
                }
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    self.setUpdateStatus(
                        sourceId: subscription.id,
                        status: nil
                    )
                    completion(false, 0, "服务器返回 HTTP \(httpResponse.statusCode)")
                }
                return
            }

            guard let data = data, !data.isEmpty else {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    self.setUpdateStatus(
                        sourceId: subscription.id,
                        status: nil
                    )
                    completion(false, 0, "订阅内容为空")
                }
                return
            }

            let text = String(decoding: data, as: UTF8.self)

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    self.setUpdateStatus(
                        sourceId: subscription.id,
                        status: nil
                    )
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
                    self.setUpdateStatus(
                        sourceId: subscription.id,
                        status: nil
                    )
                    completion(false, 0, "订阅文件保存失败：\(error.localizedDescription)")
                }
                return
            }

            self.setUpdateStatus(
                sourceId: subscription.id,
                status: "正在解析规则…"
            )

            self.compileSource(id: subscription.id, isAlreadyUpdating: true) { success, message in
                DispatchQueue.main.async {
                    self.updatingSourceIds.remove(subscription.id)
                    self.setUpdateStatus(
                        sourceId: subscription.id,
                        status: nil
                    )

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

            guard !metadata.ruleListIdentifiers.isEmpty else {
                restoreCosmeticScripts(metadata: metadata)
                continue
            }

            let group = DispatchGroup()
            var restored = Array<WKContentRuleList?>(
                repeating: nil,
                count: metadata.ruleListIdentifiers.count
            )

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
                    var repairedMetadata = metadata
                    repairedMetadata.ruleListIdentifiers = []

                    self.metadataBySource[sourceId] = repairedMetadata
                    self.compiledListsBySource.removeValue(forKey: sourceId)

                    self.saveMetadata(self.metadataBySource)
                    self.restoreCosmeticScripts(metadata: repairedMetadata)
                    self.applyRulesToAttachedWebViews()
                    return
                }

                self.compiledListsBySource[sourceId] = lists
                self.restoreCosmeticScripts(metadata: metadata)
                self.applyRulesToAttachedWebViews()
            }
        }
    }

    private func compileSource(
        id sourceId: String,
        isAlreadyUpdating: Bool = false,
        completion: ((Bool, String?) -> Void)?
    ) {
        if !isAlreadyUpdating && updatingSourceIds.contains(sourceId) {
            completion?(false, "该规则源正在更新")
            return
        }

        guard let text = sourceText(id: sourceId) else {
            deactivateSource(id: sourceId)
            completion?(true, nil)
            return
        }

        updatingSourceIds.insert(sourceId)

        if updateStatusBySource[sourceId] == nil {
            setUpdateStatus(
                sourceId: sourceId,
                status: "正在解析规则…"
            )
        }

        parseQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            let payload = self.buildSourcePayload(text: text)

            DispatchQueue.main.async {
                self.setUpdateStatus(
                    sourceId: sourceId,
                    status: "正在编译规则…"
                )

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
        let targetSlot = (oldMetadata?.activeSlot == "a") ? "b" : "a"
        let version = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        guard !payload.networkChunks.isEmpty else {
            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                activeSlot: targetSlot,
                ruleListIdentifiers: [],
                ruleCount: payload.ruleCount,
                skippedRuleCount: payload.skippedRuleCount,
                cosmeticRules: payload.cosmeticRules
            )

            metadataBySource[sourceId] = metadata
            saveMetadata(metadataBySource)

            compiledListsBySource.removeValue(forKey: sourceId)
            restoreCosmeticScripts(metadata: metadata)
            updatingSourceIds.remove(sourceId)
            setUpdateStatus(
                sourceId: sourceId,
                status: nil
            )

            if let oldMetadata = oldMetadata {
                removeStoredRuleLists(metadata: oldMetadata)
            }

            applyRulesToAttachedWebViews()

            let message = payload.skippedRuleCount > 0
                ? "已更新，跳过 \(payload.skippedRuleCount) 条不兼容规则"
                : nil

            completion?(true, message)
            return
        }

        compileChunksSequentially(
            payload.networkChunks,
            sourceId: sourceId,
            slot: targetSlot,
            version: version,
            index: 0,
            compiledLists: [],
            compiledIdentifiers: [],
            skippedCount: 0
        ) { [weak self] lists, identifiers, extraSkipped in
            guard let self = self else { return }

            let totalSkipped = payload.skippedRuleCount + (extraSkipped * self.nativeRuleChunkSize)

            let metadata = AdBlockCompiledSourceMetadata(
                sourceId: sourceId,
                activeSlot: targetSlot,
                ruleListIdentifiers: identifiers,
                ruleCount: payload.ruleCount - (extraSkipped * self.nativeRuleChunkSize),
                skippedRuleCount: totalSkipped,
                cosmeticRules: payload.cosmeticRules
            )

            self.metadataBySource[sourceId] = metadata
            self.saveMetadata(self.metadataBySource)
            self.compiledListsBySource[sourceId] = lists
            self.restoreCosmeticScripts(metadata: metadata)
            self.updatingSourceIds.remove(sourceId)
            self.setUpdateStatus(
                sourceId: sourceId,
                status: nil
            )

            if let oldMetadata = oldMetadata {
                self.removeStoredRuleLists(metadata: oldMetadata)
            }

            self.applyRulesToAttachedWebViews()

            let message = totalSkipped > 0 ? "已加载，但跳过了 \(totalSkipped) 条不兼容规则" : nil
            completion?(true, message)
        }
    }

    private func compileChunksSequentially(
        _ chunks: [[[String: Any]]],
        sourceId: String,
        slot: String,
        version: String,
        index: Int,
        compiledLists: [WKContentRuleList],
        compiledIdentifiers: [String],
        skippedCount: Int,
        completion: @escaping ([WKContentRuleList], [String], Int) -> Void
    ) {
        guard index < chunks.count else {
            completion(compiledLists, compiledIdentifiers, skippedCount)
            return
        }

        setUpdateStatus(
            sourceId: sourceId,
            status: "正在编译规则 \(index + 1)/\(chunks.count)…"
        )

        let identifier = "\(identifierPrefix).\(sourceId.replacingOccurrences(of: "-", with: "")).\(slot).\(index)"

        guard let data = try? JSONSerialization.data(withJSONObject: chunks[index]),
              let jsonString = String(data: data, encoding: .utf8) else {
            compileChunksSequentially(
                chunks,
                sourceId: sourceId,
                slot: slot,
                version: version,
                index: index + 1,
                compiledLists: compiledLists,
                compiledIdentifiers: compiledIdentifiers,
                skippedCount: skippedCount + 1,
                completion: completion
            )
            return
        }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: jsonString
        ) { [weak self] ruleList, _ in
            guard let self = self else { return }

            var nextLists = compiledLists
            var nextIdentifiers = compiledIdentifiers
            var nextSkipped = skippedCount

            if let ruleList = ruleList {
                nextLists.append(ruleList)
                nextIdentifiers.append(identifier)
            } else {
                nextSkipped += 1
            }

            DispatchQueue.main.async {
                self.compileChunksSequentially(
                    chunks,
                    sourceId: sourceId,
                    slot: slot,
                    version: version,
                    index: index + 1,
                    compiledLists: nextLists,
                    compiledIdentifiers: nextIdentifiers,
                    skippedCount: nextSkipped,
                    completion: completion
                )
            }
        }
    }

    private func deactivateSource(id sourceId: String) {
        let oldMetadata = metadataBySource.removeValue(forKey: sourceId)
        compiledListsBySource.removeValue(forKey: sourceId)
        cosmeticScriptsBySource.removeValue(forKey: sourceId)
        updatingSourceIds.remove(sourceId)
        setUpdateStatus(
            sourceId: sourceId,
            status: nil
        )
        saveMetadata(metadataBySource)

        if let oldMetadata = oldMetadata {
            removeStoredRuleLists(metadata: oldMetadata)
        }

        applyRulesToAttachedWebViews()
    }

    private func removeStoredRuleLists(metadata: AdBlockCompiledSourceMetadata) {
        for identifier in metadata.ruleListIdentifiers {
            WKContentRuleListStore.default().removeContentRuleList(
                forIdentifier: identifier,
                completionHandler: nil
            )
        }
    }

    private func restoreCosmeticScripts(metadata: AdBlockCompiledSourceMetadata) {
        guard !metadata.cosmeticRules.isEmpty else {
            cosmeticScriptsBySource.removeValue(forKey: metadata.sourceId)
            return
        }

        let batches = cosmeticRuleBatches(metadata.cosmeticRules)

        cosmeticScriptsBySource[metadata.sourceId] = batches.compactMap { rules in
            guard let data = try? JSONEncoder().encode(rules),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }

            let source = """
            (function() {
                var rules = \(json);
                var fallbackRules = [];
                var styleId = '__simple_browser_adblock_style__';
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

                function hideBySelector(selector) {
                    try {
                        var elements = document.querySelectorAll(selector);

                        for (var i = 0; i < elements.length; i++) {
                            hideElement(elements[i]);
                        }

                        return true;
                    } catch (_) {
                        return false;
                    }
                }

                function hideByHasFallback(selector) {
                    var hasIndex = selector.indexOf(':has(');

                    if (hasIndex < 0 || !selector.endsWith(')')) {
                        return;
                    }

                    var outerSelector = selector.substring(0, hasIndex).trim() || '*';
                    var innerSelector = selector.substring(hasIndex + 5, selector.length - 1).trim();

                    if (!innerSelector) {
                        return;
                    }

                    var outerElements;

                    try {
                        outerElements = document.querySelectorAll(outerSelector);
                    } catch (_) {
                        return;
                    }

                    for (var i = 0; i < outerElements.length; i++) {
                        var outerElement = outerElements[i];
                        var matched = false;

                        try {
                            if (innerSelector.startsWith('>')) {
                                matched = outerElement.querySelector(':scope ' + innerSelector) !== null;
                            } else {
                                matched = outerElement.querySelector(innerSelector) !== null;
                            }
                        } catch (_) {
                            matched = false;
                        }

                        if (matched) {
                            hideElement(outerElement);
                        }
                    }
                }

                function applyFallbackRules() {
                    for (var i = 0; i < fallbackRules.length; i++) {
                        var rule = fallbackRules[i];

                        if (!matchesDomain(rule)) {
                            continue;
                        }

                        if (!hideBySelector(rule.selector)) {
                            hideByHasFallback(rule.selector);
                        }
                    }
                }

                function insertRules() {
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
                        var rule = rules[i];

                        if (!matchesDomain(rule)) {
                            continue;
                        }

                        try {
                            sheet.insertRule(
                                rule.selector + '{display:none !important;visibility:hidden !important;pointer-events:none !important;}',
                                sheet.cssRules.length
                            );
                        } catch (_) {
                            fallbackRules.push(rule);
                        }
                    }

                    applyFallbackRules();
                }

                function scheduleFallbackApply() {
                    var timer = null;

                    var observer = new MutationObserver(function() {
                        if (timer !== null) {
                            return;
                        }

                        timer = setTimeout(function() {
                            timer = null;
                            applyFallbackRules();
                        }, 300);
                    });

                    observer.observe(document.documentElement, {
                        childList: true,
                        subtree: true
                    });
                }

                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', function() {
                        insertRules();

                        if (fallbackRules.length > 0) {
                            scheduleFallbackApply();
                        }
                    }, { once: true });
                } else {
                    insertRules();

                    if (fallbackRules.length > 0) {
                        scheduleFallbackApply();
                    }
                }
            })();
            """

            return WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        }
    }

    private func cosmeticRuleBatches(
        _ rules: [AdBlockCosmeticRule]
    ) -> [[AdBlockCosmeticRule]] {
        var result: [[AdBlockCosmeticRule]] = []
        var current: [AdBlockCosmeticRule] = []

        for rule in rules {
            var candidate = current
            candidate.append(rule)

            let size = (try? JSONEncoder().encode(candidate).count) ?? 0

            if size > cosmeticScriptPayloadLimit && !current.isEmpty {
                result.append(current)
                current = [rule]
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
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
        var networkChunks: [[[String: Any]]] = []
        var currentRules: [[String: Any]] = []
        var cosmeticRules: [AdBlockCosmeticRule] = []
        var acceptedNetworkRuleCount = 0
        var skippedRuleCount = 0

        text.enumerateLines { line, _ in
            let result = self.parseRule(line)

            if let networkRule = result.networkRule {
                if acceptedNetworkRuleCount < self.maximumNativeRulesPerSource {
                    currentRules.append(networkRule)
                    acceptedNetworkRuleCount += 1

                    if currentRules.count >= self.nativeRuleChunkSize {
                        networkChunks.append(currentRules)
                        currentRules.removeAll(keepingCapacity: true)
                    }
                } else {
                    skippedRuleCount += 1
                }
            }

            for cosmeticRule in result.cosmeticRules {
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

        if !currentRules.isEmpty {
            networkChunks.append(currentRules)
        }

        return AdBlockSourcePayload(
            networkChunks: networkChunks,
            cosmeticRules: cosmeticRules,
            ruleCount: acceptedNetworkRuleCount + cosmeticRules.count,
            skippedRuleCount: skippedRuleCount
        )
    }

    private func parseRule(_ rawLine: String) -> AdBlockParsedLine {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !line.hasPrefix("！"),
              !line.hasPrefix("[") else {
            return AdBlockParsedLine(
                networkRule: nil,
                cosmeticRules: [],
                isUnsupported: false
            )
        }

        if line.contains("#@#") || line.contains("##+js") || line.contains("#%#") {
            return AdBlockParsedLine(
                networkRule: nil,
                cosmeticRules: [],
                isUnsupported: true
            )
        }

        if let range = line.range(of: "##") {
            let domainsText = String(line[..<range.lowerBound])
            let selectorsText = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let domains = normalizedDomains(from: domainsText).include
            let selectors = splitSelectorList(selectorsText)

            let cosmeticRules = selectors.compactMap { selector in
                parseCosmeticRule(selector: selector, domains: domains)
            }

            return AdBlockParsedLine(
                networkRule: nil,
                cosmeticRules: cosmeticRules,
                isUnsupported: cosmeticRules.count != selectors.count
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
            return AdBlockParsedLine(
                networkRule: nil,
                cosmeticRules: [],
                isUnsupported: true
            )
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
                return AdBlockParsedLine(
                    networkRule: nil,
                    cosmeticRules: [],
                    isUnsupported: true
                )
            }
        }

        let filter = urlFilterPattern(from: rawPattern)

        guard !filter.isEmpty,
              (try? NSRegularExpression(pattern: filter)) != nil else {
            return AdBlockParsedLine(
                networkRule: nil,
                cosmeticRules: [],
                isUnsupported: true
            )
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
            cosmeticRules: [],
            isUnsupported: false
        )
    }

    private func parseCosmeticRule(
        selector: String,
        domains: [String]
    ) -> AdBlockCosmeticRule? {
        let value = selector.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty,
              value.count <= 4096,
              !value.contains("\u{0000}"),
              !value.contains("{"),
              !value.contains("}"),
              !value.contains(";"),
              !value.contains("<"),
              !value.contains(">style") else {
            return nil
        }

        return AdBlockCosmeticRule(
            domains: domains,
            selector: value
        )
    }

    private func splitSelectorList(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var parenthesesDepth = 0
        var bracketsDepth = 0
        var quote: Character?

        for character in text {
            if let currentQuote = quote {
                current.append(character)

                if character == currentQuote {
                    quote = nil
                }

                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                continue
            }

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
                    result.append(value)
                }

                current = ""
            } else {
                current.append(character)
            }
        }

        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)

        if !value.isEmpty {
            result.append(value)
        }

        return result
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
    var activeSlot: String
    var ruleListIdentifiers: [String]
    var ruleCount: Int
    var skippedRuleCount: Int
    var cosmeticRules: [AdBlockCosmeticRule]
}

private struct AdBlockSourcePayload {
    var networkChunks: [[[String: Any]]]
    var cosmeticRules: [AdBlockCosmeticRule]
    var ruleCount: Int
    var skippedRuleCount: Int
}

private struct AdBlockParsedLine {
    var networkRule: [String: Any]?
    var cosmeticRules: [AdBlockCosmeticRule]
    var isUnsupported: Bool
}

private final class AdBlockChunkCompilationGate {
    private let lock = NSLock()
    private var resolved = false

    func resolve(_ handler: () -> Void) {
        lock.lock()

        guard !resolved else {
            lock.unlock()
            return
        }

        resolved = true
        lock.unlock()

        handler()
    }
}

struct AdBlockCosmeticRule: Codable {
    var domains: [String]
    var selector: String
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStatusChanged),
            name: NSNotification.Name("AdBlockStatusChanged"),
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleStatusChanged() {
        tableView.reloadData()
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
                    cell.detailTextLabel?.text = AdBlockManager.shared.updateStatus(
                        sourceId: subscription.id
                    ) ?? "更新中…"
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
            cell.detailTextLabel?.text = AdBlockManager.shared.updateStatus(
                sourceId: sourceId
            ) ?? "自定义规则更新中…"
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

        AdBlockManager.shared.saveCustomRules(rules) { [weak self] success, message in
            guard let self = self else {
                return
            }

            self.navigationItem.rightBarButtonItem?.isEnabled = true

            if success {
                self.onSaved?()
                self.navigationController?.popViewController(animated: true)
                return
            }

            let alert = UIAlertController(
                title: "保存失败",
                message: message ?? "自定义规则无法完成编译",
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "确定", style: .default))
            self.present(alert, animated: true)
        }
    }
}
