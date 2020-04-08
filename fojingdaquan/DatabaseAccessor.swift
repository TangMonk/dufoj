//
//  DatabaseAccessor.swift
//  fojingdaquan
//
//  Created by tangmonk on 2020/3/18.
//  Copyright © 2020 tangmonk. All rights reserved.
//

import Foundation
import SQLite


class DatabaseAccessor {
    struct category {
        static  var table = Table("category")
        static  var id = Expression<Int64>("id")
        static  var title = Expression<String?>("title")
        static  var type = Expression<String?>("title")
        static  var parentId = Expression<Int64>("id")
    }
    
    struct book {
        var table = Table("books")
        var id = Expression<Int64>("id")
        var title = Expression<String?>("title")
        var location = Expression<String>("location")
        var categoryId = Expression<Int64>("categoryId")
        var type = Expression<String>("type")
    }
    
    struct favorite {
        var table = Table("favorites")
        var id = Expression<Int64>("id")
        var category_id = Expression<Int64?>("category_id")
        var book_id = Expression<Int64?>("book_id")
    }
    
    // The instance of DatabaseAccessor
    

    // Private initializer to avoid instancing by other classes
    private init() {}

    // The instance of the SQLite database
    public static var mainDB: Connection?

    public static func initializeDatabase() {
        let fileManager = FileManager.default
        
        let documentsUrl = fileManager.urls(for: .documentDirectory,
                                                    in: .userDomainMask)
        
        guard documentsUrl.count != 0 else {
            return // Could not find documents URL
        }
        
        let finalDatabaseURL = documentsUrl.first!.appendingPathComponent("dufoj.sqlite3")
        
        do{
            DatabaseAccessor.mainDB = try Connection(finalDatabaseURL.absoluteString)
        }catch{
            fatalError(error.localizedDescription)
        }
    }
    
    public static func searchByTitle(title: String) -> [AnyObject] {
        var title2 = title.replacingOccurrences(of: "'", with: "", options: NSString.CompareOptions.literal, range: nil)
        title2 = title.replacingOccurrences(of: "?", with: "", options: NSString.CompareOptions.literal, range: nil)

        var result: [AnyObject] = []
        
        for row in try! mainDB!.prepare("select id, title, type, parentId from category where title LIKE '%\(title2)%'") {
            
            let category = Categories(id: row[0] as! Int64, title: row[1] as! String, type: row[2] as! String, parentId: row[3] as! Int64)
            
            result.append(category)
        }
        
        for row in try! mainDB!.prepare("select id, title, location, categoryId, type from books where title LIKE '%\(title2)%'") {
            
            let book = Books(id: row[0] as! Int64, title: row[1] as! String, location: row[2] as! String, categoryId: row[3] as! Int64, type: row[4] as! String)
            
            result.append(book)
        }
        
        return result
    }
    
    //根据部类
    public static func byBulei(parentId: Int64? = nil) -> [AnyObject] {
        var result: [AnyObject] = []
        
        do {
            if parentId == nil {
                for row in try mainDB!.prepare("select id, title, type, parentId from category where parentId = (select id from category where title = '根据部类')") {
                    
                    let category = Categories(id: row[0] as! Int64, title: row[1] as! String, type: row[2] as! String, parentId: row[3] as! Int64)
                    
                    result.append(category)
                }
                
            }else{
                
                for row in try mainDB!.prepare("select id, title, type, parentId, favorite from category where parentId = ?", [parentId]) {
                    
                    let category = Categories(id: row[0] as! Int64, title: row[1] as! String, type: row[2] as! String, parentId: row[3] as! Int64, favorite: row[4] as? Int64)
                    
                    result.append(category)
                }
                
                for row in try mainDB!.prepare("select id, title, location, categoryId, type, favorite from books where categoryId = ?", [parentId]) {
                    
                    let book = Books(id: row[0] as! Int64, title: row[1] as! String, location: row[2] as! String, categoryId: row[3] as! Int64, type: row[4] as! String, favorite: row[5] as? Int64)
                    
                    result.append(book)
                }
            }
            
        }catch{
            fatalError(error.localizedDescription)
        }
        
        
        return result
    }
    
    public static func buleiRootId() -> Int64?{
        let bulei = try! mainDB?.pluck(category.table.filter(category.title == "根据部类"))
        return bulei?[category.id]
    }
    
    //根据册别
    public static func byCebie(parentId: Int64? = nil) -> [AnyObject] {
        var result: [AnyObject] = []
        
        do {
            if parentId == nil {
                for row in try mainDB!.prepare("select id, title, type, parentId from category where parentId = (select id from category where title = '根据册别')") {
                    
                    let category = Categories(id: row[0] as! Int64, title: row[1] as! String, type: row[2] as! String, parentId: row[3] as! Int64)
                    
                    result.append(category)
                }
                
            }else{
                
                for row in try mainDB!.prepare("select id, title, type, parentId, favorite from category where parentId = ?", [parentId]) {
                    
                    let category = Categories(id: row[0] as! Int64, title: row[1] as! String, type: row[2] as! String, parentId: row[3] as! Int64, favorite: row[4] as? Int64)
                    
                    result.append(category)
                }
                
                for row in try mainDB!.prepare("select id, title, location, categoryId, type, favorite from books where categoryId = ?", [parentId]) {
                    
                    let book = Books(id: row[0] as! Int64, title: row[1] as! String, location: row[2] as! String, categoryId: row[3] as! Int64, type: row[4] as! String, favorite: row[5] as? Int64)
                    
                    result.append(book)
                }
            }
            
        }catch{
            fatalError(error.localizedDescription)
        }
        
        
        return result
    }
    
    public static func cebieRootId() -> Int64?{
        let bulei = try! mainDB?.pluck(category.table.filter(category.title == "根据册别"))
        return bulei?[category.id]
    }
    
    public static func setFavorite(object: AnyObject) {
        if let book = object as? Books {
            try! mainDB?.run("update books set favorite = 1 where id = \(book.id)")
            try! mainDB?.run("replace into favorites (book_id) values (\(book.id))")
        }else if let category = object as? Categories {
            try! mainDB?.execute("update category set favorite = 1 where id = \(category.id); replace into favorites (category_id) values (\(category.id))")
        }
    }
    
    public static func deFavorite(object: AnyObject) {
        if let book = object as? Books {
            try! mainDB?.execute("update books set favorite = 0  where id = \(book.id)")
            try! mainDB?.execute("delete from favorites where book_id = \(book.id)")
        }else if let category = object as? Categories {
            try! mainDB?.execute("update category set favorite = 0 where id = \(category.id)")
            try! mainDB?.execute("delete from favorites where category_id = \(category.id)")
        }
    }
    
    public static func getFavorites() -> [AnyObject]{
        var result: [AnyObject] = []
        
        for row in try! mainDB!.prepare("SELECT * from favorites f LEFT JOIN books b on b.id = f.book_id LEFT JOIN category c on c.id = f.category_id") {
            let book_id = row[1]
            let category_id = row[2]
            
            if book_id != nil {
                let book = Books(id: row[3] as! Int64, title: row[4] as! String, location: row[6] as! String, categoryId: row[7] as! Int64, type: row[8] as! String)
                result.append(book)

            }else if category_id != nil {
                let category = Categories(id: row[10] as! Int64, title: row[11] as! String, type: row[12] as! String, parentId: row[13] as! Int64)
                result.append(category)

            }
            
        }
        return result
        
    }
}
