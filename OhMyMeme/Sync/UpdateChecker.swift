import Foundation

/// 版本更新检查（GitHub Releases，对齐桌面端 updater.py 与安卓端 UpdateChecker.kt）
enum UpdateChecker {

    struct UpdateInfo {
        let latest: String
        let downloadUrl: String
        let notes: String
        let hasUpdate: Bool
        let error: String
    }

    struct UpdateError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        init(_ message: String) { self.message = message }
    }

    private static let repo = "OhMyMeme/OhMyMeme-iOS"
    private static let githubLatest = "https://api.github.com/repos/\(repo)/releases/latest"
    private static let githubList = "https://api.github.com/repos/\(repo)/releases?per_page=5"

    private static let ua =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static let ghMirrors = [
        "https://github.dpik.top/",
        "https://gh.dpik.top/",
        "https://gh-proxy.org/",
        "https://proxy.starsfire.top/-----"
    ]

    /// 解析版本号，保留前导数字段（如 "v1.2.3-beta" → [1,2,3]）
    static func parseVersion(_ v: String) -> [Int] {
        let trimmed = v.trimmingCharacters(in: .whitespaces)
        var parts = trimmed
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            parts = String(trimmed.dropFirst())
        }
        return parts.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func compareVersions(_ a: [Int], _ b: [Int]) -> Int {
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = a.indices.contains(i) ? a[i] : 0
            let y = b.indices.contains(i) ? b[i] : 0
            if x != y { return x - y }
        }
        return 0
    }

    /// 阻塞调用，须在后台线程执行
    static func checkLatest(currentVersion: String) -> UpdateInfo {
        let current = parseVersion(currentVersion)
        do {
            let (tag, url, notes) = try fetchLatest()
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            return UpdateInfo(
                latest: latest,
                downloadUrl: url,
                notes: notes,
                hasUpdate: compareVersions(parseVersion(latest), current) > 0,
                error: ""
            )
        } catch {
            return UpdateInfo(
                latest: "", downloadUrl: "", notes: "",
                hasUpdate: false, error: "无法连接到 GitHub，请检查网络设置"
            )
        }
    }

    /// 依次探测镜像源，返回第一个可访问的下载地址；全部失败回退直连。
    static func mirrorDownloadUrl(_ url: String) -> String {
        if url.isEmpty || !url.hasPrefix("https://github.com/") { return url }
        for mirror in ghMirrors {
            if reachable(mirror + url) { return mirror + url }
        }
        return url
    }

    // MARK: - 内部实现

    /// 对齐桌面端 check_latest：先 releases/latest，失败回退 releases 列表取最高稳定版本
    private static func fetchLatest() throws -> (tag: String, url: String, notes: String) {
        do {
            return try parseRelease(fetchFirst(githubLatest))
        } catch {
            // 任何失败（含 403/404）均回落至列表
        }
        return try pickHighestFromList(fetchFirst(githubList))
    }

    /// 并发尝试所有镜像+直连，返回第一个成功响应体（对齐桌面端 _urlopen_mirror）
    private static func fetchFirst(_ url: String) throws -> String {
        let targets = ghMirrors.map { $0 + url } + [url]
        let lock = NSLock()
        let sem = DispatchSemaphore(value: 0)
        var done = false
        var winner: String?
        var tasks: [URLSessionDataTask] = []

        for t in targets {
            guard let u = URL(string: t) else { continue }
            var request = URLRequest(url: u)
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            let task = URLSession.shared.dataTask(with: request) { data, resp, _ in
                lock.lock()
                if !done,
                   let http = resp as? HTTPURLResponse,
                   (200...399).contains(http.statusCode),
                   let data,
                   let text = String(data: data, encoding: .utf8) {
                    done = true
                    winner = text
                    sem.signal()
                }
                lock.unlock()
            }
            tasks.append(task)
        }
        for t in tasks { t.resume() }
        if sem.wait(timeout: .now() + 20) == .timedOut {
            tasks.forEach { $0.cancel() }
            throw UpdateError("无法连接到 GitHub")
        }
        tasks.forEach { $0.cancel() }
        lock.lock(); let w = winner; lock.unlock()
        return w ?? ""
    }

    private static func parseRelease(_ body: String) throws -> (tag: String, url: String, notes: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            throw UpdateError("JSON 解析失败")
        }
        let tag = json["tag_name"] as? String ?? ""
        if tag.isEmpty { throw UpdateError("no tag_name") }
        let html = json["html_url"] as? String ?? ""
        let notes = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = pickIpaUrl(json["assets"] as? [[String: Any]] ?? [])
        return (tag, picked.isEmpty ? html : picked, notes)
    }

    private static func pickHighestFromList(_ body: String) throws -> (tag: String, url: String, notes: String) {
        guard let arr = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [[String: Any]] else {
            throw UpdateError("JSON 解析失败")
        }
        var bestTag = ""
        var bestUrl = ""
        var bestNotes = ""
        var bestVer: [Int] = []
        for rel in arr {
            let tag = rel["tag_name"] as? String ?? ""
            if tag.isEmpty { continue }
            // 跳过预发布与非正式版，避免更新到不稳定版本
            if (rel["prerelease"] as? Bool) == true { continue }
            if tag.lowercased().contains("nightly") { continue }
            let ver = parseVersion(tag)
            if bestTag.isEmpty || compareVersions(ver, bestVer) > 0 {
                bestTag = tag
                bestVer = ver
                let html = rel["html_url"] as? String ?? ""
                let picked = pickIpaUrl(rel["assets"] as? [[String: Any]] ?? [])
                bestUrl = picked.isEmpty ? html : picked
                bestNotes = (rel["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if bestTag.isEmpty { throw UpdateError("no releases in list") }
        return (bestTag, bestUrl, bestNotes)
    }

    private static func pickIpaUrl(_ assets: [[String: Any]]) -> String {
        for a in assets {
            let name = a["name"] as? String ?? ""
            if name.hasSuffix(".ipa") {
                return a["browser_download_url"] as? String ?? ""
            }
        }
        return ""
    }

    private static func reachable(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                ok = true
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 10)
        task.cancel()
        return ok
    }
}