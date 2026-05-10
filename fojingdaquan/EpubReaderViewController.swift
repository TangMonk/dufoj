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

private struct EpubTocItem {
    let title: String
    let url: URL?
    let chapterIndex: Int?
    let children: [EpubTocItem]
}

private struct EpubBook {
    let title: String
    let rootURL: URL
    let chapters: [EpubChapter]
    let tocItems: [EpubTocItem]
}

private struct EpubReadingPosition {
    let chapterIndex: Int
    let scrollY: Double
    let fontScale: CGFloat
}

private struct DeepSeekChatMessage: Codable {
    let role: String
    let content: String
}

private struct DeepSeekChatRequest: Codable {
    let model: String
    let messages: [DeepSeekChatMessage]
    let stream: Bool
}

private struct DeepSeekChatResponse: Codable {
    struct Choice: Codable {
        let message: DeepSeekChatMessage
    }

    struct APIError: Codable {
        let message: String
    }

    let choices: [Choice]?
    let error: APIError?
}

private struct DeepSeekChatStreamResponse: Codable {
    struct Choice: Codable {
        struct Delta: Codable {
            let content: String?
        }

        let delta: Delta?
    }

    let choices: [Choice]?
    let error: DeepSeekChatResponse.APIError?
}

private struct EpubAISettings {
    private static let apiKeyKey = "dufoj.epubReader.ai.deepSeekAPIKey"
    private static let streamingKey = "dufoj.epubReader.ai.streaming"
    private static let fontScaleKey = "dufoj.epubReader.ai.fontScale"
    private static let inlineButtonsKey = "dufoj.epubReader.ai.inlineButtons"

    static let defaultAPIKey = "sk-efa5fbb8c7574ac8a56384c7452a9a24"
    static let minimumFontScale: CGFloat = 0.8
    static let maximumFontScale: CGFloat = 1.8
    static let fontScaleStep: CGFloat = 0.1

    var apiKey: String
    var usesStreaming: Bool
    var fontScale: CGFloat
    var showsInlineButtons: Bool

    var effectiveAPIKey: String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedKey.isEmpty ? EpubAISettings.defaultAPIKey : trimmedKey
    }

    static func load() -> EpubAISettings {
        let defaults = UserDefaults.standard
        let storedScale = defaults.object(forKey: fontScaleKey) as? Double
        let storedStreaming = defaults.object(forKey: streamingKey) as? Bool
        let storedInlineButtons = defaults.object(forKey: inlineButtonsKey) as? Bool

        return EpubAISettings(apiKey: defaults.string(forKey: apiKeyKey) ?? "",
                              usesStreaming: storedStreaming ?? true,
                              fontScale: clampedFontScale(CGFloat(storedScale ?? 1.0)),
                              showsInlineButtons: storedInlineButtons ?? false)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: EpubAISettings.apiKeyKey)
        defaults.set(usesStreaming, forKey: EpubAISettings.streamingKey)
        defaults.set(Double(EpubAISettings.clampedFontScale(fontScale)), forKey: EpubAISettings.fontScaleKey)
        defaults.set(showsInlineButtons, forKey: EpubAISettings.inlineButtonsKey)
    }

    static func clampedFontScale(_ value: CGFloat) -> CGFloat {
        return min(maximumFontScale, max(minimumFontScale, value))
    }
}

private enum EpubReaderError: Error {
    case unzipFailed
    case missingContainer
    case missingPackage
    case missingChapters
}

private enum DeepSeekExplanationError: LocalizedError {
    case invalidURL
    case invalidResponse
    case requestFailed(String)
    case emptyResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "AI 服务地址无效"
        case .invalidResponse:
            return "AI 服务返回异常"
        case .requestFailed(let message):
            return message
        case .emptyResponse:
            return "AI 服务没有返回解释内容"
        case .cancelled:
            return "已取消"
        }
    }
}

private final class DeepSeekStreamingClient: NSObject, URLSessionDataDelegate {
    private let request: URLRequest
    private let onText: (String) -> Void
    private let onComplete: (Result<Void, Error>) -> Void
    private var session: URLSession?
    private var responseData = Data()
    private var lineBuffer = ""
    private var statusCode = 0
    private var hasContent = false
    private var isCompleted = false

    private(set) var task: URLSessionDataTask?

    init(request: URLRequest,
         onText: @escaping (String) -> Void,
         onComplete: @escaping (Result<Void, Error>) -> Void) {
        self.request = request
        self.onText = onText
        self.onComplete = onComplete
    }

    func start() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
        guard (200...299).contains(statusCode),
              let string = String(data: data, encoding: .utf8) else {
            return
        }

        lineBuffer += string
        processBufferedLines()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            processStreamLine(lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
            lineBuffer = ""
        }

        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled {
                complete(.failure(DeepSeekExplanationError.cancelled))
            } else {
                complete(.failure(DeepSeekExplanationError.requestFailed(error.localizedDescription)))
            }
            return
        }

        if !(200...299).contains(statusCode) {
            let decodedResponse = try? JSONDecoder().decode(DeepSeekChatResponse.self, from: responseData)
            let message = decodedResponse?.error?.message ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            complete(.failure(DeepSeekExplanationError.requestFailed(message)))
            return
        }

        complete(hasContent ? .success(()) : .failure(DeepSeekExplanationError.emptyResponse))
    }

    private func processBufferedLines() {
        while let range = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer.removeSubrange(lineBuffer.startIndex...range.lowerBound)
            processStreamLine(line)
        }
    }

    private func processStreamLine(_ line: String) {
        guard !line.isEmpty, line.hasPrefix("data:") else {
            return
        }

        let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload != "[DONE]" else {
            return
        }

        guard let data = payload.data(using: .utf8),
              let response = try? JSONDecoder().decode(DeepSeekChatStreamResponse.self, from: data) else {
            return
        }

        if let message = response.error?.message {
            complete(.failure(DeepSeekExplanationError.requestFailed(message)))
            cancel()
            return
        }

        guard let content = response.choices?.compactMap({ $0.delta?.content }).joined(),
              !content.isEmpty else {
            return
        }

        hasContent = true
        DispatchQueue.main.async {
            self.onText(content)
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        guard !isCompleted else {
            return
        }

        isCompleted = true
        session?.finishTasksAndInvalidate()
        DispatchQueue.main.async {
            self.onComplete(result)
        }
    }
}

