import UIKit

final class BrowserHistoryViewController: UITableViewController, UISearchResultsUpdating {
    private var allItems: [BrowserHistoryItem] = []
    private var filteredItems: [BrowserHistoryItem] = []
    private let searchController = UISearchController(searchResultsController: nil)

    var onSelectURL: ((URL) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "历史记录"

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "BrowserHistoryCell")

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索历史记录"

        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭",
            style: .plain,
            target: self,
            action: #selector(handleClose)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "清空",
            style: .plain,
            target: self,
            action: #selector(handleClear)
        )

        loadData()
    }

    private func loadData() {
        allItems = BrowserHistoryStore.shared.loadHistory()
        updateSearchResults(for: searchController)
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    @objc private func handleClear() {
        guard !allItems.isEmpty else {
            return
        }

        let alert = UIAlertController(
            title: "清空历史记录",
            message: "确定要清空全部浏览历史记录吗？",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            BrowserHistoryStore.shared.clearHistory()
            self?.loadData()
        })

        present(alert, animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if query.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter {
                $0.title.lowercased().contains(query) ||
                $0.urlString.lowercased().contains(query)
            }
        }

        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredItems.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "BrowserHistoryCell",
            for: indexPath
        )

        let item = filteredItems[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.secondaryText = "\(item.urlString)\n\(formattedDate(item.visitedAt))"
        content.secondaryTextProperties.numberOfLines = 2
        content.textProperties.numberOfLines = 1

        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator

        return cell
    }

    override func tableView(
        _ tableView: UITableView,
        didSelectRowAt indexPath: IndexPath
    ) {
        tableView.deselectRow(at: indexPath, animated: true)

        let item = filteredItems[indexPath.row]

        guard let url = URL(string: item.urlString) else {
            return
        }

        dismiss(animated: true) { [weak self] in
            self?.onSelectURL?(url)
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let item = filteredItems[indexPath.row]

        let deleteAction = UIContextualAction(
            style: .destructive,
            title: "删除"
        ) { [weak self] _, _, completion in
            BrowserHistoryStore.shared.delete(id: item.id)
            self?.loadData()
            completion(true)
        }

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
