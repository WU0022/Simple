import UIKit

struct HistorySection {
    let title: String
    let items: [BrowserHistoryItem]
}

final class BrowserHistoryViewController: UITableViewController, UISearchResultsUpdating {
    private var allItems: [BrowserHistoryItem] = []
    private var sections: [HistorySection] = []
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
        filterAndGroupHistory(query: "")
    }

    private func filterAndGroupHistory(query: String) {
        let filtered: [BrowserHistoryItem]
        if query.isEmpty {
            filtered = allItems
        } else {
            filtered = allItems.filter {
                $0.title.lowercased().contains(query) ||
                $0.urlString.lowercased().contains(query)
            }
        }

        var todayItems: [BrowserHistoryItem] = []
        var yesterdayItems: [BrowserHistoryItem] = []
        var earlierItems: [BrowserHistoryItem] = []

        let calendar = Calendar.current

        for item in filtered {
            if calendar.isDateInToday(item.visitedAt) {
                todayItems.append(item)
            } else if calendar.isDateInYesterday(item.visitedAt) {
                yesterdayItems.append(item)
            } else {
                earlierItems.append(item)
            }
        }

        var newSections: [HistorySection] = []
        if !todayItems.isEmpty {
            newSections.append(HistorySection(title: "今天", items: todayItems))
        }
        if !yesterdayItems.isEmpty {
            newSections.append(HistorySection(title: "昨天", items: yesterdayItems))
        }
        if !earlierItems.isEmpty {
            newSections.append(HistorySection(title: "更早", items: earlierItems))
        }

        self.sections = newSections
        tableView.reloadData()
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
        filterAndGroupHistory(query: query)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].items.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "BrowserHistoryCell",
            for: indexPath
        )

        let item = sections[indexPath.section].items[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.secondaryText = "\(item.urlString)\n\(formattedDate(item.visitedAt))"
        content.secondaryTextProperties.numberOfLines = 2
        content.textProperties.numberOfLines = 1
        content.image = UIImage(systemName: "globe")
        content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
        content.imageProperties.cornerRadius = 4

        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator

        if let url = URL(string: item.urlString), let host = url.host {
            FaviconLoader.shared.loadFavicon(for: host) { [weak tableView] image in
                guard let image = image else { return }
                DispatchQueue.main.async {
                    if let currentCell = tableView?.cellForRow(at: indexPath) {
                        var updatedContent = currentCell.defaultContentConfiguration()
                        updatedContent.text = item.title
                        updatedContent.secondaryText = "\(item.urlString)\n\(self.formattedDate(item.visitedAt))"
                        updatedContent.secondaryTextProperties.numberOfLines = 2
                        updatedContent.textProperties.numberOfLines = 1
                        updatedContent.image = image
                        updatedContent.imageProperties.maximumSize = CGSize(width: 24, height: 24)
                        updatedContent.imageProperties.cornerRadius = 4
                        currentCell.contentConfiguration = updatedContent
                    }
                }
            }
        }

        return cell
    }

    override func tableView(
        _ tableView: UITableView,
        didSelectRowAt indexPath: IndexPath
    ) {
        tableView.deselectRow(at: indexPath, animated: true)

        let item = sections[indexPath.section].items[indexPath.row]

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
        let item = sections[indexPath.section].items[indexPath.row]

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
