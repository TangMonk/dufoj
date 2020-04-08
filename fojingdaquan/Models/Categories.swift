//
//  Category.swift
//  fojingdaquan
//
//  Created by tangmonk on 2020/3/21.
//  Copyright © 2020 tangmonk. All rights reserved.
//

import Foundation

class Categories {
    init(id: Int64 = 0, title: String = "", type: String = "", parentId: Int64 = 0, favorite: Int64? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.parentId = parentId
        self.favorite = favorite
    }
    
    var id: Int64 = 0
    var title = ""
    var type = ""
    var parentId:Int64 = 0
    var favorite: Int64?

   
}
