import Cocoa
import UserNotifications

// MARK: - 消息类型
private enum MsgType: String {
    case poke = "poke"
    case heartbeat = "hb"
}

private struct ParsedMsg {
    let type: MsgType
    let deviceId: String
}

private func parseMessage(_ body: String) -> ParsedMsg? {
    // 新格式：<type>:<deviceId>
    if let colon = body.firstIndex(of: ":") {
        let typeStr = String(body[..<colon])
        let id = String(body[body.index(after: colon)...])
        if let t = MsgType(rawValue: typeStr) {
            return ParsedMsg(type: t, deviceId: id)
        }
    }
    // 兼容旧版：整段就是 deviceId，按 poke 处理
    return ParsedMsg(type: .poke, deviceId: body)
}

// MARK: - ntfy 客户端
final class NtfyClient: NSObject, URLSessionDataDelegate {
    private let baseURL = "https://ntfy.sh"
    private(set) var topic: String
    let deviceId: String
    var onPoke: (() -> Void)?
    var onHeartbeat: (() -> Void)?  // 收到对方心跳

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()

    init(topic: String, deviceId: String) {
        self.topic = topic
        self.deviceId = deviceId
        super.init()
    }

    func subscribe() {
        stop()
        guard !topic.isEmpty,
              let url = URL(string: "\(baseURL)/\(topic)/json") else { return }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 0
        cfg.timeoutIntervalForResource = 0
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        task = session?.dataTask(with: req)
        task?.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer.removeAll()
    }

    func updateTopic(_ newTopic: String) {
        topic = newTopic
        subscribe()
    }