private final class EpubAISettingsViewController: UIViewController, UITextFieldDelegate {
    private var settings: EpubAISettings
    private let onSave: (EpubAISettings) -> Void
    private let apiKeyField = UITextField()
    private let modeControl = UISegmentedControl(items: ["流式", "普通"])
    private let fontSizeLabel = UILabel()
    private let inlineButtonSwitch = UISwitch()

    init(settings: EpubAISettings, onSave: @escaping (EpubAISettings) -> Void) {
        self.settings = settings
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        updateFontSizeLabel()
    }

    private func setupViews() {
        view.backgroundColor = UIColor(white: 0, alpha: 0.45)

        let cardView = UIView()
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = UIColor(white: 0.98, alpha: 1)
        cardView.layer.cornerRadius = 10
        cardView.layer.masksToBounds = true
        view.addSubview(cardView)

        let titleLabel = UILabel()
        titleLabel.text = "AI设置"
        titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textAlignment = .center

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("关闭", for: .normal)
        closeButton.addTarget(self, action: #selector(closeSettings), for: .touchUpInside)

        let headerView = UIView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(headerView)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)
        headerView.addSubview(closeButton)

        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(stackView)

        apiKeyField.borderStyle = .roundedRect
        apiKeyField.placeholder = "DeepSeek API Key"
        apiKeyField.text = settings.apiKey
        apiKeyField.clearButtonMode = .whileEditing
        apiKeyField.autocapitalizationType = .none
        apiKeyField.autocorrectionType = .no
        apiKeyField.isSecureTextEntry = true
        apiKeyField.delegate = self

        modeControl.selectedSegmentIndex = settings.usesStreaming ? 0 : 1

        let fontRow = UIStackView()
        fontRow.axis = .horizontal
        fontRow.alignment = .center
        fontRow.spacing = 10

        let decreaseButton = UIButton(type: .system)
        decreaseButton.setTitle("A-", for: .normal)
        decreaseButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        decreaseButton.addTarget(self, action: #selector(decreaseFontSize), for: .touchUpInside)

        let increaseButton = UIButton(type: .system)
        increaseButton.setTitle("A+", for: .normal)
        increaseButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        increaseButton.addTarget(self, action: #selector(increaseFontSize), for: .touchUpInside)

        fontSizeLabel.textAlignment = .center
        fontSizeLabel.font = UIFont.systemFont(ofSize: 16)
        fontSizeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fontRow.addArrangedSubview(decreaseButton)
        fontRow.addArrangedSubview(fontSizeLabel)
        fontRow.addArrangedSubview(increaseButton)

        inlineButtonSwitch.isOn = settings.showsInlineButtons
        let inlineRow = makeSettingRow(title: "段落后显示AI按钮", control: inlineButtonSwitch)

        let saveButton = UIButton(type: .system)
        saveButton.setTitle("保存", for: .normal)
        saveButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        saveButton.addTarget(self, action: #selector(saveSettings), for: .touchUpInside)

        stackView.addArrangedSubview(makeTitleValueView(title: "DeepSeek API Key", valueView: apiKeyField))
        stackView.addArrangedSubview(makeTitleValueView(title: "吐字方式", valueView: modeControl))
        stackView.addArrangedSubview(makeTitleValueView(title: "AI解释字体", valueView: fontRow))
        stackView.addArrangedSubview(inlineRow)
        stackView.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 18),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            headerView.topAnchor.constraint(equalTo: cardView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -14),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            stackView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12),
            stackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            stackView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            stackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18)
        ])
    }

    private func makeTitleValueView(title: String, valueView: UIView) -> UIView {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 6

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = UIColor.darkGray

        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(valueView)
        return stackView
    }

    private func makeSettingRow(title: String, control: UIView) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 16)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(control)
        return row
    }

    private func updateFontSizeLabel() {
        fontSizeLabel.text = "\(Int(EpubAISettings.clampedFontScale(settings.fontScale) * 100))%"
    }

    @objc private func decreaseFontSize() {
        settings.fontScale = EpubAISettings.clampedFontScale(settings.fontScale - EpubAISettings.fontScaleStep)
        updateFontSizeLabel()
    }

    @objc private func increaseFontSize() {
        settings.fontScale = EpubAISettings.clampedFontScale(settings.fontScale + EpubAISettings.fontScaleStep)
        updateFontSizeLabel()
    }

    @objc private func closeSettings() {
        dismiss(animated: true, completion: nil)
    }

    @objc private func saveSettings() {
        settings.apiKey = apiKeyField.text ?? ""
        settings.usesStreaming = modeControl.selectedSegmentIndex == 0
        settings.showsInlineButtons = inlineButtonSwitch.isOn
        settings.save()
        onSave(settings)
        dismiss(animated: true, completion: nil)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

final class EpubReaderViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private static let defaultFontScale: CGFloat = 3.0
    private static let fontScaleStep: CGFloat = 0.5
    private static let minimumFontScale: CGFloat = 0.5
    private static let maximumFontScale: CGFloat = 6.0
    private static let deepSeekAPIURL = "https://api.deepseek.com/chat/completions"
    private static let deepSeekModel = "deepseek-v4-pro"
    private static let deepSeekSystemPrompt = "你是一个专业的佛经翻译人员，把文言文佛经翻译成白话文，采用直译为主、文白相间的风格, 既保持经典庄严感又确保现代人能理解。直接输出译文，不要解释过程。"

    private let epubURL: URL
    private let suggestedTitle: String
    private let bookLocation: String
    private let targetExcerpt: Excerpt?

    private var webView: WKWebView!
    private let bottomToolbar = UIView()
    private let progressLabel = UILabel()
    private let loadingView = UIActivityIndicatorView(style: .gray)
    private var toolbarButtons: [UIButton] = []

    private var book: EpubBook?
    private var currentChapterIndex = 0
    private var fontScale: CGFloat = EpubReaderViewController.defaultFontScale
    private var pendingScrollY: Double?
    private var pendingScrollToExcerptID: Int64?
    private var activeAIExplanationTask: URLSessionDataTask?
    private var activeAIExplanationClient: DeepSeekStreamingClient?
    private var aiExplanationDisplayTimer: Timer?
    private var aiExplanationPendingCharacters: [Character] = []
    private var aiExplanationDisplayedText = ""
    private var aiExplanationDidFinishStreaming = false
    private var aiExplanationCopyActionAdded = false
    private var aiExplanationOverlayView: UIView?
    private var aiExplanationCardView: UIView?
    private var aiExplanationTextView: UITextView?
    private var aiExplanationLoadingView: UIActivityIndicatorView?
    private var aiExplanationCopyButton: UIButton?
    private var readingPositionKey: String {
        return "dufoj.epubReader.position.\(epubURL.path)"
    }

    init(epubURL: URL, title: String, bookLocation: String = "", targetExcerpt: Excerpt? = nil) {
        self.epubURL = epubURL
        self.suggestedTitle = title
        self.bookLocation = bookLocation
        self.targetExcerpt = targetExcerpt
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

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installExcerptMenuItem()
        becomeFirstResponder()
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
        UIMenuController.shared.menuItems = nil
    }

    deinit {
        activeAIExplanationTask?.cancel()
        activeAIExplanationClient?.cancel()
        aiExplanationDisplayTimer?.invalidate()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "dufojAIExplain")
        NotificationCenter.default.removeObserver(self)
    }

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "dufojAIExplain")
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
                    if let excerpt = self.targetExcerpt,
                       book.chapters.indices.contains(excerpt.chapterIndex) {
                        self.currentChapterIndex = excerpt.chapterIndex
                        self.pendingScrollToExcerptID = excerpt.id
                        self.loadCurrentChapter(scrollY: nil)
                    } else {
                        self.currentChapterIndex = position?.chapterIndex ?? 0
                        self.loadCurrentChapter(scrollY: position?.scrollY)
                    }
                case .failure:
                    ShowMessage(controller: self, msg: "无法打开这本 EPUB", title: "错误")
                }
            }
        }
    }

    private func loadCurrentChapter(scrollY: Double? = 0, targetURL: URL? = nil) {
        guard let book = book, book.chapters.indices.contains(currentChapterIndex) else {
            return
        }

        let chapter = book.chapters[currentChapterIndex]
        progressLabel.text = "\(currentChapterIndex + 1)/\(book.chapters.count)"
        pendingScrollY = scrollY
        installReaderStyleUserScript()
        webView.loadFileURL(targetURL ?? chapter.url, allowingReadAccessTo: book.rootURL)
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
        .dufoj-excerpt-underline {
          text-decoration-line: underline !important;
          text-decoration-thickness: 0.12em !important;
          text-decoration-color: #2f9e44 !important;
          text-underline-offset: 0.16em !important;
        }
        .dufoj-ai-inline-wrapper {
          display: flex !important;
          justify-content: flex-end !important;
          margin: -0.55em 0 0.7em !important;
        }
        .dufoj-ai-inline-button {
          display: inline-flex !important;
          align-items: center !important;
          gap: 4px !important;
          border: 1px solid rgba(10, 132, 255, 0.36) !important;
          border-radius: 14px !important;
          padding: 3px 8px !important;
          background: \(isDarkModeEnabled ? "rgba(45, 92, 160, 0.34)" : "rgba(255, 255, 255, 0.72)") !important;
          color: #0a84ff !important;
          font: 500 12px -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif !important;
          line-height: 1.2 !important;
          -webkit-text-size-adjust: none !important;
        }
        .dufoj-ai-inline-button svg {
          width: 14px !important;
          height: 14px !important;
          display: block !important;
        }
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
        applyAIInlineButtonsToCurrentDocument()
    }

    private func applyAIInlineButtonsToCurrentDocument() {
        let script = aiInlineButtonScript(enabled: EpubAISettings.load().showsInlineButtons)
        webView.evaluateJavaScript(script) { _, error in
            if let error = error {
                LogDebug(log: "Apply AI inline buttons failed: \(error.localizedDescription)")
            }
        }
    }

    private func aiInlineButtonScript(enabled: Bool) -> String {
        let enabledLiteral = enabled ? "true" : "false"
        return """
        (function() {
          var enabled = \(enabledLiteral);

          function removeExistingButtons() {
            Array.prototype.slice.call(document.querySelectorAll('.dufoj-ai-inline-wrapper')).forEach(function(node) {
              if (node.parentNode) {
                node.parentNode.removeChild(node);
              }
            });
          }

          removeExistingButtons();
          if (!enabled || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.dufojAIExplain) {
            return true;
          }

          function candidateBlocks() {
            return Array.prototype.slice.call(document.querySelectorAll('p, div.lg')).filter(function(block) {
              if (!block || block.closest('.dufoj-ai-inline-wrapper')) {
                return false;
              }
              var text = (block.innerText || block.textContent || '').replace(/[\\s\\u3000]+/g, '');
              return text.length >= 8;
            });
          }

          function buttonHTML() {
            return '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2.6l1.7 5.2 5.4 1.9-5.4 1.9-1.7 5.2-1.7-5.2-5.4-1.9 5.4-1.9L12 2.6z" fill="#0a84ff"/><path d="M18.8 13.8l.8 2.3 2.3.8-2.3.8-.8 2.3-.8-2.3-2.3-.8 2.3-.8.8-2.3z" fill="#7c3aed"/></svg><span>AI</span>';
          }

          candidateBlocks().forEach(function(block) {
            var wrapper = document.createElement('span');
            wrapper.className = 'dufoj-ai-inline-wrapper';

            var button = document.createElement('button');
            button.type = 'button';
            button.className = 'dufoj-ai-inline-button';
            button.innerHTML = buttonHTML();
            button.addEventListener('click', function(event) {
              event.preventDefault();
              event.stopPropagation();
              var text = (block.innerText || block.textContent || '').replace(/^\\s+|\\s+$/g, '');
              window.webkit.messageHandlers.dufojAIExplain.postMessage({ text: text });
            });

            wrapper.appendChild(button);
            if (block.nextSibling) {
              block.parentNode.insertBefore(wrapper, block.nextSibling);
            } else {
              block.parentNode.appendChild(wrapper);
            }
          });

          return true;
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dufojAIExplain",
              let dictionary = message.body as? [String: Any],
              let text = dictionary["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        showAIExplanation(for: text)
    }

    private func installExcerptMenuItem() {
        let excerptItem = UIMenuItem(title: "📝摘录", action: #selector(createExcerptFromSelection))
        let explainItem = UIMenuItem(title: "AI解释", action: #selector(explainSelectionWithAI))
        UIMenuController.shared.menuItems = [excerptItem, explainItem]
        UIMenuController.shared.update()
    }

    @available(iOS 13.0, *)
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)

        let excerptCommand = UICommand(title: "📝摘录",
                                       image: nil,
                                       action: #selector(createExcerptFromSelection),
                                       propertyList: nil)
        let explainCommand = UICommand(title: "AI解释",
                                       image: nil,
                                       action: #selector(explainSelectionWithAI),
                                       propertyList: nil)
        let menu = UIMenu(title: "",
                          image: nil,
                          identifier: UIMenu.Identifier("dufoj.excerpt.menu"),
                          options: .displayInline,
                          children: [excerptCommand, explainCommand])
        builder.insertChild(menu, atStartOfMenu: .standardEdit)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(createExcerptFromSelection) ||
            action == #selector(explainSelectionWithAI) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func createExcerptFromSelection() {
        guard let book = book, book.chapters.indices.contains(currentChapterIndex) else {
            return
        }

        webView.evaluateJavaScript(selectionExcerptScript()) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                LogDebug(log: "Create excerpt failed: \(error.localizedDescription)")
                return
            }

            guard let dictionary = result as? [String: Any],
                  let text = dictionary["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            let occurrence = Int(self.doubleValue(from: dictionary["occurrence"]))
            let startOffset = self.optionalInt(from: dictionary["startOffset"])
            let endOffset = self.optionalInt(from: dictionary["endOffset"])
            let chapter = book.chapters[self.currentChapterIndex]
            guard let excerpt = DatabaseAccessor.addExcerpt(bookTitle: book.title,
                                                            bookLocation: self.bookLocation,
                                                            chapterIndex: self.currentChapterIndex,
                                                            chapterTitle: chapter.title,
                                                            selectedText: text,
                                                            occurrence: occurrence,
                                                            startOffset: startOffset,
                                                            endOffset: endOffset) else {
                ShowMessage(controller: self, msg: "保存摘录失败", title: "错误")
                return
            }

            self.applyExcerptsToCurrentDocument(scrollToExcerptID: excerpt.id, completion: nil)
        }
    }

    @objc private func explainSelectionWithAI() {
        webView.evaluateJavaScript(selectionTextScript()) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                LogDebug(log: "Read selection for AI explanation failed: \(error.localizedDescription)")
                return
            }

            guard let selectedText = result as? String,
                  !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                ShowMessage(controller: self, msg: "请先选择一段文字", title: "AI解释")
                return
            }

            self.showAIExplanation(for: selectedText)
        }
    }

    private func selectionTextScript() -> String {
        return """
        (function() {
          var selection = window.getSelection();
          if (!selection || selection.rangeCount === 0) {
            return null;
          }
          var text = selection.toString().replace(/^\\s+|\\s+$/g, '');
          return text || null;
        })();
        """
    }

    private func showAIExplanation(for selectedText: String) {
        resetAIExplanationState()
        showAIExplanationPopup()

        let settings = EpubAISettings.load()
        if settings.usesStreaming {
            requestAIExplanationStream(for: selectedText,
                                       apiKey: settings.effectiveAPIKey,
                                       onText: { [weak self] text in
                                           self?.enqueueAIExplanationText(text)
                                       },
                                       completion: { [weak self] result in
                                           self?.finishAIExplanationRequest(with: result)
                                       })
        } else {
            requestAIExplanation(for: selectedText, apiKey: settings.effectiveAPIKey) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let explanation):
                    self.stopAIExplanationLoading()
                    self.aiExplanationDisplayedText = explanation
                    self.updateAIExplanationTextView()
                    self.finishAIExplanationIfReady()
                case .failure(let error):
                    self.showAIExplanationError(error)
                }
            }
        }
    }

    private func showAIExplanationPopup() {
        closeAIExplanationPopup(keepRequest: true)

        let overlayView = UIView()
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.backgroundColor = UIColor(white: 0, alpha: 0.36)
        view.addSubview(overlayView)

        let cardView = UIView()
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = isDarkModeEnabled ? UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1) : UIColor(white: 0.99, alpha: 1)
        cardView.layer.cornerRadius = 10
        cardView.layer.masksToBounds = true
        overlayView.addSubview(cardView)

        let headerView = UIView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(headerView)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "AI解释"
        titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.textColor = isDarkModeEnabled ? UIColor(white: 0.92, alpha: 1) : UIColor(white: 0.1, alpha: 1)
        headerView.addSubview(titleLabel)

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("×", for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 24, weight: .regular)
        closeButton.addTarget(self, action: #selector(closeAIExplanationButtonTapped), for: .touchUpInside)
        headerView.addSubview(closeButton)

        let settingsButton = UIButton(type: .system)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setTitle("设置", for: .normal)
        settingsButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        settingsButton.addTarget(self, action: #selector(showAISettings), for: .touchUpInside)
        headerView.addSubview(settingsButton)

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        textView.backgroundColor = isDarkModeEnabled ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) : UIColor(white: 0.96, alpha: 1)
        textView.textColor = isDarkModeEnabled ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.13, alpha: 1)
        textView.layer.cornerRadius = 8
        textView.text = ""
        textView.font = aiExplanationFont()
        cardView.addSubview(textView)

        let loadingView = UIActivityIndicatorView(style: .gray)
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.startAnimating()
        textView.addSubview(loadingView)

        let copyButton = UIButton(type: .system)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.setTitle("复制解释", for: .normal)
        copyButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        copyButton.isHidden = true
        copyButton.addTarget(self, action: #selector(copyAIExplanation), for: .touchUpInside)
        cardView.addSubview(copyButton)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: view.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cardView.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            cardView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 22),
            cardView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -22),
            cardView.heightAnchor.constraint(equalTo: safeArea.heightAnchor, multiplier: 0.62),

            headerView.topAnchor.constraint(equalTo: cardView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -10),
            closeButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 14),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            settingsButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -14),
            settingsButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 54),
            settingsButton.heightAnchor.constraint(equalToConstant: 44),

            textView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 6),
            textView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            textView.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -8),

            loadingView.centerXAnchor.constraint(equalTo: textView.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: textView.centerYAnchor),

            copyButton.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            copyButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            copyButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),
            copyButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        aiExplanationOverlayView = overlayView
        aiExplanationCardView = cardView
        aiExplanationTextView = textView
        aiExplanationLoadingView = loadingView
        aiExplanationCopyButton = copyButton
    }

    private func aiExplanationFont() -> UIFont {
        return UIFont.systemFont(ofSize: 17 * EpubAISettings.load().fontScale)
    }

    private func resetAIExplanationState() {
        activeAIExplanationTask?.cancel()
        activeAIExplanationClient?.cancel()
        activeAIExplanationTask = nil
        activeAIExplanationClient = nil
        aiExplanationDisplayTimer?.invalidate()
        aiExplanationDisplayTimer = nil
        aiExplanationPendingCharacters = []
        aiExplanationDisplayedText = ""
        aiExplanationDidFinishStreaming = false
        aiExplanationCopyActionAdded = false
        aiExplanationCopyButton?.isHidden = true
        aiExplanationTextView?.text = ""
        aiExplanationLoadingView?.startAnimating()
    }

    private func enqueueAIExplanationText(_ text: String) {
        aiExplanationPendingCharacters.append(contentsOf: text)
        startAIExplanationDisplayTimer()
    }

    private func startAIExplanationDisplayTimer() {
        guard aiExplanationDisplayTimer == nil else {
            return
        }

        aiExplanationDisplayTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] timer in
            guard let self = self, self.aiExplanationTextView != nil else {
                timer.invalidate()
                return
            }

            guard !self.aiExplanationPendingCharacters.isEmpty else {
                timer.invalidate()
                self.aiExplanationDisplayTimer = nil
                self.finishAIExplanationIfReady()
                return
            }

            if self.aiExplanationDisplayedText.isEmpty {
                self.stopAIExplanationLoading()
            }

            let nextCharacter = self.aiExplanationPendingCharacters.removeFirst()
            self.aiExplanationDisplayedText.append(nextCharacter)
            self.updateAIExplanationTextView()
        }
    }

    private func finishAIExplanationRequest(with result: Result<Void, Error>) {
        switch result {
        case .success:
            aiExplanationDidFinishStreaming = true
            finishAIExplanationIfReady()
        case .failure(let error):
            if let deepSeekError = error as? DeepSeekExplanationError,
               case .cancelled = deepSeekError {
                return
            }
            showAIExplanationError(error)
        }
    }

    private func finishAIExplanationIfReady() {
        guard (aiExplanationDidFinishStreaming || activeAIExplanationClient == nil),
              aiExplanationPendingCharacters.isEmpty,
              !aiExplanationDisplayedText.isEmpty,
              !aiExplanationCopyActionAdded else {
            return
        }

        aiExplanationCopyActionAdded = true
        stopAIExplanationLoading()
        aiExplanationCopyButton?.isHidden = false
    }

    private func updateAIExplanationTextView() {
        guard let textView = aiExplanationTextView else { return }
        textView.font = aiExplanationFont()
        textView.text = aiExplanationDisplayedText
        if !aiExplanationDisplayedText.isEmpty {
            let bottomRange = NSRange(location: max(0, aiExplanationDisplayedText.count - 1), length: 1)
            textView.scrollRangeToVisible(bottomRange)
        }
    }

    private func stopAIExplanationLoading() {
        aiExplanationLoadingView?.stopAnimating()
        aiExplanationLoadingView?.isHidden = true
    }

    private func showAIExplanationError(_ error: Error) {
        stopAIExplanationLoading()
        let message = error.localizedDescription
        if aiExplanationDisplayedText.isEmpty {
            aiExplanationDisplayedText = message
            updateAIExplanationTextView()
        } else {
            enqueueAIExplanationText("\n\n\(message)")
            aiExplanationDidFinishStreaming = true
            finishAIExplanationIfReady()
        }
    }

    @objc private func copyAIExplanation() {
        UIPasteboard.general.string = aiExplanationDisplayedText
    }

    @objc private func closeAIExplanationButtonTapped() {
        closeAIExplanationPopup(keepRequest: false)
    }

    private func closeAIExplanationPopup(keepRequest: Bool) {
        if !keepRequest {
            resetAIExplanationState()
        }
        aiExplanationOverlayView?.removeFromSuperview()
        aiExplanationOverlayView = nil
        aiExplanationCardView = nil
        aiExplanationTextView = nil
        aiExplanationLoadingView = nil
        aiExplanationCopyButton = nil
    }

    @objc private func showAISettings() {
        let controller = EpubAISettingsViewController(settings: EpubAISettings.load()) { [weak self] settings in
            guard let self = self else { return }
            self.aiExplanationTextView?.font = self.aiExplanationFont()
            self.applyReaderStyleToCurrentDocument()
            if settings.showsInlineButtons {
                self.applyAIInlineButtonsToCurrentDocument()
            }
        }
        present(controller, animated: true, completion: nil)
    }

    private func requestAIExplanationStream(for selectedText: String,
                                            apiKey: String,
                                            onText: @escaping (String) -> Void,
                                            completion: @escaping (Result<Void, Error>) -> Void) {
        guard let request = makeAIExplanationRequest(selectedText: selectedText, apiKey: apiKey, stream: true) else {
            completion(.failure(DeepSeekExplanationError.invalidResponse))
            return
        }

        let client = DeepSeekStreamingClient(request: request, onText: onText) { [weak self] result in
            self?.activeAIExplanationTask = nil
            self?.activeAIExplanationClient = nil
            completion(result)
        }
        activeAIExplanationClient = client
        client.start()
        activeAIExplanationTask = client.task
    }

    private func requestAIExplanation(for selectedText: String,
                                      apiKey: String,
                                      completion: @escaping (Result<String, Error>) -> Void) {
        guard let request = makeAIExplanationRequest(selectedText: selectedText, apiKey: apiKey, stream: false) else {
            completion(.failure(DeepSeekExplanationError.invalidResponse))
            return
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<String, Error>
            defer {
                DispatchQueue.main.async {
                    self?.activeAIExplanationTask = nil
                    completion(result)
                }
            }

            if let error = error as NSError? {
                if error.code == NSURLErrorCancelled {
                    result = .failure(DeepSeekExplanationError.cancelled)
                } else {
                    result = .failure(DeepSeekExplanationError.requestFailed(error.localizedDescription))
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let data = data else {
                result = .failure(DeepSeekExplanationError.invalidResponse)
                return
            }

            let decodedResponse = try? JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
            if !(200...299).contains(httpResponse.statusCode) {
                let message = decodedResponse?.error?.message ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                result = .failure(DeepSeekExplanationError.requestFailed(message))
                return
            }

            guard let content = decodedResponse?.choices?.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                result = .failure(DeepSeekExplanationError.emptyResponse)
                return
            }

            result = .success(content)
        }
        activeAIExplanationTask = task
        task.resume()
    }

    private func makeAIExplanationRequest(selectedText: String, apiKey: String, stream: Bool) -> URLRequest? {
        guard let url = URL(string: EpubReaderViewController.deepSeekAPIURL) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = DeepSeekChatRequest(model: EpubReaderViewController.deepSeekModel,
                                       messages: [
                                           DeepSeekChatMessage(role: "system", content: EpubReaderViewController.deepSeekSystemPrompt),
                                           DeepSeekChatMessage(role: "user", content: "翻译：\(selectedText)")
                                       ],
                                       stream: stream)
        request.httpBody = try? JSONEncoder().encode(body)
        return request.httpBody == nil ? nil : request
    }

    private func selectionExcerptScript() -> String {
        return """
        (function() {
          function textNodesUnder(root) {
            var nodes = [];
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
              acceptNode: function(node) {
                if (!node.nodeValue || node.nodeValue.length === 0) {
                  return NodeFilter.FILTER_REJECT;
                }
                var parent = node.parentElement;
                if (!parent || /^(SCRIPT|STYLE|NOSCRIPT)$/i.test(parent.tagName)) {
                  return NodeFilter.FILTER_REJECT;
                }
                return NodeFilter.FILTER_ACCEPT;
              }
            });
            var current;
            while ((current = walker.nextNode())) {
              nodes.push(current);
            }
            return nodes;
          }

          function documentTextInfo() {
            var nodes = textNodesUnder(document.body || document.documentElement);
            var text = '';
            var ranges = [];
            nodes.forEach(function(node) {
              ranges.push({ node: node, start: text.length, end: text.length + node.nodeValue.length });
              text += node.nodeValue;
            });
            return { text: text, ranges: ranges };
          }

          function indexOfNode(ranges, node) {
            for (var i = 0; i < ranges.length; i++) {
              if (ranges[i].node === node) {
                return ranges[i].start;
              }
            }
            return -1;
          }

          function boundaryIndex(ranges, node, offset) {
            var index = indexOfNode(ranges, node);
            if (index >= 0) {
              return index + offset;
            }
            return -1;
          }

          var selection = window.getSelection();
          if (!selection || selection.rangeCount === 0) {
            return null;
          }

          var selectedText = selection.toString().replace(/^\\s+|\\s+$/g, '');
          if (!selectedText) {
            return null;
          }

          var range = selection.getRangeAt(0);
          var info = documentTextInfo();
          var start = boundaryIndex(info.ranges, range.startContainer, range.startOffset);
          var end = boundaryIndex(info.ranges, range.endContainer, range.endOffset);
          if (start < 0) {
            start = info.text.indexOf(selectedText);
          }
          if (end < 0 && start >= 0) {
            end = start + selectedText.length;
          }

          var occurrence = 0;
          if (start > 0) {
            var searchFrom = 0;
            while (true) {
              var found = info.text.indexOf(selectedText, searchFrom);
              if (found < 0 || found >= start) {
                break;
              }
              occurrence += 1;
              searchFrom = found + Math.max(selectedText.length, 1);
            }
          }

          try {
            var wrapper = document.createElement('span');
            wrapper.className = 'dufoj-excerpt-underline';
            wrapper.appendChild(range.extractContents());
            range.insertNode(wrapper);
          } catch (e) {}

          selection.removeAllRanges();
          return { text: selectedText, occurrence: occurrence, startOffset: start, endOffset: end };
        })();
        """
    }

    private func applyExcerptsToCurrentDocument(scrollToExcerptID: Int64?, completion: (() -> Void)?) {
        guard !bookLocation.isEmpty else {
            completion?()
            return
        }

        let excerpts = DatabaseAccessor.getExcerpts(bookLocation: bookLocation, chapterIndex: currentChapterIndex)
        let payload = excerpts.map { excerpt -> [String: Any] in
            return [
                "id": excerpt.id,
                "text": excerpt.selectedText,
                "occurrence": excerpt.occurrence,
                "startOffset": excerpt.startOffset ?? NSNull(),
                "endOffset": excerpt.endOffset ?? NSNull()
            ]
        }

        let payloadLiteral = javaScriptLiteral(from: payload, fallback: "[]")
        let targetLiteral = scrollToExcerptID.map { "\($0)" } ?? "null"
        let script = applyExcerptsScript(payloadLiteral: payloadLiteral, targetLiteral: targetLiteral)

        webView.evaluateJavaScript(script) { _, error in
            if let error = error {
                LogDebug(log: "Apply excerpts failed: \(error.localizedDescription)")
            }
            completion?()
        }
    }

    private func applyExcerptsScript(payloadLiteral: String, targetLiteral: String) -> String {
        return """
        (function() {
          var excerpts = \(payloadLiteral);
          var targetID = \(targetLiteral);

          function unwrapExistingUnderlines() {
            Array.prototype.slice.call(document.querySelectorAll('.dufoj-excerpt-underline')).forEach(function(node) {
              var parent = node.parentNode;
              if (!parent) {
                return;
              }
              while (node.firstChild) {
                parent.insertBefore(node.firstChild, node);
              }
              parent.removeChild(node);
              parent.normalize();
            });
          }

          function textNodesUnder(root) {
            var nodes = [];
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
              acceptNode: function(node) {
                if (!node.nodeValue || node.nodeValue.length === 0) {
                  return NodeFilter.FILTER_REJECT;
                }
                var parent = node.parentElement;
                if (!parent || /^(SCRIPT|STYLE|NOSCRIPT)$/i.test(parent.tagName)) {
                  return NodeFilter.FILTER_REJECT;
                }
                return NodeFilter.FILTER_ACCEPT;
              }
            });
            var current;
            while ((current = walker.nextNode())) {
              nodes.push(current);
            }
            return nodes;
          }

          function documentTextInfo() {
            var nodes = textNodesUnder(document.body || document.documentElement);
            var text = '';
            var ranges = [];
            nodes.forEach(function(node) {
              ranges.push({ node: node, start: text.length, end: text.length + node.nodeValue.length });
              text += node.nodeValue;
            });
            return { text: text, ranges: ranges };
          }

          function boundaryAt(ranges, index, preferEnd) {
            for (var i = 0; i < ranges.length; i++) {
              var item = ranges[i];
              if (index >= item.start && index < item.end) {
                return { node: item.node, offset: index - item.start };
              }
              if (preferEnd && index === item.end) {
                return { node: item.node, offset: item.node.nodeValue.length };
              }
            }
            return null;
          }

          function indexForOccurrence(text, needle, occurrence) {
            var from = 0;
            var found = -1;
            for (var i = 0; i <= occurrence; i++) {
              found = text.indexOf(needle, from);
              if (found < 0) {
                return -1;
              }
              from = found + Math.max(needle.length, 1);
            }
            return found;
          }

          function normalizedMatchIndex(text, needle, occurrence) {
            var compactText = '';
            var compactMap = [];
            for (var i = 0; i < text.length; i++) {
              if (!/[\\s\\u3000]/.test(text.charAt(i))) {
                compactMap.push(i);
                compactText += text.charAt(i);
              }
            }

            var compactNeedle = (needle || '').replace(/[\\s\\u3000]+/g, '');
            if (!compactNeedle) {
              return null;
            }

            var compactStart = indexForOccurrence(compactText, compactNeedle, occurrence);
            if (compactStart < 0) {
              compactStart = compactText.indexOf(compactNeedle);
            }
            if (compactStart < 0) {
              return null;
            }

            var compactEnd = compactStart + compactNeedle.length - 1;
            return {
              start: compactMap[compactStart],
              end: compactMap[compactEnd] + 1
            };
          }

          unwrapExistingUnderlines();

          excerpts.forEach(function(excerpt) {
            if (!excerpt || !excerpt.text) {
              return;
            }

            var info = documentTextInfo();
            var startIndex = -1;
            var endIndex = -1;

            if (typeof excerpt.startOffset === 'number' &&
                typeof excerpt.endOffset === 'number' &&
                excerpt.startOffset >= 0 &&
                excerpt.endOffset > excerpt.startOffset &&
                excerpt.endOffset <= info.text.length) {
              startIndex = excerpt.startOffset;
              endIndex = excerpt.endOffset;
            }

            if (startIndex < 0) {
              startIndex = indexForOccurrence(info.text, excerpt.text, Math.max(0, excerpt.occurrence || 0));
              if (startIndex < 0) {
                startIndex = info.text.indexOf(excerpt.text);
              }
              if (startIndex >= 0) {
                endIndex = startIndex + excerpt.text.length;
              }
            }

            if (startIndex < 0 || endIndex <= startIndex) {
              var normalizedMatch = normalizedMatchIndex(info.text, excerpt.text, Math.max(0, excerpt.occurrence || 0));
              if (!normalizedMatch) {
                return;
              }
              startIndex = normalizedMatch.start;
              endIndex = normalizedMatch.end;
            }

            var start = boundaryAt(info.ranges, startIndex, false);
            var end = boundaryAt(info.ranges, endIndex, true);
            if (!start || !end) {
              return;
            }

            try {
              var range = document.createRange();
              range.setStart(start.node, start.offset);
              range.setEnd(end.node, end.offset);
              var wrapper = document.createElement('span');
              wrapper.className = 'dufoj-excerpt-underline';
              wrapper.setAttribute('data-dufoj-excerpt-id', String(excerpt.id));
              wrapper.appendChild(range.extractContents());
              range.insertNode(wrapper);
            } catch (e) {}
          });

          if (targetID !== null && targetID !== undefined) {
            var target = document.querySelector('[data-dufoj-excerpt-id="' + targetID + '"]');
            if (target) {
              setTimeout(function() {
                target.scrollIntoView({ block: 'center' });
              }, 30);
            }
          }
          return true;
        })();
        """
    }

    private func javaScriptLiteral(from object: Any, fallback: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return string
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

        let contents = EpubContentsViewController(items: book.tocItems, currentIndex: currentChapterIndex) { [weak self] item in
            self?.saveCurrentPosition()
            self?.currentChapterIndex = item.chapterIndex ?? 0
            self?.loadCurrentChapter(scrollY: item.url?.fragment == nil ? 0 : nil, targetURL: item.url)
        }
        let navigationController = UINavigationController(rootViewController: contents)
        present(navigationController, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let targetExcerptID = pendingScrollToExcerptID
        pendingScrollToExcerptID = nil
        applyExcerptsToCurrentDocument(scrollToExcerptID: targetExcerptID) { [weak self] in
            self?.applyAIInlineButtonsToCurrentDocument()
            guard targetExcerptID == nil else {
                return
            }
            self?.restorePendingScrollPosition()
        }
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

    private func optionalInt(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return Int(value)
        }
        return nil
    }

    private func clampedFontScale(_ value: Double) -> Double {
        return min(Double(EpubReaderViewController.maximumFontScale),
                   max(Double(EpubReaderViewController.minimumFontScale), value))
    }
}

private final class EpubContentsViewController: UITableViewController {
    private struct Row {
        let item: EpubTocItem
        let level: Int
    }

    private let rows: [Row]
    private let currentIndex: Int
    private let onSelect: (EpubTocItem) -> Void

    init(items: [EpubTocItem], currentIndex: Int, onSelect: @escaping (EpubTocItem) -> Void) {
        self.rows = EpubContentsViewController.flatten(items: items)
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
        return rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapterCell", for: indexPath)
        let row = rows[indexPath.row]
        let isSelectable = row.item.chapterIndex != nil
        cell.textLabel?.text = row.item.title
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = UIFont.systemFont(ofSize: row.level == 0 ? 17 : 16,
                                                 weight: row.item.children.isEmpty ? .regular : .semibold)
        cell.textLabel?.textColor = textColor(isSelectable: isSelectable)
        cell.backgroundColor = isDarkModeEnabled ? UIColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1) : UIColor(red: 0.98, green: 0.96, blue: 0.90, alpha: 1)
        cell.indentationLevel = row.level
        cell.indentationWidth = 18
        cell.selectionStyle = isSelectable ? .default : .none
        cell.accessoryType = row.item.chapterIndex == currentIndex ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = rows[indexPath.row].item
        guard item.chapterIndex != nil else {
            return
        }

        onSelect(item)
        dismiss(animated: true, completion: nil)
    }

    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }

    private func updateColors() {
        tableView.backgroundColor = isDarkModeEnabled ? UIColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1) : UIColor(red: 0.98, green: 0.96, blue: 0.90, alpha: 1)
        navigationController?.navigationBar.barStyle = isDarkModeEnabled ? .black : .default
    }

    private func textColor(isSelectable: Bool) -> UIColor {
        if isDarkModeEnabled {
            return isSelectable ? UIColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1) : UIColor(red: 0.50, green: 0.50, blue: 0.52, alpha: 1)
        }
        return isSelectable ? UIColor(red: 0.12, green: 0.14, blue: 0.16, alpha: 1) : UIColor(white: 0.50, alpha: 1)
    }

    private var isDarkModeEnabled: Bool {
        if #available(iOS 13.0, *) {
            return traitCollection.userInterfaceStyle == .dark
        }
        return false
    }

    private static func flatten(items: [EpubTocItem], level: Int = 0) -> [Row] {
        return items.flatMap { item -> [Row] in
            return [Row(item: item, level: level)] + flatten(items: item.children, level: level + 1)
        }
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
        let parsedTocItems = parseTocItems(package: package, baseURL: baseURL)
        let tocTitles = titlesByHref(from: parsedTocItems)

        let chapters = package.spine.compactMap { idref -> EpubChapter? in
            guard !isSkippedChapterID(idref) else {
                return nil
            }

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

        let tocItems = resolveTocItems(parsedTocItems, baseURL: baseURL, chapters: chapters)
        let finalTocItems = tocItems.isEmpty ? fallbackTocItems(chapters: chapters) : tocItems

        return EpubBook(title: package.title, rootURL: destinationURL, chapters: chapters, tocItems: finalTocItems)
    }

    private static func isSkippedChapterID(_ idref: String) -> Bool {
        let skippedChapterIDs: Set<String> = ["front", "back"]
        return skippedChapterIDs.contains(idref.lowercased())
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

    private static func parseTocItems(package: PackageData, baseURL: URL) -> [ParsedTocItem] {
        guard let tocItem = package.tocItem,
              let tocURL = URL(string: tocItem.href, relativeTo: baseURL)?.absoluteURL,
              let parser = XMLParser(contentsOf: tocURL) else {
            return []
        }

        let delegate = TocXMLDelegate()
        parser.delegate = delegate
        if parser.parse() {
            return delegate.items
        }
        return []
    }

    private static func titlesByHref(from items: [ParsedTocItem]) -> [String: String] {
        var titles: [String: String] = [:]
        for item in items {
            let key = normalizedHref(item.href)
            if !key.isEmpty && !item.title.isEmpty {
                titles[key] = item.title
            }
            titles.merge(titlesByHref(from: item.children)) { current, _ in current }
        }
        return titles
    }

    private static func resolveTocItems(_ items: [ParsedTocItem], baseURL: URL, chapters: [EpubChapter]) -> [EpubTocItem] {
        var resolvedItems: [EpubTocItem] = []

        for item in items {
            let children = resolveTocItems(item.children, baseURL: baseURL, chapters: chapters)
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetURL = URL(string: item.href, relativeTo: baseURL)?.absoluteURL
            let resolvedChapterIndex: Int?
            if let targetURL = targetURL {
                resolvedChapterIndex = chapterIndex(for: targetURL, chapters: chapters)
            } else {
                resolvedChapterIndex = nil
            }

            if title.isEmpty || resolvedChapterIndex == nil && children.isEmpty {
                continue
            }

            resolvedItems.append(EpubTocItem(title: title,
                                             url: targetURL,
                                             chapterIndex: resolvedChapterIndex,
                                             children: children))
        }

        return resolvedItems
    }

    private static func fallbackTocItems(chapters: [EpubChapter]) -> [EpubTocItem] {
        return chapters.enumerated().map { index, chapter in
            return EpubTocItem(title: chapter.title,
                               url: chapter.url,
                               chapterIndex: index,
                               children: [])
        }
    }

    private static func chapterIndex(for url: URL, chapters: [EpubChapter]) -> Int? {
        let normalizedURL = normalizedFileURL(url)
        return chapters.firstIndex { normalizedFileURL($0.url) == normalizedURL }
    }

    private static func normalizedFileURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return (components?.url ?? url).standardizedFileURL
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

    var tocItem: ManifestItem? {
        if let tocID = tocID, let item = manifest[tocID] {
            return item
        }

        return manifest.values.first {
            $0.mediaType.lowercased().contains("ncx") || $0.href.lowercased().hasSuffix(".ncx")
        }
    }
}

private struct ParsedTocItem {
    let title: String
    let href: String
    let children: [ParsedTocItem]
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
    private final class NavPoint {
        var title = ""
        var href = ""
        var children: [ParsedTocItem] = []
        var readingTitle = false
    }

    private var navStack: [NavPoint] = []
    private(set) var items: [ParsedTocItem] = []

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
            navStack[navStack.count - 1].href = decodedHref(src)
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
            guard !title.isEmpty || !navPoint.href.isEmpty || !navPoint.children.isEmpty else {
                return
            }

            let item = ParsedTocItem(title: title, href: navPoint.href, children: navPoint.children)
            if navStack.isEmpty {
                items.append(item)
            } else {
                navStack[navStack.count - 1].children.append(item)
            }
        }
    }

    private func decodedHref(_ href: String) -> String {
        return href.removingPercentEncoding ?? href
    }
}

private func simpleName(_ elementName: String) -> String {
    return (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
}

extension UIViewController {
    func openEpubReader(book: Books) {
        openEpubReader(book: book, targetExcerpt: nil)
    }

    func openEpubReader(book: Books, targetExcerpt: Excerpt?) {
        guard let bookPath = Bundle.main.path(forResource: "cbeta_epub_2019q4.bundle/\(book.location)", ofType: "epub") else {
            ShowMessage(controller: self, msg: "找不到 EPUB 文件", title: "错误")
            return
        }

        let reader = EpubReaderViewController(epubURL: URL(fileURLWithPath: bookPath),
                                              title: book.title,
                                              bookLocation: book.location,
                                              targetExcerpt: targetExcerpt)
        if let navigationController = navigationController {
            navigationController.pushViewController(reader, animated: true)
        } else {
            present(UINavigationController(rootViewController: reader), animated: true, completion: nil)
        }
    }
}
