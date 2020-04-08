//
//  Favorite.swift
//  fojingdaquan
//
//  Created by tangmonk on 2020/4/7.
//  Copyright © 2020 tangmonk. All rights reserved.
//

import Foundation

class Favorite {
    internal init(id: Int64 = 0, category_id: Int64, book_id: Int64) {
        self.id = id
        self.category_id = category_id
        self.book_id = book_id
    }
    
    var id: Int64 = 0
    var category_id: Int64
    var book_id: Int64
   
}
