//
//  MainTableViewController.swift
//  fojingdaquan
//
//  Created by tangmonk on 2020/3/21.
//  Copyright © 2020 tangmonk. All rights reserved.
//

import UIKit
import os.log
import FolioReaderKit

class MainTableViewController2: UITableViewController, UISearchResultsUpdating {
    var parentId: Int64? = nil
    var items: [AnyObject] = []
    let searchController = UISearchController(searchResultsController: nil)

    //MARK: life circle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if parentId == nil {
            parentId = DatabaseAccessor.cebieRootId()
        }
        items = DatabaseAccessor.byCebie(parentId: parentId)
        
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        
        tableView.tableHeaderView = searchController.searchBar
        
        definesPresentationContext = true
    }
    //MARK: swipe to favorite
    
    override func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        
        var actions: [UITableViewRowAction] = []
        let item = items[indexPath.row]
        var favorited: Bool = false
        
        if let book = item as? Books {
            if book.favorite == 1 {
                favorited = true
            }
        }else if let category = item as? Categories {
            if category.favorite == 1 {
                favorited = true
            }
        }
        
        if favorited {
            let defavoriteAction =  UITableViewRowAction(style: .normal,
              title: "取消收藏") { (action, indexPath) in
                let item = self.items[indexPath.row]
                DatabaseAccessor.deFavorite(object: item)
                if let book = item as? Books {
                    book.favorite = 0
                    self.items[indexPath.row] = book
                }else if let category = item as? Categories {
                    category.favorite = 0
                    self.items[indexPath.row] = category
                }
            }
            actions.append(defavoriteAction)
        }else{
            let favoriteAction =  UITableViewRowAction(style: .normal,
              title: "收藏") { (action, indexPath) in
                let item = self.items[indexPath.row]
                DatabaseAccessor.setFavorite(object: item)
                
                if let book = item as? Books {
                    book.favorite = 1
                    self.items[indexPath.row] = book
                }else if let category = item as? Categories {
                    category.favorite = 1
                    self.items[indexPath.row] = category
                }
            }
            actions.append(favoriteAction)
        }
        
        return actions
    }
   
    // MARK: Search
    
    func updateSearchResults(for searchController: UISearchController) {
        let searchBar = searchController.searchBar
        
        if searchBar.text != nil && searchBar.text!.count >= 1{
            items = DatabaseAccessor.searchByTitle(title: searchBar.text!)
        }else{
            items = DatabaseAccessor.byBulei(parentId: parentId)
        }
        tableView.reloadData()
    }
    
    // MARK: - Table view data source
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        // #warning Incomplete implementation, return the number of sections
        return 1
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // #warning Incomplete implementation, return the number of rows
        return items.count
    }
    
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "mainCell", for: indexPath)
        
        if let book = items[indexPath.row] as? Books {
            cell.textLabel?.text = book.title
            cell.accessoryType = .none;
        }else if let category = items[indexPath.row] as? Categories{
            cell.textLabel?.text = category.title
            cell.accessoryType = .disclosureIndicator;
        }
        
        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = items[indexPath.row]
        if let book = item as? Books {

            guard let bookPath = Bundle.main.path(forResource: "cbeta_epub_2019q4.bundle/\(book.location)", ofType: "epub") else { return }

            let folioReader = FolioReader()
            let config = FolioReaderConfig()
            config.shouldHideNavigationOnTap = true
            
            config.canChangeScrollDirection = true
            config.enableTTS = false
            config.displayTitle = true
            config.allowSharing = true
            config.tintColor = hexStringToUIColor(hex: "#0a84ff")
            config.hideBars = false
            config.canChangeFontStyle = false
            
            config.menuTextColor = UIColor.brown
            config.hidePageIndicator = true
            
            folioReader.presentReader(parentViewController: self, withEpubPath: bookPath, andConfig: config)

        }else if let category = item as? Categories {
            let storyboard = UIStoryboard(name: "Main", bundle: nil)
            guard let controller = storyboard.instantiateViewController(withIdentifier: "mainTableView2") as? MainTableViewController2
                else { fatalError("error with navigation category") }
            controller.parentId = category.id
            controller.title = category.title
            navigationController?.pushViewController(controller, animated: true)
        }
        
        
    }
    
    /*
     // Override to support conditional editing of the table view.
     override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
     // Return false if you do not want the specified item to be editable.
     return true
     }
     */
    
    /*
     // Override to support editing the table view.
     override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
     if editingStyle == .delete {
     // Delete the row from the data source
     tableView.deleteRows(at: [indexPath], with: .fade)
     } else if editingStyle == .insert {
     // Create a new instance of the appropriate class, insert it into the array, and add a new row to the table view
     }
     }
     */
    
    /*
     // Override to support rearranging the table view.
     override func tableView(_ tableView: UITableView, moveRowAt fromIndexPath: IndexPath, to: IndexPath) {
     
     }
     */
    
    /*
     // Override to support conditional rearranging of the table view.
     override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
     // Return false if you do not want the item to be re-orderable.
     return true
     }
     */
    
    /*
     // MARK: - Navigation
     
     // In a storyboard-based application, you will often want to do a little preparation before navigation
     override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
     // Get the new view controller using segue.destination.
     // Pass the selected object to the new view controller.
     }
     */
    
}
