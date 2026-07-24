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
    private let enabledKey = "adblock_enabled_v1"
    private let subscriptionsKey = "adblock_subscriptions_v1"
    private let customRulesKey = "adblock_custom_rules_v1"
    private let cachedCSSTextKey = "adblock_cached_css_text_v1"
    private let ruleListIdentifier = "SimpleBrowserAdBlockRules"

    private(set) var compiledRuleList: WKContentRuleList?
    private(set) var injectedCSSUserScript: WKUserScript?
    private(set) var lastErrorDescription: String?
    private(set) var compiledCount: Int = 0

    private var attachedWebViews = NSHashTable<WKWebView>.weakObjects()

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            recompileRules()
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: enabledKey)
        }
        if let cachedCSS = UserDefaults.standard.string(forKey: cachedCSSTextKey), !cachedCSS.isEmpty {
            self.injectedCSSUserScript = WKUserScript(source: cachedCSS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        }
        initDefaultSubscriptionsIfNeeded()
        loadCompiledRules()
    }

    private func initDefaultSubscriptionsIfNeeded() {
        if UserDefaults.standard.object(forKey: subscriptionsKey) == nil {
            let defaultSub = AdBlockSubscription(
                id: "easylist_china",
                name: "EasyList China (基础规则)",
                urlString: "https://easylist-downloads.adblockplus.org/easylistchina.txt",
                isEnabled: true,
                lastUpdated: nil,
                ruleCount: 0
            )
            saveSubscriptions([defaultSub])
        }
    }

    func loadSubscriptions() -> [AdBlockSubscription] {
        guard let data = UserDefaults.standard.data(forKey: subscriptionsKey),
              let subs = try? JSONDecoder().decode([AdBlockSubscription].self, from: data) else {
            return []
        }
        return subs
    }

    func saveSubscriptions(_ subs: [AdBlockSubscription]) {
        if let data = try? JSONEncoder().encode(subs) {
            UserDefaults.standard.set(data, forKey: subscriptionsKey)
        }
    }

    func updateSubscription(id: String, name: String, urlString: String) {
        var subs = loadSubscriptions()
        if let idx = subs.firstIndex(where: { $0.id == id }) {
            subs[idx].name = name
            subs[idx].urlString = urlString
            saveSubscriptions(subs)
            recompileRules()
        }
    }

    func deleteSubscription(id: String) {
        var subs = loadSubscriptions()
        subs.removeAll { $0.id == id }
        saveSubscriptions(subs)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fileURL = self.getSubscriptionFileURL(id: id)
            try? FileManager.default.removeItem(at: fileURL)
            self.recompileRules()
        }
    }

    func getCustomRules() -> String {
        return UserDefaults.standard.string(forKey: customRulesKey) ?? "*ads*$domain=pornhub.com\n*ads*$domain=hanime1.me\npornhub.com##[class*=\"ads\"]\nhanime1.me,hanimeone.me###mobile-ad"
    }

    func saveCustomRules(_ rules: String) {
        UserDefaults.standard.set(rules, forKey: customRulesKey)
        recompileRules()
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

        guard isEnabled else { return }

        if let compiledRuleList = compiledRuleList {
            controller.add(compiledRuleList)
        }

        if let injectedCSSUserScript = injectedCSSUserScript {
            controller.addUserScript(injectedCSSUserScript)
        }
    }

    private func applyRulesToAttachedWebViews() {
        for webView in attachedWebViews.allObjects {
            applyRules(to: webView)
        }
    }

    private func loadCompiledRules() {
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: ruleListIdentifier) { [weak self] ruleList, _ in
            DispatchQueue.main.async {
                if let ruleList = ruleList {
                    self?.compiledRuleList = ruleList
                    self?.applyRulesToAttachedWebViews()
                } else {
                    self?.recompileRules()
                }
            }
        }
    }

    func applyRulesToConfiguration(_ configuration: WKWebViewConfiguration) {
        guard isEnabled else { return }
        if let ruleList = compiledRuleList {
            configuration.userContentController.add(ruleList)
        }
        if let cssScript = injectedCSSUserScript {
            configuration.userContentController.addUserScript(cssScript)
        }
    }

    func fetchSubscription(_ sub: AdBlockSubscription, completion: @escaping (Bool, Bool, Int, String?) -> Void) {
        guard let url = URL(string: sub.urlString) else {
            completion(false, false, 0, "无效的地址")
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15.0)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    completion(false, false, 0, error.localizedDescription)
                }
                return
            }

            guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async {
                    completion(false, false, 0, "HTTP 状态码: \(code)")
                }
                return
            }

            guard let data = data, !data.isEmpty else {
                DispatchQueue.main.async {
                    completion(false, false, 0, "数据内容为空")
                }
                return
            }

            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""

            guard !text.isEmpty else {
                DispatchQueue.main.async {
                    completion(false, false, 0, "无法解析文本")
                }
                return
            }

            let fileURL = self.getSubscriptionFileURL(id: sub.id)
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)

            let lineCount = text.components(separatedBy: .newlines).filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !trimmed.hasPrefix("!") && !trimmed.hasPrefix("！") && !trimmed.hasPrefix("[")
            }.count

            var subs = self.loadSubscriptions()
            if let idx = subs.firstIndex(where: { $0.id == sub.id }) {
                subs[idx].lastUpdated = Date()
                subs[idx].ruleCount = lineCount
                self.saveSubscriptions(subs)
            }

            self.recompileRules { success, compileErr in
                DispatchQueue.main.async {
                    completion(true, success, lineCount, compileErr)
                }
            }
        }
        task.resume()
    }

    func recompileRules(completion: ((Bool, String?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let (jsonString, jsScriptString, totalRules) = self.generateWebKitRulesAndJSScript()

            DispatchQueue.main.async {
                self.compiledCount = totalRules

                if !jsScriptString.isEmpty {
                    UserDefaults.standard.set(jsScriptString, forKey: self.cachedCSSTextKey)
                    self.injectedCSSUserScript = WKUserScript(source: jsScriptString, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                } else {
                    UserDefaults.standard.removeObject(forKey: self.cachedCSSTextKey)
                    self.injectedCSSUserScript = nil
                }

                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: self.ruleListIdentifier, encodedContentRuleList: jsonString) { ruleList, error in
                    if let ruleList = ruleList {
                        self.compiledRuleList = ruleList
                        self.lastErrorDescription = nil
                        self.applyRulesToAttachedWebViews()
                        completion?(true, nil)
                    } else {
                        let errStr = error?.localizedDescription ?? "规则编译失败"
                        self.lastErrorDescription = errStr
                        self.applyRulesToAttachedWebViews()
                        completion?(false, errStr)
                    }
                }
            }
        }
    }

    private func getSubscriptionFileURL(id: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("adblock_sub_\(id).txt")
    }

    private func generateWebKitRulesAndJSScript() -> (String, String, Int) {
        var jsonRules: [[String: Any]] = []
        var domainCSSTable: [String: Set<String>] = [:]
        var totalRuleCount = 0
        let maxRulesLimit = 25000

        let processLine: (String) -> Void = { [weak self] line in
            guard let self = self, totalRuleCount < maxRulesLimit else { return }
            let (rules, domCSSDict) = self.parseABPLine(line)
            jsonRules.append(contentsOf: rules)

            if let dict = domCSSDict {
                for (dom, selectors) in dict {
                    if domainCSSTable[dom] == nil {
                        domainCSSTable[dom] = Set<String>()
                    }
                    domainCSSTable[dom]?.formUnion(selectors)
                }
            }

            if !rules.isEmpty || (domCSSDict != nil && !domCSSDict!.isEmpty) {
                totalRuleCount += 1
            }
        }

        let rawCustom = getCustomRules()
        let customLines = rawCustom.components(separatedBy: .newlines)
        for line in customLines {
            processLine(line)
        }

        let subs = loadSubscriptions().filter { $0.isEnabled }
        for sub in subs {
            let fileURL = getSubscriptionFileURL(id: sub.id)
            if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                for line in lines {
                    if totalRuleCount >= maxRulesLimit { break }
                    processLine(line)
                }
            }
        }

        if jsonRules.isEmpty {
            jsonRules.append([
                "trigger": ["url-filter": ".*ad-example-dummy-filter.*"],
                "action": ["type": "ignore-previous-rules"]
            ])
        }

        let jsonString: String
        if let data = try? JSONSerialization.data(withJSONObject: jsonRules, options: []),
           let str = String(data: data, encoding: .utf8) {
            jsonString = str
        } else {
            jsonString = "[]"
        }

        let jsString = generateDOMHidingUserScript(from: domainCSSTable)
        return (jsonString, jsString, totalRuleCount)
    }

    private func generateDOMHidingUserScript(from table: [String: Set<String>]) -> String {
        guard !table.isEmpty else { return "" }

        var rulesJSONArray: [[String: Any]] = []
        for (domain, selectors) in table {
            let cssCombined = selectors.joined(separator: ", ")
            let domainsArray = domain == "*" ? [] : domain.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            rulesJSONArray.append([
                "domains": domainsArray,
                "css": cssCombined
            ])
        }

        guard let rulesData = try? JSONSerialization.data(withJSONObject: rulesJSONArray, options: []),
              let rulesJSONText = String(data: rulesData, encoding: .utf8) else {
            return ""
        }

        return """
        (function() {
            var host = (location.hostname || '').toLowerCase();
            var rules = \(rulesJSONText);

            function apply() {
                var matched = [];
                for (var i = 0; i < rules.length; i++) {
                    var item = rules[i];
                    if (!item.domains || item.domains.length === 0) {
                        matched.push(item.css);
                        continue;
                    }
                    for (var j = 0; j < item.domains.length; j++) {
                        var d = item.domains[j];
                        if (host === d || host.endsWith('.' + d)) {
                            matched.push(item.css);
                            break;
                        }
                    }
                }
                if (matched.length === 0) return;
                var fullCSS = matched.join(', ') + ' { display: none !important; visibility: hidden !important; opacity: 0 !important; pointer-events: none !important; }';
                var style = document.getElementById('__adblock_injected_css__');
                if (!style) {
                    style = document.createElement('style');
                    style.id = '__adblock_injected_css__';
                    style.type = 'text/css';
                    (document.head || document.documentElement || document).appendChild(style);
                }
                style.textContent = fullCSS;
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', apply);
            }
            apply();
        })();
        """
    }

    private func parseABPLine(_ rawLine: String) -> ([[String: Any]], [String: Set<String>]?) {
        var jsonRules: [[String: Any]] = []
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return ([], nil) }
        if line.hasPrefix("!") || line.hasPrefix("！") || line.hasPrefix("[") { return ([], nil) }

        if let range = line.range(of: "##") {
            let domainStr = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let fullSelector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fullSelector.isEmpty else { return ([], nil) }

            var ifDomains: [String] = []
            var unlessDomains: [String] = []

            let targetDomainKey = domainStr.isEmpty ? "*" : domainStr.lowercased()
            var domCSSDict: [String: Set<String>] = [targetDomainKey: Set([fullSelector])]

            if !domainStr.isEmpty {
                let domains = domainStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                for d in domains {
                    let cleanD = d.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ./\t\r\n"))
                    if cleanD.hasPrefix("~") {
                        let noTilde = String(cleanD.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !noTilde.isEmpty { unlessDomains.append(noTilde) }
                    } else if !cleanD.isEmpty {
                        ifDomains.append(cleanD)
                    }
                }
            }

            let selectorItems = splitSelectorList(fullSelector)
            var standardSelectors: [String] = []

            for sel in selectorItems {
                if sel.isEmpty { continue }
                if !sel.contains(":has(") && !sel.contains(":matches(") && !sel.contains(":where(") && !sel.contains(":xpath(") {
                    standardSelectors.append(sel)
                }
            }

            if !standardSelectors.isEmpty {
                let combinedSel = standardSelectors.joined(separator: ", ")
                var trigger: [String: Any] = ["url-filter": ".*"]
                if !ifDomains.isEmpty {
                    trigger["if-domain"] = ifDomains
                } else if !unlessDomains.isEmpty {
                    trigger["unless-domain"] = unlessDomains
                }
                let action: [String: Any] = [
                    "type": "css-display-none",
                    "selector": combinedSel
                ]
                jsonRules.append(["trigger": trigger, "action": action])
            }

            return (jsonRules, domCSSDict)
        }

        var isWhiteList = false
        if line.hasPrefix("@@") {
            isWhiteList = true
            line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var urlPattern = line
        var optionsStr = ""

        if let dollarIndex = line.lastIndex(of: "$") {
            urlPattern = String(line[..<dollarIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            optionsStr = String(line[line.index(after: dollarIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !urlPattern.isEmpty else { return ([], nil) }

        var ifDomains: [String] = []
        var unlessDomains: [String] = []
        var resourceTypes: [String] = []
        var loadType: String? = nil

        if !optionsStr.isEmpty {
            let opts = optionsStr.components(separatedBy: ",")
            for opt in opts {
                let trimmedOpt = opt.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedOpt.hasPrefix("domain=") {
                    let domainVal = String(trimmedOpt.dropFirst(7))
                    let dList = domainVal.components(separatedBy: "|")
                    for d in dList {
                        let clean = d.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ./\t\r\n"))
                        if clean.hasPrefix("~") {
                            let noTilde = String(clean.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !noTilde.isEmpty { unlessDomains.append(noTilde) }
                        } else if !clean.isEmpty {
                            ifDomains.append(clean)
                        }
                    }
                } else if trimmedOpt == "script" {
                    resourceTypes.append("script")
                } else if trimmedOpt == "image" {
                    resourceTypes.append("image")
                } else if trimmedOpt == "stylesheet" || trimmedOpt == "style" {
                    resourceTypes.append("style-sheet")
                } else if trimmedOpt == "xmlhttprequest" || trimmedOpt == "xhr" {
                    resourceTypes.append("raw")
                } else if trimmedOpt == "subdocument" {
                    resourceTypes.append("document")
                } else if trimmedOpt == "media" {
                    resourceTypes.append("media")
                } else if trimmedOpt == "font" {
                    resourceTypes.append("font")
                } else if trimmedOpt == "third-party" || trimmedOpt == "3p" {
                    loadType = "third-party"
                } else if trimmedOpt == "~third-party" || trimmedOpt == "1p" || trimmedOpt == "first-party" {
                    loadType = "first-party"
                }
            }
        }

        var regexPattern = ""
        if urlPattern.hasPrefix("||") {
            let domainOnly = String(urlPattern.dropFirst(2)).replacingOccurrences(of: "^", with: "")
            let cleanDomain = domainOnly.trimmingCharacters(in: .whitespacesAndNewlines)
            let escapedDomain = NSRegularExpression.escapedPattern(for: cleanDomain)
            regexPattern = ".*" + escapedDomain + ".*"
        } else {
            var pattern = urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            pattern = pattern.replacingOccurrences(of: " ", with: "")
            pattern = NSRegularExpression.escapedPattern(for: pattern)
            pattern = pattern.replacingOccurrences(of: "\\*", with: ".*")
            pattern = pattern.replacingOccurrences(of: "\\^", with: ".*")
            regexPattern = ".*" + pattern + ".*"
        }

        while regexPattern.contains(".*.*") {
            regexPattern = regexPattern.replacingOccurrences(of: ".*.*", with: ".*")
        }

        var trigger: [String: Any] = [
            "url-filter": regexPattern,
            "url-filter-is-case-sensitive": false
        ]

        if !ifDomains.isEmpty {
            trigger["if-domain"] = ifDomains
        } else if !unlessDomains.isEmpty {
            trigger["unless-domain"] = unlessDomains
        }

        if !resourceTypes.isEmpty { trigger["resource-type"] = resourceTypes }
        if let loadType = loadType { trigger["load-type"] = [loadType] }

        let actionType = isWhiteList ? "ignore-previous-rules" : "block"
        let action: [String: Any] = ["type": actionType]

        jsonRules.append(["trigger": trigger, "action": action])
        return (jsonRules, nil)
    }

    private func splitSelectorList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var parenDepth = 0
        var bracketDepth = 0

        for char in text {
            if char == "(" { parenDepth += 1 }
            else if char == ")" { if parenDepth > 0 { parenDepth -= 1 } }
            else if char == "[" { bracketDepth += 1 }
            else if char == "]" { if bracketDepth > 0 { bracketDepth -= 1 } }

            if char == "," && parenDepth == 0 && bracketDepth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { items.append(trimmed) }
                current = ""
            } else {
                current.append(char)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(trimmed) }
        return items
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
        } else if indexPath.section == 1 {
            if indexPath.row < subscriptions.count {
                let sub = subscriptions[indexPath.row]
                cell.textLabel?.text = sub.name
                if let date = sub.lastUpdated {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MM-dd HH:mm"
                    cell.detailTextLabel?.text = "规则数: \(sub.ruleCount) | 更新于: \(formatter.string(from: date))"
                } else {
                    cell.detailTextLabel?.text = "未更新"
                }
                cell.accessoryType = .disclosureIndicator
            } else {
                cell.textLabel?.text = "添加新订阅链接..."
                cell.textLabel?.textColor = .systemBlue
                cell.detailTextLabel?.text = nil
                cell.accessoryType = .none
            }
        } else {
            let status = AdBlockManager.shared.lastErrorDescription == nil ? "已成功编译加载" : "编译提示: \(AdBlockManager.shared.lastErrorDescription!)"
            cell.textLabel?.text = "编辑自定义过滤规则"
            cell.detailTextLabel?.text = "有效规则: \(AdBlockManager.shared.compiledCount) 条 | \(status)"
            cell.accessoryType = .disclosureIndicator
        }

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
                let sub = subscriptions[indexPath.row]
                showSubscriptionDetail(sub)
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

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1, indexPath.row < subscriptions.count else { return nil }
        let sub = subscriptions[indexPath.row]

        let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            self?.showEditSubscriptionAlert(sub)
            completion(true)
        }
        editAction.backgroundColor = .systemBlue

        return UISwipeActionsConfiguration(actions: [editAction])
    }

    private func showEditSubscriptionAlert(_ sub: AdBlockSubscription) {
        let alert = UIAlertController(title: "编辑规则订阅", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "订阅名称"
            tf.text = sub.name
        }
        alert.addTextField { tf in
            tf.placeholder = "订阅 URL"
            tf.text = sub.urlString
        }

        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let urlStr = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !urlStr.isEmpty else { return }

            AdBlockManager.shared.updateSubscription(id: sub.id, name: name, urlString: urlStr)
            self?.loadData()
            self?.onRulesChanged?()
        })

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showSubscriptionDetail(_ sub: AdBlockSubscription) {
        let alert = UIAlertController(title: sub.name, message: sub.urlString, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "立即更新规则", style: .default) { [weak self] _ in
            let hud = UIAlertController(title: nil, message: "正在下载更新规则...", preferredStyle: .alert)
            self?.present(hud, animated: true)

            AdBlockManager.shared.fetchSubscription(sub) { downloadSuccess, compileSuccess, count, errorMsg in
                hud.dismiss(animated: true) {
                    let msg: String
                    if !downloadSuccess {
                        msg = "下载失败：\(errorMsg ?? "请检查网络或代理")"
                    } else if !compileSuccess {
                        msg = "规则已下载 (\(count) 条)，但编译提示：\(errorMsg ?? "超出限制或语法错误")"
                    } else {
                        msg = "更新成功，已加载 \(count) 条规则"
                    }
                    let res = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
                    self?.present(res, animated: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        res.dismiss(animated: true)
                    }
                    self?.loadData()
                    self?.onRulesChanged?()
                }
            }
        })

        alert.addAction(UIAlertAction(title: "删除订阅", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.subscriptions.removeAll { $0.id == sub.id }
            AdBlockManager.shared.deleteSubscription(id: sub.id)
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

            let newSub = AdBlockSubscription(
                id: UUID().uuidString,
                name: name,
                urlString: urlStr,
                isEnabled: true,
                lastUpdated: nil,
                ruleCount: 0
            )

            var subs = AdBlockManager.shared.loadSubscriptions()
            subs.append(newSub)
            AdBlockManager.shared.saveSubscriptions(subs)
            self?.loadData()

            AdBlockManager.shared.fetchSubscription(newSub) { _, _, _, _ in
                self?.loadData()
                self?.onRulesChanged?()
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
        let text = textView.text ?? ""
        AdBlockManager.shared.saveCustomRules(text)
        onSaved?()
        navigationController?.popViewController(animated: true)
    }
}
