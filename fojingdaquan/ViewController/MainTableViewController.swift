//
//  MainTableViewController.swift
//  fojingdaquan
//
//  Created by tangmonk on 2020/3/21.
//  Copyright © 2020 tangmonk. All rights reserved.
//

import UIKit

class BookListTableViewController: UITableViewController, UISearchResultsUpdating {
    var parentId: Int64? = nil
    var items: [AnyObject] = []

    private let searchController = UISearchController(searchResultsController: nil)
    private var pendingSearchWorkItem: DispatchWorkItem?
    private var searchRequestId = 0

    var rootCategoryId: Int64? {
        return nil
    }

    var childStoryboardIdentifier: String {
        return ""
    }

    func loadItems(parentId: Int64?) -> [AnyObject] {
        return []
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if parentId == nil {
            parentId = rootCategoryId
        }

        setupSearchController()
        reloadItems(searchText: nil, debounce: false)
    }

    deinit {
        pendingSearchWorkItem?.cancel()
    }

    private func setupSearchController() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索经书"
        tableView.tableHeaderView = searchController.searchBar
        definesPresentationContext = true
    }

    func updateSearchResults(for searchController: UISearchController) {
        reloadItems(searchText: searchController.searchBar.text, debounce: true)
    }

    private func reloadItems(searchText: String?, debounce: Bool) {
        pendingSearchWorkItem?.cancel()
        searchRequestId += 1

        let requestId = searchRequestId
        let keyword = searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parentId = self.parentId

        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                let loadedItems: [AnyObject]
                if let keyword = keyword, !keyword.isEmpty {
                    loadedItems = DatabaseAccessor.searchByTitle(title: keyword)
                } else {
                    loadedItems = self.loadItems(parentId: parentId)
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.searchRequestId == requestId else {
                        return
                    }

                    self.items = loadedItems
                    self.tableView.reloadData()
                }
            }
        }

        pendingSearchWorkItem = workItem
        if debounce {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        } else {
            workItem.perform()
        }
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard items.indices.contains(indexPath.row) else {
            return nil
        }

        let favorited = isFavorited(items[indexPath.row])
        let title = favorited ? "取消收藏" : "收藏"
        let action = UIContextualAction(style: .normal, title: title) { [weak self] _, _, completion in
            guard let self = self, self.items.indices.contains(indexPath.row) else {
                completion(false)
                return
            }

            let item = self.items[indexPath.row]
            let success = favorited ? DatabaseAccessor.deFavorite(object: item) : DatabaseAccessor.setFavorite(object: item)
            if success {
                self.updateFavoriteFlag(at: indexPath, favorited: !favorited)
            } else {
                ShowMessage(controller: self, msg: "收藏状态更新失败", title: "错误")
            }
            completion(success)
        }

        action.backgroundColor = favorited ? UIColor.red : UIColor.orange
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "mainCell", for: indexPath)

        if let book = items[indexPath.row] as? Books {
            cell.textLabel?.text = book.title
            cell.accessoryType = .none
        } else if let category = items[indexPath.row] as? Categories {
            cell.textLabel?.text = category.title
            cell.accessoryType = .disclosureIndicator
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let item = items[indexPath.row]
        if let book = item as? Books {
            openEpubReader(book: book)
        } else if let category = item as? Categories {
            let storyboard = UIStoryboard(name: "Main", bundle: nil)
            guard let controller = storyboard.instantiateViewController(withIdentifier: childStoryboardIdentifier) as? BookListTableViewController else {
                ShowMessage(controller: self, msg: "无法打开分类", title: "错误")
                return
            }
            controller.parentId = category.id
            controller.title = category.title
            navigationController?.pushViewController(controller, animated: true)
        }
    }

    private func isFavorited(_ item: AnyObject) -> Bool {
        if let book = item as? Books {
            return book.favorite == 1
        } else if let category = item as? Categories {
            return category.favorite == 1
        }
        return false
    }

    private func updateFavoriteFlag(at indexPath: IndexPath, favorited: Bool) {
        guard items.indices.contains(indexPath.row) else {
            return
        }

        let value: Int64 = favorited ? 1 : 0
        if let book = items[indexPath.row] as? Books {
            book.favorite = value
        } else if let category = items[indexPath.row] as? Categories {
            category.favorite = value
        }

        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}

class MainTableViewController: BookListTableViewController {
    override var rootCategoryId: Int64? {
        return DatabaseAccessor.buleiRootId()
    }

    override var childStoryboardIdentifier: String {
        return "mainTableView"
    }

    override func loadItems(parentId: Int64?) -> [AnyObject] {
        return DatabaseAccessor.byBulei(parentId: parentId)
    }
}
