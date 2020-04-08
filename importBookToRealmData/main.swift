//
//  main.swift
//  importBookToRealmData
//
//  Created by tangmonk on 2020/3/16.
//  Copyright © 2020 tangmonk. All rights reserved.
//

import Foundation
import SwiftKueryPostgreSQL
import SwiftKuery
import SQLite

var username = "tangmonk"
var password = "123"
var host = "localhost"
var port = 5432
var databaseName = "dufoj"

let connection = PostgreSQLConnection(host: "localhost", port: 5432, options: [.databaseName("dufoj"), .userName(username), .password("123")])

let db = try Connection("./dufoj.sqlite3")
//
//
//let sqliteBooks = Table("books")
//let id = Expression<Int64>("id")
//let title = Expression<String?>("title")
//let location = Expression<String>("location")
//let categoryId = Expression<Int64>("categoryId")
//let type = Expression<String>("type")
//
//try db.run(sqliteBooks.create { t in
//    t.column(id, primaryKey: true)
//    t.column(title)
//    t.column(location)
//    t.column(categoryId)
//    t.column(type)
//})
//
//
//class Books : SwiftKuery.Table {
//    let tableName = "books"
//    let id = Column("id")
//    let title = Column("title")
//    let location = Column("location")
//    let categoryId = Column("category_id")
//    let type = Column("type")
//}
////
//let books = Books()
////var realBooks: [Book] = []
////var count = 0
//connection.connect() { result in
//    guard result.success else {
//        fatalError("connecting failed")
//    }
//
//    let query = Select(books.id, books.title,  books.location, books.categoryId, books.type, from: books)
//
//    connection.execute(query: query) { result in
//        guard let resultSet = result.asResultSet else {
//            guard let error = result.asError else {
//                fatalError("Error executing query: Unknown Error")
//            }
//            fatalError("Error executing query: \(error)")
//        }
//
//
//        resultSet.forEach() { row, error in
//            guard let row = row else {
//                // A null row means we have run out of results unless we encountered an error
//                if let error = error {
//                    fatalError("Error fetching row: \(error)")
//                }
//                // No error so all rows are processed, make final callback passing result.
//                return
//            }
//
//            var bookIdPg = 0
//            var categoryIdPg = 0
//            var locationPg = ""
//            var titlePg = ""
//            var typePg = ""
//
//            for (index, value) in row.enumerated() {
//                if let value = value {
//                    var valueString = String(describing: value)
//                    if index == 0 {
//                        bookIdPg = Int(valueString) ?? 0
//                        if bookIdPg == 0 {
//                            fatalError("unexpect 0 id")
//                        }
//                    }
//                    if index == 1{
//                        valueString = valueString.gb
//
//                        let regex = try! NSRegularExpression(pattern: "^[A-Z]\\d+\\s", options: NSRegularExpression.Options.caseInsensitive)
//                        let range = NSMakeRange(0, valueString.count)
//                        let modString = regex.stringByReplacingMatches(in: valueString, options: [], range: range, withTemplate: "")
//                        valueString = modString
//                        titlePg = valueString
//                    }
//                    if index == 2 {
//                        locationPg = valueString
//                    }
//                    if index == 3 {
//                        categoryIdPg = Int(valueString) ?? 0
//
//                        if categoryIdPg == 0 {
//                            fatalError("unexpect 0 id")
//                        }
//                    }
//                    if index == 4 {
//                        typePg = valueString
//                    }
//
//                }
//            }
//            let insert = sqliteBooks.insert(id <- Int64(bookIdPg), title <- titlePg, location <- locationPg, categoryId <- Int64(categoryIdPg), type <- typePg)
//
//            let rowid = try! db.run(insert)
//            print(rowid)
//
//        }
//    }
//}

//let sqliteCategory = Table("category")
//let categoryId2 = Expression<Int64>("id")
//let categoryTitle = Expression<String?>("title")
//let categoryType = Expression<String>("type")
//let categoryParentId = Expression<Int64>("parentId")
//
//try db.run(sqliteCategory.create { t in
//    t.column(categoryId2, primaryKey: true)
//    t.column(categoryTitle)
//    t.column(categoryType)
//    t.column(categoryParentId)
//    
//})
//
//
//class Categories : SwiftKuery.Table {
//    let tableName = "categories"
//    let id = Column("id")
//    let parentId = Column("parent_id")
//    let type = Column("type")
//    let title = Column("title")
//}
//
//
//let categories = Categories()
//
//connection.connect() { result in
//    guard result.success else {
//        fatalError("connecting failed")
//    }
//
//    let query = Select(categories.id, categories.title,  categories.parentId, categories.type, from: categories)
//
//    connection.execute(query: query) { result in
//        guard let resultSet = result.asResultSet else {
//            guard let error = result.asError else {
//                fatalError("Error executing query: Unknown Error")
//            }
//            fatalError("Error executing query: \(error)")
//        }
//
//
//        resultSet.forEach() { row, error in
//            guard let row = row else {
//                // A null row means we have run out of results unless we encountered an error
//                if let error = error {
//                    fatalError("Error fetching row: \(error)")
//                }
//                // No error so all rows are processed, make final callback passing result.
//                return
//            }
//
//            var id = 0
//            var title = ""
//            var type = ""
//            var parentId = 0
//            for (index, value) in row.enumerated() {
//                if let value = value {
//                    var valueString = String(describing: value)
//                    if index == 0 {
//                        id = Int(valueString) ?? 0
//                        if id == 0 {
//                            fatalError("unexpect 0 id")
//                        }
//                    }
//                    if index == 1{
//                        valueString = valueString.gb
//
//                        title = valueString
//                    }
//                    if index == 2 {
//                        parentId = Int(valueString) ?? 100000
//
//                        if parentId == 100000 {
//                            fatalError("unexpect 100000 id")
//                        }
//                    }
//                    if index == 3 {
//                        type = valueString
//                    }
//
//
//                }
//            }
//
//            let insert = sqliteCategory.insert(categoryId2 <- Int64(id), categoryTitle <- title, categoryParentId <- Int64(parentId), categoryType <- type)
//
//            let rowid = try! db.run(insert)
//            print(rowid)
//
//        }
//    }
//
//}

print("done")
RunLoop.main.run()
