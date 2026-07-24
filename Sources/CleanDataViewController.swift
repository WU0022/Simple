import UIKit

final class CleanDataSelectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var selectedOptions: Set<CleanOption> = [.cache]
    private let savedOptionsKey = "browser_saved_clean_options_v1"

    var onConfirmClean: ((Set<CleanOption>, @escaping () -> Void) -> Void)?
    var onOpenWebsiteDataManager: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "清除数据"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(handleCancel))

        setupInterface()
        loadSavedOptions()
    }

    private func setupInterface() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(CleanOptionRowCell.self, forCellReuseIdentifier: "CleanOptionRowCell")

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadSavedOptions() {
        if let saved = UserDefaults.standard.array(forKey: savedOptionsKey) as? [Int] {
            let opts = saved.compactMap { CleanOption(rawValue: $0) }
            selectedOptions = Set(opts)
        }
    }

    private func saveOptions() {
        let rawValues = selectedOptions.map { $0.rawValue }
        UserDefaults.standard.set(rawValues, forKey: savedOptionsKey)
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }

    @objc private func requestCleanConfirmation() {
        guard !selectedOptions.isEmpty else { return }

        var message = "确定要执行清理操作吗？"
        if selectedOptions.contains(.loginAndData) {
            message = "勾选了“登录与本地数据”，未受保护网站的 Cookies 和本地数据库将被清除。"
        }

        let alert = UIAlertController(title: "确认清理", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "确定清理", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let opts = self.selectedOptions
            self.onConfirmClean?(opts) { [weak self] in
                guard let self = self else { return }
                let successAlert = UIAlertController(title: nil, message: "清理完成", preferredStyle: .alert)
                self.present(successAlert, animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    successAlert.dismiss(animated: true)
                }
            }
        })
        present(alert, animated: true)
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return 3
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 4 }
        return 1
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 52
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "CleanOptionRowCell", for: indexPath) as! CleanOptionRowCell

        if indexPath.section == 0 {
            let option: CleanOption
            let titleText: String
            switch indexPath.row {
            case 0:
                titleText = "网页缓存文件"
                option = .cache
            case 1:
                titleText = "登录与本地数据"
                option = .loginAndData
            case 2:
                titleText = "搜索与浏览历史记录"
                option = .searchHistory
            default:
                titleText = "用户脚本缓存数据"
                option = .scriptData
            }

            let isChecked = selectedOptions.contains(option)
            cell.configure(title: titleText, isChecked: isChecked, isActionButton: false)
        } else if indexPath.section == 1 {
            cell.configure(title: "确认清理", isChecked: false, isActionButton: true, textColor: .systemBlue)
        } else {
            cell.configure(title: "管理网站数据", isChecked: false, isActionButton: true, textColor: .systemBlue)
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if indexPath.section == 0 {
            let option: CleanOption
            switch indexPath.row {
            case 0: option = .cache
            case 1: option = .loginAndData
            case 2: option = .searchHistory
            default: option = .scriptData
            }

            if selectedOptions.contains(option) {
                selectedOptions.remove(option)
            } else {
                selectedOptions.insert(option)
            }
            saveOptions()
            tableView.reloadRows(at: [indexPath], with: .automatic)
        } else if indexPath.section == 1 {
            requestCleanConfirmation()
        } else {
            dismiss(animated: true) { [weak self] in
                self?.onOpenWebsiteDataManager?()
            }
        }
    }
}

final class CleanOptionRowCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let checkIcon = UIImageView()
    private var regularConstraints: [NSLayoutConstraint] = []
    private var centeredConstraints: [NSLayoutConstraint] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .secondarySystemGroupedBackground

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)

        checkIcon.translatesAutoresizingMaskIntoConstraints = false
        checkIcon.image = UIImage(systemName: "checkmark")
        checkIcon.tintColor = .systemBlue

        contentView.addSubview(titleLabel)
        contentView.addSubview(checkIcon)

        regularConstraints = [
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkIcon.leadingAnchor, constant: -8),
            checkIcon.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            checkIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            checkIcon.widthAnchor.constraint(equalToConstant: 18),
            checkIcon.heightAnchor.constraint(equalToConstant: 18)
        ]

        centeredConstraints = [
            titleLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ]

        NSLayoutConstraint.activate(regularConstraints)
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, isChecked: Bool, isActionButton: Bool, textColor: UIColor? = nil) {
        titleLabel.text = title

        if isActionButton {
            titleLabel.textColor = textColor ?? .label
            titleLabel.textAlignment = .center
            titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            checkIcon.isHidden = true
            NSLayoutConstraint.deactivate(regularConstraints)
            NSLayoutConstraint.activate(centeredConstraints)
        } else {
            titleLabel.textColor = .label
            titleLabel.textAlignment = .left
            titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
            checkIcon.isHidden = !isChecked
            NSLayoutConstraint.deactivate(centeredConstraints)
            NSLayoutConstraint.activate(regularConstraints)
        }
    }
}
