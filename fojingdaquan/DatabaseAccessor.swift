//
//  DatabaseAccessor.swift
//  fojingdaquan
//
//  Created by tangmonk on 2020/3/18.
//  Copyright © 2020 tangmonk. All rights reserved.
//

import Foundation
import SQLite

class Excerpt {
    let id: Int64
    let bookTitle: String
    let bookLocation: String
    let chapterIndex: Int
    let chapterTitle: String
    let selectedText: String
    let occurrence: Int
    let createdAt: Double

    init(id: Int64,
         bookTitle: String,
         bookLocation: String,
         chapterIndex: Int,
         chapterTitle: String,
         selectedText: String,
         occurrence: Int,
         createdAt: Double) {
        self.id = id
        self.bookTitle = bookTitle
        self.bookLocation = bookLocation
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.selectedText = selectedText
        self.occurrence = occurrence
        self.createdAt = createdAt
    }
}


class DatabaseAccessor {
    struct category {
        static  var table = Table("category")
        static  var id = Expression<Int64>("id")
        static  var title = Expression<String?>("title")
        static  var type = Expression<String?>("type")
        static  var parentId = Expression<Int64>("parentId")
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
    private static let databaseQueue = DispatchQueue(label: "dufoj.database.queue")

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
            createExcerptTableIfNeeded()
        }catch{
            LogDebug(log: "Database initialize failed: \(error.localizedDescription)")
        }
    }

    private static func read<T>(_ fallback: T, _ block: (Connection) throws -> T) -> T {
        return databaseQueue.sync {
            guard let db = mainDB else {
                LogDebug(log: "Database is not initialized")
                return fallback
            }

            do {
                return try block(db)
            } catch {
                LogDebug(log: "Database read failed: \(error.localizedDescription)")
                return fallback
            }
        }
    }

    private static func write(_ block: (Connection) throws -> Void) -> Bool {
        return databaseQueue.sync {
            guard let db = mainDB else {
                LogDebug(log: "Database is not initialized")
                return false
            }

            do {
                try block(db)
                return true
            } catch {
                LogDebug(log: "Database write failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    private static func write<T>(_ fallback: T, _ block: (Connection) throws -> T) -> T {
        return databaseQueue.sync {
            guard let db = mainDB else {
                LogDebug(log: "Database is not initialized")
                return fallback
            }

            do {
                return try block(db)
            } catch {
                LogDebug(log: "Database write failed: \(error.localizedDescription)")
                return fallback
            }
        }
    }

    private static func createExcerptTableIfNeeded() {
        _ = write { db in
            try db.run("""
            CREATE TABLE IF NOT EXISTS excerpts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_title TEXT NOT NULL,
                book_location TEXT NOT NULL,
                chapter_index INTEGER NOT NULL,
                chapter_title TEXT NOT NULL,
                selected_text TEXT NOT NULL,
                occurrence INTEGER NOT NULL,
                created_at REAL NOT NULL
            )
            """)
        }
    }

    private static func excerpt(from row: Statement.Element) -> Excerpt {
        return Excerpt(id: row[0] as! Int64,
                       bookTitle: row[1] as! String,
                       bookLocation: row[2] as! String,
                       chapterIndex: Int(row[3] as! Int64),
                       chapterTitle: row[4] as! String,
                       selectedText: row[5] as! String,
                       occurrence: Int(row[6] as! Int64),
                       createdAt: (row[7] as? Double) ?? (row[7] as? NSNumber)?.doubleValue ?? 0)
    }
    
    public static func searchByTitle(title: String) -> [AnyObject] {
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            return []
        }

        return read([]) { db in
            var result: [AnyObject] = []
            let pattern = "%\(keyword)%"

            for row in try db.prepare("select id, title, type, parentId, favorite from category where title LIKE ?", [pattern]) {
                let category = Categories(id: row[0] as! Int64,
                                          title: row[1] as! String,
                                          type: row[2] as! String,
                                          parentId: row[3] as! Int64,
                                          favorite: row[4] as? Int64)
                result.append(category)
            }

            for row in try db.prepare("select id, title, location, categoryId, type, favorite from books where title LIKE ?", [pattern]) {
                let book = Books(id: row[0] as! Int64,
                                 title: row[1] as! String,
                                 location: row[2] as! String,
                                 categoryId: row[3] as! Int64,
                                 type: row[4] as! String,
                                 favorite: row[5] as? Int64)
                result.append(book)
            }

            return result
        }
    }
    
    //根据部类
    public static func byBulei(parentId: Int64? = nil) -> [AnyObject] {
        return read([]) { db in
            var result: [AnyObject] = []

            if parentId == nil {
                for row in try db.prepare("select id, title, type, parentId, favorite from category where parentId = (select id from category where title = '根据部类')") {
                    
                    let category = Categories(id: row[0] as! Int64, title: row[1] as! String, type: row[2] as! String, parentId: row[3] as! Int64, favorite: row[4] as? Int64)
                    
                    result.append(category)
                }
                
            }else{
                
                for row in try db.prepare("select id, title, type, parentId, favorite from category where parentId = ?", [parentId]) {
                    
                    let category = Categories(id: row[0] as! Int64, title: row[1] as! String, type: row[2] as! String, parentId: row[3] as! Int64, favorite: row[4] as? Int64)
                    
                    result.append(category)
                }
                
                for row in try db.prepare("select id, title, location, categoryId, type, favorite from books where categoryId = ?", [parentId]) {
                    
                    let book = Books(id: row[0] as! Int64, title: row[1] as! String, location: row[2] as! String, categoryId: row[3] as! Int64, type: row[4] as! String, favorite: row[5] as? Int64)
                    
                    result.append(book)
                }
            }

            return result
        }
    }
    
    public static func buleiRootId() -> Int64?{
        return read(nil) { db in
            let bulei = try db.pluck(category.table.filter(category.title == "根据部类"))
            return bulei?[category.id]
        }
    }
    
    //根据册别
    public static func byCebie(parentId: Int64? = nil) -> [AnyObject] {
        return read([]) { db in
            var result: [AnyObject] = []

            if parentId == nil {
                for row in try db.prepare("select id, title, type, parentId, favorite from category where parentId = (select id from category where title = '根据册别')") {
                    
                    let category = Categories(id: row[0] as! Int64, title: row[1] as! String, type: row[2] as! String, parentId: row[3] as! Int64, favorite: row[4] as? Int64)
                    
                    result.append(category)
                }
                
            }else{
                
                for row in try db.prepare("select id, title, type, parentId, favorite from category where parentId = ?", [parentId]) {
                    
                    let category = Categories(id: row[0] as! Int64, title: row[1] as! String, type: row[2] as! String, parentId: row[3] as! Int64, favorite: row[4] as? Int64)
                    
                    result.append(category)
                }
                
                for row in try db.prepare("select id, title, location, categoryId, type, favorite from books where categoryId = ?", [parentId]) {
                    
                    let book = Books(id: row[0] as! Int64, title: row[1] as! String, location: row[2] as! String, categoryId: row[3] as! Int64, type: row[4] as! String, favorite: row[5] as? Int64)
                    
                    result.append(book)
                }
            }

            return result
        }
    }
    
    public static func cebieRootId() -> Int64?{
        return read(nil) { db in
            let cebie = try db.pluck(category.table.filter(category.title == "根据册别"))
            return cebie?[category.id]
        }
    }
    
    @discardableResult
    public static func setFavorite(object: AnyObject) -> Bool {
        return write { db in
            if let book = object as? Books {
                try db.run("update books set favorite = 1 where id = ?", [book.id])
                try db.run("delete from favorites where book_id = ?", [book.id])
                try db.run("insert into favorites (book_id) values (?)", [book.id])
            }else if let category = object as? Categories {
                try db.run("update category set favorite = 1 where id = ?", [category.id])
                try db.run("delete from favorites where category_id = ?", [category.id])
                try db.run("insert into favorites (category_id) values (?)", [category.id])
            }
        }
    }

    @discardableResult
    public static func deFavorite(object: AnyObject) -> Bool {
        return write { db in
            if let book = object as? Books {
                try db.run("update books set favorite = 0  where id = ?", [book.id])
                try db.run("delete from favorites where book_id = ?", [book.id])
            }else if let category = object as? Categories {
                try db.run("update category set favorite = 0 where id = ?", [category.id])
                try db.run("delete from favorites where category_id = ?", [category.id])
            }
        }
    }

    public static func getFavorites() -> [AnyObject]{
        return read([]) { db in
            var result: [AnyObject] = []

            let sql = """
            SELECT DISTINCT f.book_id,
                   f.category_id,
                   b.id,
                   b.title,
                   b.location,
                   b.categoryId,
                   b.type,
                   c.id,
                   c.title,
                   c.type,
                   c.parentId
            FROM favorites f
            LEFT JOIN books b on b.id = f.book_id
            LEFT JOIN category c on c.id = f.category_id
            """

            for row in try db.prepare(sql) {
                let bookId = row[0]
                let categoryId = row[1]

                if bookId != nil {
                    let book = Books(id: row[2] as! Int64,
                                     title: row[3] as! String,
                                     location: row[4] as! String,
                                     categoryId: row[5] as! Int64,
                                     type: row[6] as! String,
                                     favorite: 1)
                    result.append(book)
                }else if categoryId != nil {
                    let category = Categories(id: row[7] as! Int64,
                                              title: row[8] as! String,
                                              type: row[9] as! String,
                                              parentId: row[10] as! Int64,
                                              favorite: 1)
                    result.append(category)
                }
            }

            return result
        }
    }

    public static func addExcerpt(bookTitle: String,
                                  bookLocation: String,
                                  chapterIndex: Int,
                                  chapterTitle: String,
                                  selectedText: String,
                                  occurrence: Int) -> Excerpt? {
        let text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        return write(nil) { db in
            let createdAt = Date().timeIntervalSince1970
            try db.run("""
            INSERT INTO excerpts
                (book_title, book_location, chapter_index, chapter_title, selected_text, occurrence, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [bookTitle, bookLocation, Int64(chapterIndex), chapterTitle, text, Int64(occurrence), createdAt])

            return Excerpt(id: db.lastInsertRowid,
                           bookTitle: bookTitle,
                           bookLocation: bookLocation,
                           chapterIndex: chapterIndex,
                           chapterTitle: chapterTitle,
                           selectedText: text,
                           occurrence: occurrence,
                           createdAt: createdAt)
        }
    }

    public static func getExcerpts() -> [Excerpt] {
        return read([]) { db in
            var result: [Excerpt] = []
            for row in try db.prepare("""
            SELECT id, book_title, book_location, chapter_index, chapter_title, selected_text, occurrence, created_at
            FROM excerpts
            ORDER BY created_at DESC, id DESC
            """) {
                result.append(excerpt(from: row))
            }
            return result
        }
    }

    public static func getExcerpts(bookLocation: String, chapterIndex: Int) -> [Excerpt] {
        return read([]) { db in
            var result: [Excerpt] = []
            for row in try db.prepare("""
            SELECT id, book_title, book_location, chapter_index, chapter_title, selected_text, occurrence, created_at
            FROM excerpts
            WHERE book_location = ? AND chapter_index = ?
            ORDER BY created_at ASC, id ASC
            """, [bookLocation, Int64(chapterIndex)]) {
                result.append(excerpt(from: row))
            }
            return result
        }
    }

    public static func getExcerpt(id: Int64) -> Excerpt? {
        return read(nil) { db in
            for row in try db.prepare("""
            SELECT id, book_title, book_location, chapter_index, chapter_title, selected_text, occurrence, created_at
            FROM excerpts
            WHERE id = ?
            LIMIT 1
            """, [id]) {
                return excerpt(from: row)
            }
            return nil
        }
    }
}
