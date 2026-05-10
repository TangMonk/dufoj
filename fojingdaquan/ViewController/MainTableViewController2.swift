//
//  MainTableViewController2.swift
//  fojingdaquan
//
//  Created by tangmonk on 2020/3/21.
//  Copyright © 2020 tangmonk. All rights reserved.
//

import UIKit

class MainTableViewController2: BookListTableViewController {
    override var rootCategoryId: Int64? {
        return DatabaseAccessor.cebieRootId()
    }

    override var childStoryboardIdentifier: String {
        return "mainTableView2"
    }

    override func loadItems(parentId: Int64?) -> [AnyObject] {
        return DatabaseAccessor.byCebie(parentId: parentId)
    }
}
