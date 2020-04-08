//
//  Book.swift
//  fojingdaquan
//
//  Created by tangmonk on 2020/3/21.
//  Copyright © 2020 tangmonk. All rights reserved.
//

import Foundation

class Books {
    init(id: Int64 = 0, title: String = "", location: String = "", categoryId: Int64 = 0, type: String = "", favorite: Int64? = nil) {
        self.id = id
        self.title = title
        self.location = location
        self.categoryId = categoryId
        self.type = type
        self.favorite = favorite
    }
    
    var id: Int64 = 0
    var title = ""
    var location = ""
    var categoryId: Int64 = 0
    var type = ""
    var favorite: Int64?

}
