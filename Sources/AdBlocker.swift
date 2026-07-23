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
    private let ruleListIdentifier = "SimpleBrowserAdBlockRules"

    private(set) var compiledRuleList: WKContentRuleList?
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

    func getCustomRules() -> String {
        return UserDefaults.standard.string(forKey: customRulesKey) ?? "##.ad-banner\n##.adsbygoogle\n||doubleclick.net^"
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

        guard isEnabled, let compiledRuleList = compiledRuleList else {
            return
        }

        controller.add(compiledRuleList)
    }

    private func applyRulesToAttachedWebViews() {
        for webView in attachedWebViews.allObjects {
            applyRules(to: webView)
        }
    }

    private func loadCompiledRules() {
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: ruleListIdentifier) { [weak self] ruleList, _ in
            DispatchQueue.main.async {
                self?.compiledRuleList = ruleList
                self?.applyRulesToAttachedWebViews()
            }
        }
    }

    func applyRulesToConfiguration(_ configuration: WKWebViewConfiguration) {
        guard isEnabled, let ruleList = compiledRuleList else { return }
        configuration.userContentController.add(ruleList)
    }

    func fetchSubscription(_ sub: AdBlockSubscription, completion: @escaping (Bool, Int) -> Void) {
        guard let url = URL(string: sub.urlString) else {
            completion(false, 0)
            return
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self, let data = data, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                DispatchQueue.main.async { completion(false, 0) }
                return
            }

            let fileURL = self.getSubscriptionFileURL(id: sub.id)
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)

            let lineCount = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("!") && !$0.isEmpty }.count

            var subs = self.loadSubscriptions()
            if let idx = subs.firstIndex(where: { $0.id == sub.id }) {
                subs[idx].lastUpdated = Date()
                subs[idx].ruleCount = lineCount
                self.saveSubscriptions(subs)
            }

            self.recompileRules { success in
                DispatchQueue.main.async {
                    completion(success, lineCount)
                }
            }
        }
        task.resume()
    }

    func recompileRules(completion: ((Bool) -> Void)? = nil) {
        let jsonString = generateWebKitRulesJSON()

        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: ruleListIdentifier, encodedContentRuleList: jsonString) { [weak self] ruleList, error in
            DispatchQueue.main.async {
                if let ruleList = ruleList {
                    self?.compiledRuleList = ruleList
                    self?.applyRulesToAttachedWebViews()
                    completion?(true)
                } else {
                    completion?(false)
                }
            }
        }
    }

    private func getSubscriptionFileURL(id: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("adblock_sub_\(id).txt")
    }

    private func generateWebKitRulesJSON() -> String {
        var rulesArray: [[String: Any]] = []

        let rawCustom = getCustomRules()
        let customLines = rawCustom.components(separatedBy: .newlines)
        for line in customLines {
            if let rule = parseEasyListLine(line) {
                rulesArray.append(rule)
            }
        }

        let subs = loadSubscriptions().filter { $0.isEnabled }
        for sub in subs {
            let fileURL = getSubscriptionFileURL(id: sub.id)
            if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                for line in lines {
                    if let rule = parseEasyListLine(line) {
                        rulesArray.append(rule)
                    }
                }
            }
        }

        if rulesArray.isEmpty {
            rulesArray.append([
                "trigger": ["url-filter": ".*ad-example-dummy-filter.*"],
                "action": ["type": "ignore-previous-rules"]
            ])
        }

        if let data = try? JSONSerialization.data(withJSONObject: rulesArray, options: []),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        return "[]"
    }

    private func parseEasyListLine(_ rawLine: String) -> [String: Any]? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return nil }

        if line.contains("##") {
            let parts = line.components(separatedBy: "##")
            guard parts.count == 2 else { return nil }
            let domainStr = parts[0].trimmingCharacters(in: .whitespaces)
            let selector = parts[1].trimmingCharacters(in: .whitespaces)
            guard !selector.isEmpty else { return nil }

            var trigger: [String: Any] = ["url-filter": ".*"]
            if !domainStr.isEmpty {
                let domains = domainStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("~") }
                if !domains.isEmpty {
                    trigger["if-domain"] = domains
                }
            }

            let action: [String: Any] = [
                "type": "css-display-none",
                "selector": selector
            ]

            return ["trigger": trigger, "action": action]
        } else if line.hasPrefix("||") {
            let clean = line.dropFirst(2).replacingOccurrences(of: "^", with: "")
            let escaped = NSRegularExpression.escapedPattern(for: String(clean))
            let filter = ".*" + escaped + ".*"

            return [
                "trigger": ["url-filter": filter],
                "action": ["type": "block"]
            ]
        }

        return nil
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
            cell.textLabel?.text = "编辑自定义过滤规则"
            cell.detailTextLabel?.text = "支持基础域名拦截与 CSS 隐藏规则"
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

            AdBlockManager.shared.fetchSubscription(sub) { success, count in
                hud.dismiss(animated: true) {
                    let msg = success ? "更新成功，已加载 \(count) 条规则" : "更新失败，请检查网络链接"
                    let res = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
                    self?.present(res, animated: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        res.dismiss(animated: true)
                    }
                    self?.loadData()
                    self?.onRulesChanged?()
                }
            }
        })

        alert.addAction(UIAlertAction(title: "删除订阅", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            var subs = self.subscriptions
            subs.removeAll { $0.id == sub.id }
            AdBlockManager.shared.saveSubscriptions(subs)
            AdBlockManager.shared.recompileRules()
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

            AdBlockManager.shared.fetchSubscription(newSub) { _, _ in
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