    // 通用发送
    private func send(type: MsgType, tags: String, priority: String,
                      completion: @escaping (Bool) -> Void) {
        guard !topic.isEmpty,
              let url = URL(string: "\(baseURL)/\(topic)") else {
            completion(false); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(priority, forHTTPHeaderField: "Priority")
        req.setValue(tags, forHTTPHeaderField: "Tags")
        req.httpBody = "\(type.rawValue):\(deviceId)".data(using: .utf8)
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
                completion(ok)
            }
        }.resume()
    }

    func poke(completion: @escaping (Bool) -> Void) {
        send(type: .poke, tags: "poke", priority: "low", completion: completion)
    }

    func sendHeartbeat() {
        send(type: .heartbeat, tags: "hb", priority: "min") { _ in }
    }

    // MARK: URLSessionDataDelegate
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: 0..<nl)
            buffer.removeSubrange(0...nl)
            handleLine(lineData)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.subscribe()
        }
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["event"] as? String) == "message" else { return }
        let body = (obj["message"] as? String) ?? ""
        guard let parsed = parseMessage(body) else { return }
        // 自己发的忽略
        if parsed.deviceId == deviceId { return }
        switch parsed.type {
        case .poke: onPoke?()
        case .heartbeat: onHeartbeat?()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!

    private let loveStart: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 5; c.day = 16
        return Calendar.current.date(from: c)!
    }()

    private let topicKey = "ntfyTopic"
    private let deviceKey = "deviceId"

    // 心跳间隔 5 分钟，超时 12 分钟（约 2.4 倍，容忍一次丢包）
    private let heartbeatInterval: TimeInterval = 5 * 60
    private let onlineTimeout: TimeInterval = 12 * 60

    // 更新检测：每周一次
    private let updateCheckInterval: TimeInterval = 7 * 24 * 60 * 60
    private let githubOwner = "HandsomeWu1"
    private let githubRepo = "WeTime"
    private let releasesPageURL = "https://github.com/HandsomeWu1/WeTime/releases/latest"

    private let menu = NSMenu()
    private let summaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let presenceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pokeItem = NSMenuItem(title: "戳 TA 一下 ❤️", action: nil, keyEquivalent: "p")
    private let topicItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "检查更新", action: nil, keyEquivalent: "")

    private var ntfy: NtfyClient!
    private var iconRevertTimer: Timer?
    private var heartbeatTimer: Timer?
    private var presenceRefreshTimer: Timer?
    private var updateCheckTimer: Timer?
    private var defaultIcon: NSImage?

    private var availableNewVersion: String?  // 检测到的新版本号

    private var lastSeenOther: Date?  // 上次收到对方心跳/戳的时间

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defaultIcon = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Love")
        defaultIcon?.isTemplate = true
        statusItem.button?.image = defaultIcon

        let deviceId: String = {
            if let s = UserDefaults.standard.string(forKey: deviceKey) { return s }
            let s = UUID().uuidString
            UserDefaults.standard.set(s, forKey: deviceKey)
            return s
        }()
        let topic = UserDefaults.standard.string(forKey: topicKey) ?? ""
        ntfy = NtfyClient(topic: topic, deviceId: deviceId)
        ntfy.onPoke = { [weak self] in self?.handleIncomingPoke() }
        ntfy.onHeartbeat = { [weak self] in self?.handleIncomingHeartbeat() }

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }

        buildMenu()

        // 首次启动：没有频道时弹窗让用户配置
        if topic.isEmpty {
            promptForTopic(initial: true)
        }

        ntfy.subscribe()

        // 启动后立即发一次心跳，再每 5 分钟一次
        ntfy.sendHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval,
                                              repeats: true) { [weak self] _ in
            self?.ntfy.sendHeartbeat()
        }
        // 每 30 秒刷新一次菜单中的"X 分钟前"显示
        presenceRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30,
                                                    repeats: true) { [weak self] _ in
            self?.refreshPresenceItem()
        }

        // 启动 5 秒后查一次更新，之后每周一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdates(silent: true)
        }
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: updateCheckInterval,
                                                repeats: true) { [weak self] _ in
            self?.checkForUpdates(silent: true)
        }
    }

    private func buildMenu() {
        menu.removeAllItems()
        menu.delegate = self

        summaryItem.target = self
        summaryItem.action = #selector(copySummary)
        menu.addItem(summaryItem)

        detailItem.isEnabled = false
        menu.addItem(detailItem)

        menu.addItem(NSMenuItem.separator())

        presenceItem.isEnabled = false
        menu.addItem(presenceItem)

        pokeItem.target = self
        pokeItem.action = #selector(sendPoke)
        menu.addItem(pokeItem)

        topicItem.target = self
        topicItem.action = #selector(changeTopic)
        menu.addItem(topicItem)

        menu.addItem(NSMenuItem.separator())
        updateItem.target = self
        updateItem.action = #selector(checkForUpdatesManual)
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: "退出",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
        refreshLoveTime()
        refreshTopicItem()
        refreshPresenceItem()
        refreshUpdateItem()
    }

    private func refreshTopicItem() {
        let topic = ntfy.topic
        if topic.isEmpty {
            topicItem.title = "设置共享频道…（未配置）"
            pokeItem.isEnabled = false
        } else {
            topicItem.title = "共享频道：\(topic)（点击修改）"
            pokeItem.isEnabled = true
        }
    }

    private func refreshLoveTime() {
        let now = Date()
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: loveStart, to: now).day ?? 0
        let parts = cal.dateComponents([.year, .month, .day], from: loveStart, to: now)
        let y = parts.year ?? 0, m = parts.month ?? 0, d = parts.day ?? 0
        if now < loveStart {
            let remaining = cal.dateComponents([.day], from: now, to: loveStart).day ?? 0
            summaryItem.title = "❤️ 距离开始还有 \(remaining) 天"
            detailItem.title = "  开始日期：2026 年 5 月 16 日"
        } else {
            summaryItem.title = "❤️ 在一起 \(days) 天"
            detailItem.title = "  \(y) 年 \(m) 个月 \(d) 天"
        }
    }

    private func refreshPresenceItem() {
        guard let last = lastSeenOther else {
            presenceItem.title = "⚪️ 等待对方上线…"
            return
        }
        let elapsed = Date().timeIntervalSince(last)
        if elapsed < onlineTimeout {
            presenceItem.title = "🟢 对方在线"
        } else {
            presenceItem.title = "🔴 对方离线（\(humanAgo(elapsed))）"
        }
    }

    private func humanAgo(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "刚刚" }
        let m = s / 60
        if m < 60 { return "\(m) 分钟前" }
        let h = m / 60
        if h < 24 { return "\(h) 小时前" }
        let d = h / 24
        return "\(d) 天前"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLoveTime()
        refreshTopicItem()
        refreshPresenceItem()
        refreshUpdateItem()
    }

    @objc private func copySummary() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(summaryItem.title, forType: .string)
    }

    @objc private func sendPoke() {
        let original = pokeItem.title
        pokeItem.title = "发送中…"
        pokeItem.isEnabled = false
        ntfy.poke { [weak self] ok in
            guard let self else { return }
            self.pokeItem.title = ok ? "已戳一下 ✓" : "发送失败 ✗"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.pokeItem.title = original
                self.refreshTopicItem()
            }
        }
    }

    @objc private func changeTopic() {
        promptForTopic(initial: false)
    }

    private func promptForTopic(initial: Bool) {
        let alert = NSAlert()
        alert.messageText = initial ? "首次配置：设置共享频道" : "修改共享频道"
        alert.informativeText = "两台 Mac 输入同一个秘密字符串即可配对。\n建议是无人能猜到的长字符串（含字母/数字/横杠）。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        tf.stringValue = ntfy.topic
        tf.placeholderString = "your-secret-channel-xxxx"
        alert.accessoryView = tf
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = tf

        if alert.runModal() == .alertFirstButtonReturn {
            let v = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty {
                UserDefaults.standard.set(v, forKey: topicKey)
                ntfy.updateTopic(v)
                lastSeenOther = nil
                ntfy.sendHeartbeat()
            }
        }
        refreshTopicItem()
        refreshPresenceItem()
    }

    private func handleIncomingPoke() {
        // 戳本身也算一次"对方在线"信号
        lastSeenOther = Date()
        refreshPresenceItem()

        let content = UNMutableNotificationContent()
        content.title = "💕 TA 戳了你一下"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)

        if let button = statusItem.button {
            button.contentTintColor = .systemPink
            iconRevertTimer?.invalidate()
            iconRevertTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak button] _ in
                button?.contentTintColor = nil
            }
        }
    }

    private func handleIncomingHeartbeat() {
        lastSeenOther = Date()
        refreshPresenceItem()
    }

    // MARK: - 更新检测
    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    private func refreshUpdateItem() {
        if let v = availableNewVersion {
            updateItem.title = "⬆️ 发现新版 \(v)（点击下载）"
        } else {
            updateItem.title = "检查更新（当前 v\(currentVersion)）"
        }
    }

    @objc private func checkForUpdatesManual() {
        // 已知有新版：直接打开下载页
        if availableNewVersion != nil {
            if let url = URL(string: releasesPageURL) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        // 否则发起一次检查（带提示）
        updateItem.title = "检查中…"
        checkForUpdates(silent: false)
    }

    private func checkForUpdates(silent: Bool) {
        // 用 releases.atom 而不是 API，避免匿名限流（60次/小时）
        let feed = "https://github.com/\(githubOwner)/\(githubRepo)/releases.atom"
        guard let url = URL(string: feed) else { return }
        var req = URLRequest(url: url)
        req.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let data = data,
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8),
                      let tag = self.parseLatestTag(fromAtom: text) else {
                    if !silent {
                        self.showAlert(title: "检查失败",
                                       text: "无法连接 GitHub，稍后再试。")
                    }
                    self.refreshUpdateItem()
                    return
                }
                let latest = self.normalize(tag)
                let current = self.normalize(self.currentVersion)
                if self.compareVersions(latest, current) > 0 {
                    self.availableNewVersion = "v\(latest)"
                    self.refreshUpdateItem()
                    if !silent {
                        self.showAlert(title: "发现新版本 v\(latest)",
                                       text: "你当前 v\(current)。点击菜单中的「⬆️ 发现新版」可打开下载页。")
                    }
                } else {
                    self.availableNewVersion = nil
                    self.refreshUpdateItem()
                    if !silent {
                        self.showAlert(title: "已是最新版本",
                                       text: "当前 v\(current)。")
                    }
                }
            }
        }.resume()
    }

    /// 从 atom feed 里抓第一个 <title>vX.Y.Z</title>（跳过 feed 自身的标题）
    private func parseLatestTag(fromAtom xml: String) -> String? {
        // feed 结构：<feed>...<title>Release notes from WeTime</title>...<entry><title>v1.0.0</title>...
        // 取第一个 <entry> 里的 <title>
        guard let entryRange = xml.range(of: "<entry>") else { return nil }
        let after = xml[entryRange.upperBound...]
        guard let openTag = after.range(of: "<title>"),
              let closeTag = after.range(of: "</title>") else { return nil }
        let title = after[openTag.upperBound..<closeTag.lowerBound]
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ s: String) -> String {
        s.hasPrefix("v") ? String(s.dropFirst()) : s
    }

    /// 简单的语义版本比较：1.2.3 vs 1.2.10
    private func compareVersions(_ a: String, _ b: String) -> Int {
        let A = a.split(separator: ".").map { Int($0) ?? 0 }
        let B = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(A.count, B.count)
        for i in 0..<n {
            let x = i < A.count ? A[i] : 0
            let y = i < B.count ? B[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
