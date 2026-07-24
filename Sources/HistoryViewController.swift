import UIKit

final class HistoryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {
    private var allItems: [HistoryItem] = []
    private var filteredItems: [HistoryItem] = []
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchController = UISearchController(searchResultsController: nil)

    var onSelectURL: ((URL) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "历史记录"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "清空",
            style: .plain,
            target: self,
            action: #selector(handleClearAll)
        )
        navigationItem.leftBarButtonItem?.tintColor = .systemRed

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(handleDone)
        )

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索历史记录"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "HistoryCell")

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        loadData()
    }

    private func loadData() {
        allItems = HistoryStore.shared.getHistory()
        updateSearchResults(for: searchController)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let searchText = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if searchText.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter {
                $0.title.lowercased().contains(searchText) || $0.urlString.lowercased().contains(searchText)
            }
        }
        tableView.reloadData()
    }

    @objc private func handleDone() {
        dismiss(animated: true)
    }

    @objc private func handleClearAll() {
        guard !allItems.isEmpty else { return }
        let alert = UIAlertController(title: "清空历史记录", message: "确定要清空所有浏览历史记录吗？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定清空", style: .destructive) { [weak self] _ in
            HistoryStore.shared.clearHistory()
            self?.loadData()
        })
        present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "HistoryCell")
        let item = filteredItems[indexPath.row]

        cell.textLabel?.text = item.title
        cell.textLabel?.font = .systemFont(ofSize: 15, weight: .medium)

        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let dateStr = formatter.string(from: item.timestamp)

        cell.detailTextLabel?.text = "\(dateStr) - \(item.urlString)"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = filteredItems[indexPath.row]
        guard let url = URL(string: item.urlString) else { return }

        dismiss(animated: true) { [weak self] in
            self?.onSelectURL?(url)
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < filteredItems.count else { return nil }
        let item = filteredItems[indexPath.row]

        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            HistoryStore.shared.removeHistory(id: item.id)
            self?.loadData()
            completion(true)
        }

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
}
