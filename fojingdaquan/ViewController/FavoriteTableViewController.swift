//
//  MainTableViewController.swift
//  fojingdaquan
//
//  Created by tangmonk on 2020/3/21.
//  Copyright © 2020 tangmonk. All rights reserved.
//

import UIKit
import os.log

class FavoriteTableViewController: UITableViewController {
    var parentId: Int64? = nil
    var items: [AnyObject] = []
    let searchController = UISearchController(searchResultsController: nil)
    private let favoriteGuideView = UIView()
    private let favoriteGuideLabel = UILabel()
    private let favoriteGuideBookView = UIImageView()
    private let favoriteGuideArrowLabel = UILabel()
    private var didSetupFavoriteGuide = false

    //MARK: life circle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupFavoriteGuideIfNeeded()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if (parentId != nil) {
            items = DatabaseAccessor.byCebie(parentId: parentId)
        }else{
            items = DatabaseAccessor.getFavorites()
        }
        
        updateFavoriteGuideVisibility()
        tableView.reloadData()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startFavoriteGuideAnimation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        favoriteGuideBookView.layer.removeAnimation(forKey: "favoriteGuideSlide")
        favoriteGuideArrowLabel.layer.removeAnimation(forKey: "favoriteGuideFade")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateFavoriteGuideHeaderSize()
    }

    private func setupFavoriteGuideIfNeeded() {
        guard parentId == nil, !didSetupFavoriteGuide else {
            return
        }

        didSetupFavoriteGuide = true
        favoriteGuideView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 64)
        favoriteGuideView.backgroundColor = UIColor(red: 0.96, green: 0.94, blue: 0.89, alpha: 1)

        favoriteGuideLabel.text = "按住书籍往左边滑动即可收藏"
        favoriteGuideLabel.font = UIFont.systemFont(ofSize: 14)
        favoriteGuideLabel.textColor = UIColor(red: 0.34, green: 0.28, blue: 0.18, alpha: 1)
        favoriteGuideLabel.numberOfLines = 2
        favoriteGuideLabel.translatesAutoresizingMaskIntoConstraints = false

        favoriteGuideBookView.image = UIImage(named: "book")
        favoriteGuideBookView.contentMode = .scaleAspectFit
        favoriteGuideBookView.translatesAutoresizingMaskIntoConstraints = false

        favoriteGuideArrowLabel.text = "<"
        favoriteGuideArrowLabel.font = UIFont.systemFont(ofSize: 22, weight: .semibold)
        favoriteGuideArrowLabel.textColor = UIColor(red: 0.54, green: 0.42, blue: 0.20, alpha: 1)
        favoriteGuideArrowLabel.translatesAutoresizingMaskIntoConstraints = false

        favoriteGuideView.addSubview(favoriteGuideBookView)
        favoriteGuideView.addSubview(favoriteGuideArrowLabel)
        favoriteGuideView.addSubview(favoriteGuideLabel)

        NSLayoutConstraint.activate([
            favoriteGuideBookView.leadingAnchor.constraint(equalTo: favoriteGuideView.leadingAnchor, constant: 18),
            favoriteGuideBookView.centerYAnchor.constraint(equalTo: favoriteGuideView.centerYAnchor),
            favoriteGuideBookView.widthAnchor.constraint(equalToConstant: 28),
            favoriteGuideBookView.heightAnchor.constraint(equalToConstant: 28),

            favoriteGuideArrowLabel.leadingAnchor.constraint(equalTo: favoriteGuideBookView.trailingAnchor, constant: 8),
            favoriteGuideArrowLabel.centerYAnchor.constraint(equalTo: favoriteGuideBookView.centerYAnchor),
            favoriteGuideArrowLabel.widthAnchor.constraint(equalToConstant: 20),

            favoriteGuideLabel.leadingAnchor.constraint(equalTo: favoriteGuideArrowLabel.trailingAnchor, constant: 14),
            favoriteGuideLabel.trailingAnchor.constraint(equalTo: favoriteGuideView.trailingAnchor, constant: -16),
            favoriteGuideLabel.centerYAnchor.constraint(equalTo: favoriteGuideView.centerYAnchor)
        ])

        updateFavoriteGuideVisibility()
    }

    private func updateFavoriteGuideVisibility() {
        guard parentId == nil else {
            if tableView.tableHeaderView === favoriteGuideView {
                tableView.tableHeaderView = nil
            }
            return
        }

        if items.isEmpty {
            tableView.tableHeaderView = favoriteGuideView
            updateFavoriteGuideHeaderSize()
            startFavoriteGuideAnimation()
        } else if tableView.tableHeaderView === favoriteGuideView {
            favoriteGuideBookView.layer.removeAnimation(forKey: "favoriteGuideSlide")
            favoriteGuideArrowLabel.layer.removeAnimation(forKey: "favoriteGuideFade")
            tableView.tableHeaderView = nil
        }
    }

    private func updateFavoriteGuideHeaderSize() {
        guard tableView.tableHeaderView === favoriteGuideView else {
            return
        }

        let targetSize = CGSize(width: tableView.bounds.width, height: 64)
        if favoriteGuideView.frame.size != targetSize {
            favoriteGuideView.frame.size = targetSize
            tableView.tableHeaderView = favoriteGuideView
        }
    }

    private func startFavoriteGuideAnimation() {
        guard tableView.tableHeaderView === favoriteGuideView else {
            return
        }

        favoriteGuideBookView.layer.removeAnimation(forKey: "favoriteGuideSlide")
        favoriteGuideArrowLabel.layer.removeAnimation(forKey: "favoriteGuideFade")

        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 0
        slide.toValue = -20
        slide.duration = 0.9
        slide.autoreverses = true
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        favoriteGuideBookView.layer.add(slide, forKey: "favoriteGuideSlide")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.35
        fade.toValue = 1.0
        fade.duration = 0.9
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        favoriteGuideArrowLabel.layer.add(fade, forKey: "favoriteGuideFade")
    }
    //MARK: swipe to defavorite
    
    override func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        let defavoriteAction =  UITableViewRowAction(style: .normal,
          title: "取消收藏") { (action, indexPath) in
            let item = self.items[indexPath.row]
            DatabaseAccessor.deFavorite(object: item)
            self.items.remove(at: indexPath.row)
            self.updateFavoriteGuideVisibility()
            tableView.reloadData()
        }
        
        return [defavoriteAction]
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
            openEpubReader(book: book)

        }else if let category = item as? Categories {
            let storyboard = UIStoryboard(name: "Main", bundle: nil)
            guard let controller = storyboard.instantiateViewController(withIdentifier: "favoriteTableView") as? FavoriteTableViewController
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
