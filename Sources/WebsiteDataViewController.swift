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
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "清理未锁定数据", style: .plain, target: self, action: #selector(handleCleanAllCaches))
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
        let alert = UIAlertController(
            title: "清理未锁定网站数据",
            message: "将清除所有未锁定网站的缓存、Cookies、登录状态及本地数据。已锁定网站的数据将被保留。",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "清理未锁定数据", style: .destructive) { [weak self] _ in
            WebsiteCleaner.shared.cleanUnprotectedLoginAndData {
                self?.loadData()
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
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
        content.image = UIImage(systemName: "globe")
        content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
        content.imageProperties.cornerRadius = 4
        cell.contentConfiguration = content
        cell.selectionStyle = .none

        if isLocked {
            let lockView = UIImageView(image: UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
            lockView.tintColor = .secondaryLabel
            cell.accessoryView = lockView
        } else {
            cell.accessoryView = nil
        }

        FaviconLoader.shared.loadFavicon(for: record.displayName) { [weak tableView] image in
            guard let image = image else { return }
            DispatchQueue.main.async {
                if let currentCell = tableView?.cellForRow(at: indexPath) {
                    var updatedContent = currentCell.defaultContentConfiguration()
                    updatedContent.text = record.displayName
                    updatedContent.image = image
                    updatedContent.imageProperties.maximumSize = CGSize(width: 24, height: 24)
                    updatedContent.imageProperties.cornerRadius = 4
                    currentCell.contentConfiguration = updatedContent
                }
            }
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < filteredRecords.count else {
            return nil
        }

        let record = filteredRecords[indexPath.row]
        let isLocked = CookieLockStore.shared.isLocked(domain: record.displayName)

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            let message = isLocked
                ? "该网站已锁定，但你正在主动删除。删除后将清除 Cookies、登录状态、缓存及本地数据。"
                : "将清除该网站的 Cookies、登录状态、缓存及本地数据。"

            let alert = UIAlertController(
                title: "删除网站数据",
                message: message,
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                completion(false)
            })

            alert.addAction(UIAlertAction(title: "删除全部数据", style: .destructive) { [weak self] _ in
                WebsiteCleaner.shared.cleanSingleDomain(record: record, cacheOnly: false) {
                    self?.loadData()
                    completion(true)
                }
            })

            self?.present(alert, animated: true)
        }

        let cacheAction = UIContextualAction(style: .normal, title: "缓存") { [weak self] _, _, completion in
            WebsiteCleaner.shared.cleanSingleDomain(record: record, cacheOnly: true) {
                self?.loadData()
                completion(true)
            }
        }
        cacheAction.backgroundColor = .systemBlue

        let lockActionTitle = isLocked ? "解锁" : "锁定"
        let lockAction = UIContextualAction(style: .normal, title: lockActionTitle) { [weak self] _, _, completion in
            CookieLockStore.shared.toggleLock(domain: record.displayName)
            self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            completion(true)
        }
        lockAction.backgroundColor = .systemOrange

        return UISwipeActionsConfiguration(actions: [deleteAction, cacheAction, lockAction])
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
                switchView.isOn = DomainSettingsStore.shared.getBool(domain: domain, setting: "adBlock", defaultVal: true)
                switchView.isEnabled = true
                switchView.addTarget(self, action: #selector(handleSwitchChanged(_:)), for: .valueChanged)
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
        if sender.tag == 1 {
            DomainSettingsStore.shared.setBool(domain: domain, setting: "adBlock", value: sender.isOn)
            onSettingsChanged?()
        } else if sender.tag == 2 {
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
    private var mobileItems: [UserAgentItem] = []
    private var desktopItems: [UserAgentItem] = []
    private var customItems: [UserAgentItem] = []
    private var selectedId: String = ""
    var onUASelected: ((UserAgentItem) -> Void)?

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "浏览器标识"
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemGroupedBackground
        tableView.register(UserAgentCardCell.self, forCellReuseIdentifier: "UserAgentCardCell")

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
        mobileItems = UserAgentStore.shared.loadMobileItems()
        desktopItems = UserAgentStore.shared.loadDesktopItems()
        customItems = UserAgentStore.shared.loadCustomItems()
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
            let currentItem = UserAgentStore.shared.getSelectedItem()
            self?.onUASelected?(currentItem)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func item(for indexPath: IndexPath) -> UserAgentItem {
        switch indexPath.section {
        case 0:
            return mobileItems[indexPath.row]
        case 1:
            return desktopItems[indexPath.row]
        default:
            return customItems[indexPath.row]
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return customItems.isEmpty ? 2 : 3
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return "移动版标识"
        case 1:
            return "电脑版标识"
        default:
            return "自定义标识"
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return mobileItems.count
        case 1:
            return desktopItems.count
        default:
            return customItems.count
        }
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 68
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UserAgentCardCell", for: indexPath) as! UserAgentCardCell
        let item = self.item(for: indexPath)
        cell.configure(item: item, isSelected: item.id == selectedId)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = self.item(for: indexPath)
        selectedId = item.id
        UserAgentStore.shared.setSelectedId(item.id)
        tableView.reloadData()

        onUASelected?(item)
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = self.item(for: indexPath)

        let editAction = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, completion in
            self?.showEditUAAlert(item: item)
            completion(true)
        }
        editAction.backgroundColor = .systemBlue

        if item.isCustom {
            let deleteAction = UIContextualAction(style: .normal, title: "删除") { [weak self] _, _, completion in
                UserAgentStore.shared.deleteCustomItem(id: item.id)
                self?.loadData()
                let currentItem = UserAgentStore.shared.getSelectedItem()
                self?.onUASelected?(currentItem)
                completion(true)
            }
            deleteAction.backgroundColor = .systemRed
            return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
        } else {
            return UISwipeActionsConfiguration(actions: [editAction])
        }
    }
}

final class UserAgentCardCell: UITableViewCell {
    private let cardView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkmarkImageView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = 12
        cardView.clipsToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingTail

        checkmarkImageView.translatesAutoresizingMaskIntoConstraints = false
        checkmarkImageView.image = UIImage(systemName: "checkmark.circle.fill")
        checkmarkImageView.tintColor = .systemBlue
        checkmarkImageView.contentMode = .scaleAspectFit

        cardView.addSubview(titleLabel)
        cardView.addSubview(subtitleLabel)
        cardView.addSubview(checkmarkImageView)
        contentView.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),

            checkmarkImageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            checkmarkImageView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            checkmarkImageView.widthAnchor.constraint(equalToConstant: 20),
            checkmarkImageView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: checkmarkImageView.leadingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: checkmarkImageView.leadingAnchor, constant: -12),
            subtitleLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(item: UserAgentItem, isSelected: Bool) {
        titleLabel.text = item.name
        subtitleLabel.text = item.uaString
        checkmarkImageView.isHidden = !isSelected
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

        let item = UserScript(
            id: script?.id ?? UUID().uuidString,
            name: nameText,
            matchPattern: matchText,
            code: codeText,
            isEnabled: script?.isEnabled ?? true
        )

        onSave?(item)
        dismiss(animated: true)
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }
}
