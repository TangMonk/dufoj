//
//  EpubReaderViewController.swift
//  fojingdaquan
//
//  Created by Codex on 2026/5/9.
//  Copyright © 2026 tangmonk. All rights reserved.
//

import Foundation
import SSZipArchive
import UIKit
import WebKit

private struct EpubChapter {
    let title: String
    let href: String
    let url: URL
}

private struct EpubBook {
    let title: String
    let rootURL: URL
    let chapters: [EpubChapter]
}

private enum EpubReaderError: Error {
    case unzipFailed
    case missingContainer
    case missingPackage
    case missingChapters
}

final class EpubReaderViewController: UIViewController, WKNavigationDelegate {
    private let epubURL: URL
    private let suggestedTitle: String

    private var webView: WKWebView!
    private let toolbar = UIToolbar()
    private let progressItem = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
    private let loadingView = UIActivityIndicatorView(style: .gray)

    private var book: EpubBook?
    private var currentChapterIndex = 0
    private var fontScale: CGFloat = 1.0

    init(epubURL: URL, title: String) {
        self.epubURL = epubURL
        self.suggestedTitle = title
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = suggestedTitle
        view.backgroundColor = UIColor.white
        setupWebView()
        setupToolbar()
        setupLoadingView()
        loadEpub()
    }

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.backgroundColor = UIColor.white
        webView.isOpaque = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
    }

    private func setupToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        let smaller = UIBarButtonItem(title: "A-", style: .plain, target: self, action: #selector(decreaseFontSize))
        let previous = UIBarButtonItem(title: "上一章", style: .plain, target: self, action: #selector(showPreviousChapter))
        let next = UIBarButtonItem(title: "下一章", style: .plain, target: self, action: #selector(showNextChapter))
        let larger = UIBarButtonItem(title: "A+", style: .plain, target: self, action: #selector(increaseFontSize))
        let fixed = UIBarButtonItem(barButtonSystemItem: .fixedSpace, target: nil, action: nil)
        fixed.width = 12
        let flexible = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)

        progressItem.isEnabled = false
        toolbar.items = [smaller, fixed, previous, flexible, progressItem, flexible, next, fixed, larger]

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "目录", style: .plain, target: self, action: #selector(showContents))

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: bottomLayoutGuide.topAnchor)
        ])
    }

    private func setupLoadingView() {
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.hidesWhenStopped = true
        view.addSubview(loadingView)

        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func loadEpub() {
        loadingView.startAnimating()
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<EpubBook, Error>
            do {
                result = .success(try EpubParser.load(epubURL: self.epubURL, suggestedTitle: self.suggestedTitle))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.loadingView.stopAnimating()
                switch result {
                case .success(let book):
                    self.book = book
                    self.title = book.title
                    self.currentChapterIndex = 0
                    self.loadCurrentChapter()
                case .failure:
                    ShowMessage(controller: self, msg: "无法打开这本 EPUB", title: "错误")
                }
            }
        }
    }

    private func loadCurrentChapter() {
        guard let book = book, book.chapters.indices.contains(currentChapterIndex) else {
            return
        }

        let chapter = book.chapters[currentChapterIndex]
        progressItem.title = "\(currentChapterIndex + 1)/\(book.chapters.count)"
        webView.loadFileURL(chapter.url, allowingReadAccessTo: book.rootURL)
    }

    private func applyReaderStyle() {
        let percent = Int(fontScale * 100)
        let css = """
        html { -webkit-text-size-adjust: \(percent)% !important; }
        body {
          box-sizing: border-box !important;
          max-width: 760px !important;
          margin: 0 auto !important;
          padding: 18px 18px 34px !important;
          color: #1f2328 !important;
          background: #fffdf8 !important;
          line-height: 1.9 !important;
          font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif !important;
        }
        p, div, li { line-height: 1.9 !important; }
        img, svg { max-width: 100% !important; height: auto !important; }
        a { color: #0a84ff !important; }
        """
        let escapedCSS = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        let script = """
        (function() {
          var style = document.getElementById('dufoj-reader-style');
          if (!style) {
            style = document.createElement('style');
            style.id = 'dufoj-reader-style';
            document.head.appendChild(style);
          }
          style.innerHTML = '\(escapedCSS)';
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    @objc private func showPreviousChapter() {
        guard currentChapterIndex > 0 else { return }
        currentChapterIndex -= 1
        loadCurrentChapter()
    }

    @objc private func showNextChapter() {
        guard let book = book, currentChapterIndex < book.chapters.count - 1 else { return }
        currentChapterIndex += 1
        loadCurrentChapter()
    }

    @objc private func decreaseFontSize() {
        fontScale = max(0.75, fontScale - 0.1)
        applyReaderStyle()
    }

    @objc private func increaseFontSize() {
        fontScale = min(1.8, fontScale + 0.1)
        applyReaderStyle()
    }

    @objc private func showContents() {
        guard let book = book else { return }

        let contents = EpubContentsViewController(chapters: book.chapters, currentIndex: currentChapterIndex) { [weak self] index in
            self?.currentChapterIndex = index
            self?.loadCurrentChapter()
        }
        let navigationController = UINavigationController(rootViewController: contents)
        present(navigationController, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyReaderStyle()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              let index = chapterIndex(for: url) else {
            decisionHandler(.allow)
            return
        }

        currentChapterIndex = index
        loadCurrentChapter()
        decisionHandler(.cancel)
    }

    private func chapterIndex(for url: URL) -> Int? {
        guard let book = book else { return nil }
        let normalizedURL = normalizedFileURL(url)
        return book.chapters.firstIndex { normalizedFileURL($0.url) == normalizedURL }
    }

    private func normalizedFileURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return (components?.url ?? url).standardizedFileURL
    }
}

private final class EpubContentsViewController: UITableViewController {
    private let chapters: [EpubChapter]
    private let currentIndex: Int
    private let onSelect: (Int) -> Void

    init(chapters: [EpubChapter], currentIndex: Int, onSelect: @escaping (Int) -> Void) {
        self.chapters = chapters
        self.currentIndex = currentIndex
        self.onSelect = onSelect
        super.init(style: .plain)
        title = "目录"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "chapterCell")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return chapters.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapterCell", for: indexPath)
        cell.textLabel?.text = chapters[indexPath.row].title
        cell.textLabel?.numberOfLines = 2
        cell.accessoryType = indexPath.row == currentIndex ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        onSelect(indexPath.row)
        dismiss(animated: true, completion: nil)
    }

    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }
}

private final class EpubParser {
    static func load(epubURL: URL, suggestedTitle: String) throws -> EpubBook {
        let fileManager = FileManager.default
        let destinationURL = try extractionURL(for: epubURL)
        let containerURL = destinationURL.appendingPathComponent("META-INF/container.xml")

        if !fileManager.fileExists(atPath: containerURL.path) {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true, attributes: nil)
            var unzipError: NSError?
            let success = SSZipArchive.unzipFile(atPath: epubURL.path,
                                                 toDestination: destinationURL.path,
                                                 preserveAttributes: false,
                                                 overwrite: true,
                                                 password: nil,
                                                 error: &unzipError,
                                                 delegate: nil)
            if !success {
                throw unzipError ?? EpubReaderError.unzipFailed
            }
        }

        let packagePath = try parseContainer(containerURL)
        let packageURL = destinationURL.appendingPathComponent(packagePath)
        let package = try parsePackage(packageURL, suggestedTitle: suggestedTitle)
        let baseURL = packageURL.deletingLastPathComponent()
        let tocTitles = parseTocTitles(package: package, baseURL: baseURL)

        let chapters = package.spine.compactMap { idref -> EpubChapter? in
            guard let item = package.manifest[idref],
                  item.mediaType.contains("xhtml") || item.mediaType.contains("html") else {
                return nil
            }
            let title = tocTitles[normalizedHref(item.href)] ?? readableTitle(from: item.href)
            guard let url = URL(string: item.href, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }
            return EpubChapter(title: title, href: item.href, url: url)
        }

        if chapters.isEmpty {
            throw EpubReaderError.missingChapters
        }

        return EpubBook(title: package.title, rootURL: destinationURL, chapters: chapters)
    }

    private static func extractionURL(for epubURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let cachesURL = try fileManager.url(for: .cachesDirectory,
                                            in: .userDomainMask,
                                            appropriateFor: nil,
                                            create: true)
        let attributes = try fileManager.attributesOfItem(atPath: epubURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = Int((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let rawName = "\(epubURL.deletingPathExtension().lastPathComponent)-\(size)-\(modified)"
        let safeName = rawName.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return cachesURL.appendingPathComponent("dufoj-epub-reader").appendingPathComponent(safeName)
    }

    private static func parseContainer(_ containerURL: URL) throws -> String {
        guard let parser = XMLParser(contentsOf: containerURL) else {
            throw EpubReaderError.missingContainer
        }
        let delegate = ContainerXMLDelegate()
        parser.delegate = delegate
        if parser.parse(), let packagePath = delegate.packagePath {
            return packagePath
        }
        throw EpubReaderError.missingContainer
    }

    private static func parsePackage(_ packageURL: URL, suggestedTitle: String) throws -> PackageData {
        guard let parser = XMLParser(contentsOf: packageURL) else {
            throw EpubReaderError.missingPackage
        }
        let delegate = PackageXMLDelegate(suggestedTitle: suggestedTitle)
        parser.delegate = delegate
        if parser.parse() {
            return delegate.package
        }
        throw EpubReaderError.missingPackage
    }

    private static func parseTocTitles(package: PackageData, baseURL: URL) -> [String: String] {
        guard let tocID = package.tocID,
              let tocItem = package.manifest[tocID],
              let tocURL = URL(string: tocItem.href, relativeTo: baseURL)?.absoluteURL,
              let parser = XMLParser(contentsOf: tocURL) else {
            return [:]
        }

        let delegate = TocXMLDelegate()
        parser.delegate = delegate
        if parser.parse() {
            return delegate.titlesByHref
        }
        return [:]
    }

    private static func readableTitle(from href: String) -> String {
        let filename = (href as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension
    }

    private static func normalizedHref(_ href: String) -> String {
        let path = href.components(separatedBy: "#").first ?? href
        return path.removingPercentEncoding ?? path
    }
}

private struct ManifestItem {
    let href: String
    let mediaType: String
}

private struct PackageData {
    let title: String
    let manifest: [String: ManifestItem]
    let spine: [String]
    let tocID: String?
}

private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var packagePath: String?

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        if simpleName(elementName) == "rootfile" {
            packagePath = attributeDict["full-path"]
        }
    }
}

private final class PackageXMLDelegate: NSObject, XMLParserDelegate {
    private let suggestedTitle: String
    private var inMetadata = false
    private var readingTitle = false
    private var titleBuffer = ""
    private var title: String?
    private var manifest: [String: ManifestItem] = [:]
    private var spine: [String] = []
    private var tocID: String?

    init(suggestedTitle: String) {
        self.suggestedTitle = suggestedTitle
    }

    var package: PackageData {
        let finalTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PackageData(title: finalTitle?.isEmpty == false ? finalTitle! : suggestedTitle,
                           manifest: manifest,
                           spine: spine,
                           tocID: tocID)
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        let name = simpleName(elementName)

        if name == "metadata" {
            inMetadata = true
        } else if inMetadata && name == "title" {
            readingTitle = true
            titleBuffer = ""
        } else if name == "item",
                  let id = attributeDict["id"],
                  let href = attributeDict["href"] {
            manifest[id] = ManifestItem(href: href, mediaType: attributeDict["media-type"] ?? "")
        } else if name == "spine" {
            tocID = attributeDict["toc"]
        } else if name == "itemref",
                  let idref = attributeDict["idref"] {
            spine.append(idref)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingTitle {
            titleBuffer.append(string)
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = simpleName(elementName)

        if name == "metadata" {
            inMetadata = false
        } else if readingTitle && name == "title" {
            readingTitle = false
            title = titleBuffer
        }
    }
}

private final class TocXMLDelegate: NSObject, XMLParserDelegate {
    private struct NavPoint {
        var title = ""
        var href = ""
        var readingTitle = false
    }

    private var navStack: [NavPoint] = []
    var titlesByHref: [String: String] = [:]

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        let name = simpleName(elementName)

        if name == "navpoint" {
            navStack.append(NavPoint())
        } else if name == "text", !navStack.isEmpty {
            navStack[navStack.count - 1].readingTitle = true
        } else if name == "content",
                  !navStack.isEmpty,
                  let src = attributeDict["src"] {
            navStack[navStack.count - 1].href = normalizedHref(src)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !navStack.isEmpty, navStack[navStack.count - 1].readingTitle else {
            return
        }
        navStack[navStack.count - 1].title.append(string)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = simpleName(elementName)

        if name == "text", !navStack.isEmpty {
            navStack[navStack.count - 1].readingTitle = false
        } else if name == "navpoint", let navPoint = navStack.popLast() {
            let title = navPoint.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !navPoint.href.isEmpty && !title.isEmpty {
                titlesByHref[navPoint.href] = title
            }
        }
    }

    private func normalizedHref(_ href: String) -> String {
        let path = href.components(separatedBy: "#").first ?? href
        return path.removingPercentEncoding ?? path
    }
}

private func simpleName(_ elementName: String) -> String {
    return (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
}

extension UIViewController {
    func openEpubReader(book: Books) {
        guard let bookPath = Bundle.main.path(forResource: "cbeta_epub_2019q4.bundle/\(book.location)", ofType: "epub") else {
            ShowMessage(controller: self, msg: "找不到 EPUB 文件", title: "错误")
            return
        }

        let reader = EpubReaderViewController(epubURL: URL(fileURLWithPath: bookPath), title: book.title)
        if let navigationController = navigationController {
            navigationController.pushViewController(reader, animated: true)
        } else {
            present(UINavigationController(rootViewController: reader), animated: true, completion: nil)
        }
    }
}
