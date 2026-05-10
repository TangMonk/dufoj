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

private struct EpubReadingPosition {
    let chapterIndex: Int
    let scrollY: Double
    let fontScale: CGFloat
}

private enum EpubReaderError: Error {
    case unzipFailed
    case missingContainer
    case missingPackage
    case missingChapters
}

final class EpubReaderViewController: UIViewController, WKNavigationDelegate {
    private static let defaultFontScale: CGFloat = 3.0
    private static let fontScaleStep: CGFloat = 0.5
    private static let minimumFontScale: CGFloat = 0.5
    private static let maximumFontScale: CGFloat = 6.0

    private let epubURL: URL
    private let suggestedTitle: String

    private var webView: WKWebView!
    private let bottomToolbar = UIView()
    private let progressLabel = UILabel()
    private let loadingView = UIActivityIndicatorView(style: .gray)
    private var toolbarButtons: [UIButton] = []

    private var book: EpubBook?
    private var currentChapterIndex = 0
    private var fontScale: CGFloat = EpubReaderViewController.defaultFontScale
    private var pendingScrollY: Double?
    private var readingPositionKey: String {
        return "dufoj.epubReader.position.\(epubURL.path)"
    }

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
        setupWebView()
        setupToolbar()
        setupLoadingView()
        updateChromeColors()
        observeReadingPositionEvents()
        loadEpub()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if #available(iOS 13.0, *),
           previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
            updateChromeColors()
            installReaderStyleUserScript()
            applyReaderStyleToCurrentDocument()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveCurrentPosition()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        installReaderStyleUserScript()
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
    }

    private func setupToolbar() {
        bottomToolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomToolbar)

        let stackView = UIStackView(arrangedSubviews: [
            makeToolbarButton(title: "A-", action: #selector(decreaseFontSize)),
            makeToolbarButton(title: "上一章", action: #selector(showPreviousChapter)),
            progressLabel,
            makeToolbarButton(title: "下一章", action: #selector(showNextChapter)),
            makeToolbarButton(title: "A+", action: #selector(increaseFontSize))
        ])
        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        bottomToolbar.addSubview(stackView)

        progressLabel.textAlignment = .center
        progressLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        progressLabel.adjustsFontSizeToFitWidth = true
        progressLabel.minimumScaleFactor = 0.7

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "目录", style: .plain, target: self, action: #selector(showContents))

        let safeArea = view.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomToolbar.topAnchor),

            bottomToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomToolbar.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            bottomToolbar.heightAnchor.constraint(equalToConstant: 58),

            stackView.topAnchor.constraint(equalTo: bottomToolbar.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: bottomToolbar.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: bottomToolbar.trailingAnchor, constant: -10),
            stackView.bottomAnchor.constraint(equalTo: bottomToolbar.bottomAnchor, constant: -8)
        ])
    }

    private func makeToolbarButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
        button.titleLabel?.lineBreakMode = .byClipping
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        button.layer.cornerRadius = 8
        button.layer.borderWidth = 0.5
        button.addTarget(self, action: action, for: .touchUpInside)
        toolbarButtons.append(button)
        return button
    }

    private func updateChromeColors() {
        view.backgroundColor = readerBackgroundColor
        webView?.backgroundColor = readerBackgroundColor
        bottomToolbar.backgroundColor = isDarkModeEnabled ? UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 0.96) : UIColor(white: 0.98, alpha: 0.96)
        progressLabel.textColor = isDarkModeEnabled ? UIColor(red: 0.55, green: 0.55, blue: 0.57, alpha: 1) : UIColor.lightGray

        for button in toolbarButtons {
            button.backgroundColor = isDarkModeEnabled ? UIColor(red: 0.18, green: 0.18, blue: 0.19, alpha: 0.92) : UIColor(white: 1.0, alpha: 0.92)
            button.layer.borderColor = (isDarkModeEnabled ? UIColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 1) : UIColor(white: 0.88, alpha: 1)).cgColor
            button.setTitleColor(isDarkModeEnabled ? UIColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1) : view.tintColor, for: .normal)
        }
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
                    let position = self.savedReadingPosition(chapterCount: book.chapters.count)
                    self.fontScale = position?.fontScale ?? EpubReaderViewController.defaultFontScale
                    self.currentChapterIndex = position?.chapterIndex ?? 0
                    self.loadCurrentChapter(scrollY: position?.scrollY)
                case .failure:
                    ShowMessage(controller: self, msg: "无法打开这本 EPUB", title: "错误")
                }
            }
        }
    }

    private func loadCurrentChapter(scrollY: Double? = 0) {
        guard let book = book, book.chapters.indices.contains(currentChapterIndex) else {
            return
        }

        let chapter = book.chapters[currentChapterIndex]
        progressLabel.text = "\(currentChapterIndex + 1)/\(book.chapters.count)"
        pendingScrollY = scrollY
        installReaderStyleUserScript()
        webView.loadFileURL(chapter.url, allowingReadAccessTo: book.rootURL)
    }

    private var isDarkModeEnabled: Bool {
        if #available(iOS 13.0, *) {
            return traitCollection.userInterfaceStyle == .dark
        }
        return false
    }

    private var readerBackgroundHex: String {
        return isDarkModeEnabled ? "#222224" : "#F6F0E2"
    }

    private var readerTextHex: String {
        return isDarkModeEnabled ? "#D1D1D1" : "#1f2328"
    }

    private var readerBackgroundColor: UIColor {
        return isDarkModeEnabled ? UIColor(red: 34.0 / 255.0, green: 34.0 / 255.0, blue: 36.0 / 255.0, alpha: 1) : UIColor(red: 246.0 / 255.0, green: 240.0 / 255.0, blue: 226.0 / 255.0, alpha: 1)
    }

    private func readerCSS() -> String {
        let percent = Int(fontScale * 100)
        let contentTextColorRule = isDarkModeEnabled ? "color: \(readerTextHex) !important;" : ""
        return """
        html {
          -webkit-text-size-adjust: \(percent)% !important;
          margin: 0 !important;
          padding: 0 !important;
          background: \(readerBackgroundHex) !important;
          color-scheme: \(isDarkModeEnabled ? "dark" : "light") !important;
        }
        body {
          box-sizing: border-box !important;
          max-width: none !important;
          margin: 0 auto !important;
          padding: 14px 64px 30px !important;
          color: \(readerTextHex) !important;
          background: \(readerBackgroundHex) !important;
          line-height: 1.9 !important;
          font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif !important;
        }
        p, div, li, section, article, span {
          line-height: 1.9 !important;
          margin-left: 0 !important;
          margin-right: 0 !important;
          \(contentTextColorRule)
        }
        div.lg {
          visibility: hidden !important;
          white-space: pre-line !important;
        }
        div.lg.dufoj-lg-ready {
          visibility: visible !important;
        }
        img, svg { max-width: 100% !important; height: auto !important; }
        a { color: #0a84ff !important; }
        """
    }

    private func readerStyleScript() -> String {
        let css = readerCSS()
        let cssData = try? JSONSerialization.data(withJSONObject: [css], options: [])
        let cssLiteral = cssData
            .flatMap { String(data: $0, encoding: .utf8) }?
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""

        return """
        (function() {
          var css = \(cssLiteral);
          var style = document.getElementById('dufoj-reader-style');
          if (!style) {
            style = document.createElement('style');
            style.id = 'dufoj-reader-style';
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent = css;
        })();
        """
    }

    private func readerPoemScript() -> String {
        return """
        (function() {
          function normalizePoemText(text) {
            return (text || '')
              .replace(/，[\\s\\u3000]*/g, '，\\n')
              .replace(/[\\s\\u3000]+/g, '\\n')
              .split('\\n')
              .map(function(line) {
                return line
                  .replace(/^[\\s\\u3000]+/g, '')
                  .replace(/[\\s\\u3000]+$/g, '');
              })
              .filter(function(line) {
                return line.length > 0;
              })
              .join('\\n');
          }

          function formatPoem(block) {
            if (block.getAttribute('data-dufoj-lg-formatted') !== '1') {
              block.textContent = normalizePoemText(block.textContent);
              block.setAttribute('data-dufoj-lg-formatted', '1');
            }
            block.classList.add('dufoj-lg-ready');
          }

          function formatPoems(root) {
            Array.prototype.forEach.call((root || document).querySelectorAll('div.lg'), formatPoem);
          }

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function() {
              formatPoems(document);
            });
          } else {
            formatPoems(document);
          }
        })();
        """
    }

    private func installReaderStyleUserScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: readerStyleScript(),
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: readerPoemScript(),
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
    }

    private func applyReaderStyleToCurrentDocument() {
        webView.evaluateJavaScript(readerStyleScript(), completionHandler: nil)
        webView.evaluateJavaScript(readerPoemScript(), completionHandler: nil)
    }

    @objc private func showPreviousChapter() {
        guard currentChapterIndex > 0 else { return }
        saveCurrentPosition()
        currentChapterIndex -= 1
        loadCurrentChapter(scrollY: 0)
    }

    @objc private func showNextChapter() {
        guard let book = book, currentChapterIndex < book.chapters.count - 1 else { return }
        saveCurrentPosition()
        currentChapterIndex += 1
        loadCurrentChapter(scrollY: 0)
    }

    @objc private func decreaseFontSize() {
        fontScale = max(EpubReaderViewController.minimumFontScale,
                        fontScale - EpubReaderViewController.fontScaleStep)
        installReaderStyleUserScript()
        applyReaderStyleToCurrentDocument()
        saveCurrentPosition()
    }

    @objc private func increaseFontSize() {
        fontScale = min(EpubReaderViewController.maximumFontScale,
                        fontScale + EpubReaderViewController.fontScaleStep)
        installReaderStyleUserScript()
        applyReaderStyleToCurrentDocument()
        saveCurrentPosition()
    }

    @objc private func showContents() {
        guard let book = book else { return }

        let contents = EpubContentsViewController(chapters: book.chapters, currentIndex: currentChapterIndex) { [weak self] index in
            self?.saveCurrentPosition()
            self?.currentChapterIndex = index
            self?.loadCurrentChapter(scrollY: 0)
        }
        let navigationController = UINavigationController(rootViewController: contents)
        present(navigationController, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        restorePendingScrollPosition()
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

        saveCurrentPosition()
        currentChapterIndex = index
        loadCurrentChapter(scrollY: 0)
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

    private func observeReadingPositionEvents() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(saveCurrentPositionForNotification),
                                               name: UIApplication.willResignActiveNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(saveCurrentPositionForNotification),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
    }

    @objc private func saveCurrentPositionForNotification() {
        saveCurrentPosition()
    }

    private func savedReadingPosition(chapterCount: Int) -> EpubReadingPosition? {
        guard let dictionary = UserDefaults.standard.dictionary(forKey: readingPositionKey),
              let chapterIndex = dictionary["chapterIndex"] as? Int,
              chapterIndex >= 0,
              chapterIndex < chapterCount else {
            return nil
        }

        return EpubReadingPosition(chapterIndex: chapterIndex,
                                   scrollY: doubleValue(from: dictionary["scrollY"]),
                                   fontScale: CGFloat(clampedFontScale(doubleValue(from: dictionary["fontScale"],
                                                                                  defaultValue: Double(EpubReaderViewController.defaultFontScale)))))
    }

    private func saveCurrentPosition() {
        guard book != nil, webView != nil else {
            return
        }

        let chapterIndex = currentChapterIndex
        let script = "Math.max(window.pageYOffset || document.documentElement.scrollTop || document.body.scrollTop || 0, 0);"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self = self else { return }
            self.persistReadingPosition(chapterIndex: chapterIndex, scrollY: self.doubleValue(from: result))
        }
    }

    private func persistReadingPosition(chapterIndex: Int? = nil, scrollY: Double) {
        let index = chapterIndex ?? currentChapterIndex
        guard let book = book, book.chapters.indices.contains(index) else {
            return
        }

        UserDefaults.standard.set([
            "chapterIndex": index,
            "scrollY": max(0, scrollY),
            "fontScale": Double(fontScale)
        ], forKey: readingPositionKey)
    }

    private func restorePendingScrollPosition() {
        guard let scrollY = pendingScrollY else {
            persistReadingPosition(scrollY: 0)
            return
        }

        pendingScrollY = nil
        let roundedScrollY = max(0, scrollY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            self.webView.evaluateJavaScript("window.scrollTo(0, \(roundedScrollY));", completionHandler: nil)
            self.persistReadingPosition(scrollY: roundedScrollY)
        }
    }

    private func doubleValue(from value: Any?, defaultValue: Double = 0) -> Double {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let value = value as? Double {
            return value
        }
        return defaultValue
    }

    private func clampedFontScale(_ value: Double) -> Double {
        return min(Double(EpubReaderViewController.maximumFontScale),
                   max(Double(EpubReaderViewController.minimumFontScale), value))
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
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if #available(iOS 13.0, *),
           previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
            updateColors()
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return chapters.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapterCell", for: indexPath)
        cell.textLabel?.text = chapters[indexPath.row].title
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.textColor = isDarkModeEnabled ? UIColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1) : UIColor(red: 0.12, green: 0.14, blue: 0.16, alpha: 1)
        cell.backgroundColor = isDarkModeEnabled ? UIColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1) : UIColor(red: 0.98, green: 0.96, blue: 0.90, alpha: 1)
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

    private func updateColors() {
        tableView.backgroundColor = isDarkModeEnabled ? UIColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1) : UIColor(red: 0.98, green: 0.96, blue: 0.90, alpha: 1)
        navigationController?.navigationBar.barStyle = isDarkModeEnabled ? .black : .default
    }

    private var isDarkModeEnabled: Bool {
        if #available(iOS 13.0, *) {
            return traitCollection.userInterfaceStyle == .dark
        }
        return false
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
