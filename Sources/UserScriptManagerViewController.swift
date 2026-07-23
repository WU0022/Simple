import UIKit

final class UserScriptManagerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private var allScripts: [UserScript] = []
    private var filteredScripts: [UserScript] = []

    var onScriptsUpdated: (() -> Void)?

    private let searchField = UITextField()
    private let tableView = UITableView(frame: .zero, style: .plain)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1.0)
        setupInterface()
        loadData()
    }

    private func setupInterface() {
        let headerView = UIView()
        headerView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.text = "管理面板"

        let addButton = TouchButton(type: .system)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        addButton.tintColor = .systemRed
        addButton.addTarget(self, action: #selector(handleAddScript), for: .touchUpInside)

        let closeButton = TouchButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        closeButton.tintColor = .tertiaryLabel
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

        headerView.addSubview(titleLabel)
        headerView.addSubview(addButton)
        headerView.addSubview(closeButton)

        let searchContainer = UIView()
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.backgroundColor = UIColor(white: 0.9, alpha: 0.5)
        searchContainer.layer.cornerRadius = 10
        searchContainer.clipsToBounds = true

        let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.tintColor = .secondaryLabel

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "搜索"
        searchField.font = .systemFont(ofSize: 15)
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(handleSearchChanged), for: .editingChanged)

        searchContainer.addSubview(searchIcon)
        searchContainer.addSubview(searchField)

        let sectionHeader = UILabel()
        sectionHeader.translatesAutoresizingMaskIntoConstraints = false
        sectionHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionHeader.textColor = .secondaryLabel
        sectionHeader.text = "USERSCRIPT"

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UserScriptRowCell.self, forCellReuseIdentifier: "UserScriptRowCell")

        view.addSubview(headerView)
        view.addSubview(searchContainer)
        view.addSubview(sectionHeader)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            headerView.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            addButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -16),
            addButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.heightAnchor.constraint(equalToConstant: 28),

            searchContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 14),
            searchContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            searchContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            searchContainer.heightAnchor.constraint(equalToConstant: 36),

            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 10),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),

            sectionHeader.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 16),
            sectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            tableView.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10)
        ])
    }

    private func loadData() {
        allScripts = UserScriptStore.shared.loadScripts()
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if query.isEmpty {
            filteredScripts = allScripts
        } else {
            filteredScripts = allScripts.filter { $0.name.lowercased().contains(query) || $0.matchPattern.lowercased().contains(query) }
        }
        tableView.reloadData()
    }

    @objc private func handleSearchChanged() {
        applyFilter()
    }

    @objc private func handleAddScript() {
        let editor = UserScriptEditorViewController(script: nil)
        editor.onSave = { [weak self] newScript in
            self?.allScripts.append(newScript)
            UserScriptStore.shared.saveScripts(self?.allScripts ?? [])
            self?.loadData()
            self?.onScriptsUpdated?()
        }
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredScripts.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 74
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UserScriptRowCell", for: indexPath) as! UserScriptRowCell
        let script = filteredScripts[indexPath.row]
        cell.configure(script: script, index: indexPath.row)
        cell.onToggle = { [weak self] isEnabled in
            guard let self = self else { return }
            if let idx = self.allScripts.firstIndex(where: { $0.id == script.id }) {
                self.allScripts[idx].isEnabled = isEnabled
                UserScriptStore.shared.saveScripts(self.allScripts)
                self.onScriptsUpdated?()
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let script = filteredScripts[indexPath.row]
        let editor = UserScriptEditorViewController(script: script)
        editor.onSave = { [weak self] updatedScript in
            if let idx = self?.allScripts.firstIndex(where: { $0.id == updatedScript.id }) {
                self?.allScripts[idx] = updatedScript
                UserScriptStore.shared.saveScripts(self?.allScripts ?? [])
                self?.loadData()
                self?.onScriptsUpdated?()
            }
        }
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let script = filteredScripts[indexPath.row]
            ScriptDataStore.shared.clearDataForScript(scriptId: script.id)
            allScripts.removeAll { $0.id == script.id }
            UserScriptStore.shared.saveScripts(allScripts)
            applyFilter()
            onScriptsUpdated?()
        }
    }
}

