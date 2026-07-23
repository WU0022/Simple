import UIKit
import WebKit

final class WebsiteDataManagerViewController: UITableViewController, UISearchResultsUpdating {
    private var allRecords: [WKWebsiteDataRecord] = []
    private var filteredRecords: [WKWebsiteDataRecord] = []
    private let searchController = UISearchController(searchResultsController: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "管理网站数据"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DataRecordCell")

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索网站域名"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(handleDone))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "清理缓存", style: .plain, target: self, action: #selector(handleCleanAllCaches))
        loadData()
    }

    private func loadData() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { [weak self] records in
            DispatchQueue.main.async {
                self?.allRecords = records.sorted { $0.displayName < $1.displayName }
                self?.updateSearchResults(for: self?.searchController ?? UISearchController())
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let searchText = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if searchText.isEmpty {
            filteredRecords = allRecords
        } else {
            filteredRecords = allRecords.filter { $0.displayName.lowercased().contains(searchText) }
        }
        tableView.reloadData()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    @objc private func handleCleanAllCaches() {
        let alert = UIAlertController(title: "清理未锁定网站数据", message: "将清理所有未锁定网站的缓存与本地数据，受保护网站的数据将被保留。", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "清理未锁定数据", style: .default) { [weak self] _ in
            WebsiteCleaner.shared.cleanUnprotectedLoginAndData {
                self?.loadData()
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredRecords.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DataRecordCell", for: indexPath)
        let record = filteredRecords[indexPath.row]
        let isLocked = CookieLockStore.shared.isLocked(domain: record.displayName)

        var content = cell.defaultContentConfiguration()
        content.text = record.displayName
        cell.contentConfiguration = content
        cell.selectionStyle = .none

        if isLocked {
            let lockView = UIImageView(image: UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
            lockView.tintColor = .secondaryLabel
            cell.accessoryView = lockView
        } else {
            cell.accessoryView = nil
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < filteredRecords.count else { return nil }
        let record = filteredRecords[indexPath.row]
        let isLocked = CookieLockStore.shared.isLocked(domain: record.displayName)

        let deleteAction = UIContextualAction(style: .normal, title: "删除") { [weak self] _, _, completion in
            WebsiteCleaner.shared.cleanSingleDomain(record: record, cacheOnly: false) {
                self?.loadData()
                completion(true)
            }
        }
        deleteAction.backgroundColor = .systemRed

        let lockActionTitle = isLocked ? "解锁" : "锁定"
        let lockAction = UIContextualAction(style: .normal, title: lockActionTitle) { [weak self] _, _, completion in
            CookieLockStore.shared.toggleLock(domain: record.displayName)
            self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            completion(true)
        }
        lockAction.backgroundColor = .systemOrange

        return UISwipeActionsConfiguration(actions: [deleteAction, lockAction])
    }
}

final class DomainSettingsViewController: UITableViewController {
    private let domain: String
    var onSettingsChanged: (() -> Void)?
    var onExtractText: (() -> Void)?

    init(domain: String, onSettingsChanged: (() -> Void)?) {
        self.domain = domain
        self.onSettingsChanged = onSettingsChanged
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = domain
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(handleDone))
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 0 ? 3 : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)

        if indexPath.section == 0 {
            let switchView = UISwitch()
            switchView.tag = indexPath.row

            if indexPath.row == 0 {
                cell.textLabel?.text = "视频悬窗"
                switchView.isOn = DomainSettingsStore.shared.getBool(domain: domain, setting: "videoPopout", defaultVal: false)
                switchView.isEnabled = false
            } else if indexPath.row == 1 {
                cell.textLabel?.text = "广告过滤"
                switchView.isOn = DomainSettingsStore.shared.getBool(domain: domain, setting: "adBlock", defaultVal: false)
                switchView.isEnabled = false
            } else if indexPath.row == 2 {
                cell.textLabel?.text = "用户脚本"
                switchView.isOn = DomainSettingsStore.shared.getBool(domain: domain, setting: "userScripts", defaultVal: true)
                switchView.addTarget(self, action: #selector(handleSwitchChanged(_:)), for: .valueChanged)
            }
            cell.accessoryView = switchView
        } else {
            cell.textLabel?.text = "获取网页所有文字"
            cell.textLabel?.textColor = .systemBlue
            cell.textLabel?.textAlignment = .center
        }

        return cell
    }

    @objc private func handleSwitchChanged(_ sender: UISwitch) {
        if sender.tag == 2 {
            DomainSettingsStore.shared.setBool(domain: domain, setting: "userScripts", value: sender.isOn)
            onSettingsChanged?()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            dismiss(animated: true) { [weak self] in
                self?.onExtractText?()
            }
        }
    }
}

final class UserAgentManagerViewController: UITableViewController {
    private var items: [UserAgentItem] = []
    private var selectedId: String = ""
    var onUASelected: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "浏览器标识"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "UACell")

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(handleAddCustomUA)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleDone)
        )

        loadData()
    }

    private func loadData() {
        items = UserAgentStore.shared.loadAllItems()
        selectedId = UserAgentStore.shared.getSelectedId()
        tableView.reloadData()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    @objc private func handleAddCustomUA() {
        let alert = UIAlertController(title: "添加自定义标识", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in tf.placeholder = "标识名称" }
        alert.addTextField { tf in tf.placeholder = "User-Agent 字符串" }

        alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let ua = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !ua.isEmpty else { return }

            UserAgentStore.shared.addCustomItem(name: name, uaString: ua)
            self?.loadData()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showEditUAAlert(item: UserAgentItem) {
        let alert = UIAlertController(title: "编辑标识", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "标识名称"
            tf.text = item.name
        }
        alert.addTextField { tf in
            tf.placeholder = "User-Agent 字符串"
            tf.text = item.uaString
        }

        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            guard let name = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let ua = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces), !ua.isEmpty else { return }

            if item.isCustom {
                UserAgentStore.shared.updateCustomItem(id: item.id, name: name, uaString: ua)
            } else {
                UserAgentStore.shared.addCustomItem(name: name, uaString: ua)
            }
            self?.loadData()
            let currentUA = UserAgentStore.shared.getSelectedUA()
            self?.onUASelected?(currentUA)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UACell", for: indexPath)
        let item = items[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = item.name
        cell.contentConfiguration = content

        cell.accessoryType = item.id == selectedId ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items[indexPath.row]
        selectedId = item.id
        UserAgentStore.shared.setSelectedId(item.id)
        tableView.reloadData()

        onUASelected?(item.uaString)
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = items[indexPath.row]

        let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            self?.showEditUAAlert(item: item)
            completion(true)
        }
        editAction.backgroundColor = .systemBlue

        if item.isCustom {
            let deleteAction = UIContextualAction(style: .normal, title: "删除") { [weak self] _, _, completion in
                UserAgentStore.shared.deleteCustomItem(id: item.id)
                self?.loadData()
                let currentUA = UserAgentStore.shared.getSelectedUA()
                self?.onUASelected?(currentUA)
                completion(true)
            }
            deleteAction.backgroundColor = .systemRed
            return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
        } else {
            return UISwipeActionsConfiguration(actions: [editAction])
        }
    }
}

final class UserScriptEditorViewController: UIViewController {
    private var script: UserScript?
    var onSave: ((UserScript) -> Void)?

    private let nameField = UITextField()
    private let matchField = UITextField()
    private let textView = UITextView()

    init(script: UserScript?) {
        self.script = script
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = script == nil ? "新建油猴脚本" : "编辑脚本"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存",
            style: .done,
            target: self,
            action: #selector(handleSave)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消",
            style: .plain,
            target: self,
            action: #selector(handleCancel)
        )

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.backgroundColor = .secondarySystemGroupedBackground
        nameField.layer.cornerRadius = 10
        nameField.clipsToBounds = true
        nameField.placeholder = "脚本名称"
        nameField.text = script?.name ?? ""
        nameField.font = .systemFont(ofSize: 15)

        let namePadding = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        nameField.leftView = namePadding
        nameField.leftViewMode = .always

        matchField.translatesAutoresizingMaskIntoConstraints = false
        matchField.backgroundColor = .secondarySystemGroupedBackground
        matchField.layer.cornerRadius = 10
        matchField.clipsToBounds = true
        matchField.placeholder = "匹配域名规则 (如 * 或 google.com)"
        matchField.text = script?.matchPattern ?? "*"
        matchField.font = .systemFont(ofSize: 15)

        let matchPadding = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        matchField.leftView = matchPadding
        matchField.leftViewMode = .always

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.clipsToBounds = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.text = script?.code ?? "(function() {\n    'use strict';\n})();"

        view.addSubview(nameField)
        view.addSubview(matchField)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            nameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            nameField.heightAnchor.constraint(equalToConstant: 42),

            matchField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            matchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            matchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            matchField.heightAnchor.constraint(equalToConstant: 42),

            textView.topAnchor.constraint(equalTo: matchField.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    @objc private func handleSave() {
        let codeText = textView.text ?? ""
        var nameText = nameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        var matchText = matchField.text?.trimmingCharacters(in: .whitespaces) ?? ""

        let parsed = UserScriptStore.shared.parseMetadata(from: codeText)
        if nameText.isEmpty { nameText = parsed.name }
        if matchText.isEmpty { matchText = parsed.match }
        let iconURLText = parsed.iconURL ?? script?.iconURL

        let item = UserScript(
            id: script?.id ?? UUID().uuidString,
            name: nameText,
            matchPattern: matchText,
            code: codeText,
            isEnabled: script?.isEnabled ?? true,
            iconURL: iconURLText
        )

        onSave?(item)
        dismiss(animated: true)
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }
}