final class UserScriptRowCell: UITableViewCell {
    private let cardView = UIView()
    private let iconView = UIView()
    private let iconLabel = UILabel()
    private let iconImageView = UIImageView()
    private let nameLabel = UILabel()
    private let matchLabel = UILabel()
    private let toggleSwitch = UISwitch()

    var onToggle: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .white
        cardView.layer.cornerRadius = 16
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.04
        cardView.layer.shadowRadius = 8
        cardView.layer.shadowOffset = CGSize(width: 0, height: 2)
        cardView.clipsToBounds = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.backgroundColor = UIColor(white: 0.95, alpha: 1.0)
        iconView.layer.cornerRadius = 12
        iconView.clipsToBounds = true

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.font = .systemFont(ofSize: 18, weight: .bold)
        iconLabel.textColor = .systemRed
        iconLabel.textAlignment = .center

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.clipsToBounds = true

        iconView.addSubview(iconLabel)
        iconView.addSubview(iconImageView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 15, weight: .bold)
        nameLabel.textColor = .label

        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.font = .systemFont(ofSize: 12, weight: .regular)
        matchLabel.textColor = .secondaryLabel
        matchLabel.lineBreakMode = .byTruncatingTail

        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        toggleSwitch.onTintColor = .systemRed
        toggleSwitch.addTarget(self, action: #selector(handleSwitch), for: .valueChanged)

        let labelStack = UIStackView(arrangedSubviews: [nameLabel, matchLabel])
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.axis = .vertical
        labelStack.spacing = 3

        cardView.addSubview(iconView)
        cardView.addSubview(labelStack)
        cardView.addSubview(toggleSwitch)

        contentView.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),

            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42),

            iconLabel.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            iconImageView.topAnchor.constraint(equalTo: iconView.topAnchor),
            iconImageView.bottomAnchor.constraint(equalTo: iconView.bottomAnchor),
            iconImageView.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            iconImageView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor),

            labelStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            labelStack.trailingAnchor.constraint(equalTo: toggleSwitch.leadingAnchor, constant: -10),
            labelStack.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

            toggleSwitch.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            toggleSwitch.centerYAnchor.constraint(equalTo: cardView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(script: UserScript, index: Int) {
        nameLabel.text = script.name
        matchLabel.text = "匹配: \(script.matchPattern)"
        toggleSwitch.isOn = script.isEnabled

        iconImageView.image = nil
        iconImageView.isHidden = true
        iconLabel.isHidden = false

        let firstChar = String(script.name.prefix(1))
        iconLabel.text = firstChar.isEmpty ? "网" : firstChar

        let colors: [UIColor] = [.systemRed, .systemOrange, .systemBlue, .systemPurple, .systemTeal]
        iconLabel.textColor = colors[index % colors.count]

        if let iconStr = script.iconURL, !iconStr.isEmpty {
            if iconStr.hasPrefix("data:image"), let commaIdx = iconStr.firstIndex(of: ",") {
                let base64Str = String(iconStr[iconStr.index(after: commaIdx)...])
                if let data = Data(base64Encoded: base64Str, options: .ignoreUnknownCharacters), let img = UIImage(data: data) {
                    iconImageView.image = img
                    iconImageView.isHidden = false
                    iconLabel.isHidden = true
                }
            } else if let url = URL(string: iconStr), url.scheme?.hasPrefix("http") == true {
                URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data = data, let img = UIImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self?.iconImageView.image = img
                        self?.iconImageView.isHidden = false
                        self?.iconLabel.isHidden = true
                    }
                }.resume()
            }
        }
    }

    @objc private func handleSwitch() {
        onToggle?(toggleSwitch.isOn)
    }
}
