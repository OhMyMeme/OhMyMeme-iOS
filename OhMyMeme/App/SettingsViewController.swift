import UIKit

final class SettingsViewController: UITableViewController {

    private enum RowKind {
        case autoPlayGif, showUncategorized, copyMode, storage, clearAll, version, lanSync, checkUpdate, cloudSync
    }

    private struct Section {
        let title: String?
        let rows: [(RowKind, String)]
    }

    private let config = AppContext.shared.config
    private var sections: [Section] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
        )
        let navBar = navigationController?.navigationBar
        navBar?.barStyle = .black
        navBar?.titleTextAttributes = [.foregroundColor: UIColor.white]
        navBar?.tintColor = UIColor(hex: 0x3B82F6)
        view.backgroundColor = UIColor(hex: 0x0D0D0F)
        tableView.backgroundColor = UIColor(hex: 0x0D0D0F)
        tableView.separatorColor = UIColor(hex: 0x27272A)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")

        sections = [
            Section(title: "表情显示", rows: [
                (.autoPlayGif, "动图自动播放"),
                (.showUncategorized, "显示「未分类」分组")
            ]),
            Section(title: "复制处理", rows: [
                (.copyMode, "复制处理模式")
            ]),
            Section(title: "局域网互联", rows: [
                (.lanSync, "同步电脑表情")
            ]),
            Section(title: "云端同步", rows: [
                (.cloudSync, "云端同步配置与操作")
            ]),
            Section(title: "存储", rows: [
                (.storage, "数据位置")
            ]),
            Section(title: "危险操作", rows: [
                (.clearAll, "清空本地全部数据")
            ]),
            Section(title: "关于", rows: [
                (.checkUpdate, "检查更新"),
                (.version, "版本")
            ])
        ]
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        if let header = view as? UITableViewHeaderFooterView {
            header.textLabel?.textColor = UIColor(hex: 0x71717A)
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.backgroundColor = UIColor(hex: 0x1E1E22)
        cell.textLabel?.textColor = .white
        cell.detailTextLabel?.textColor = UIColor(hex: 0x9CA3AF)
        cell.detailTextLabel?.numberOfLines = 2
        cell.accessoryView = nil
        cell.accessoryType = .none

        let (kind, title) = sections[indexPath.section].rows[indexPath.row]
        cell.textLabel?.text = title
        switch kind {
        case .autoPlayGif:
            cell.accessoryView = makeSwitch(value: config.bool("auto_play_gif")) { [weak self] on in
                self?.config.set("auto_play_gif", on)
                self?.config.save()
                NotificationCenter.default.post(name: .configChanged, object: nil)
            }
        case .showUncategorized:
            cell.accessoryView = makeSwitch(value: config.bool("show_uncategorized")) { [weak self] on in
                self?.config.set("show_uncategorized", on)
                self?.config.save()
                NotificationCenter.default.post(name: .configChanged, object: nil)
            }
        case .copyMode:
            cell.detailTextLabel?.text = copyModeName(config.int("copy_resize_mode"))
            cell.accessoryType = .disclosureIndicator
        case .lanSync:
            cell.detailTextLabel?.text = "扫描电脑 → 拉取/推送"
            cell.accessoryType = .disclosureIndicator
        case .cloudSync:
            cell.detailTextLabel?.text = "类型：\(syncTypeName())"
            cell.accessoryType = .disclosureIndicator
        case .storage:
            cell.detailTextLabel?.text = StoragePaths.dataDir.path
        case .clearAll:
            cell.textLabel?.textColor = UIColor(hex: 0xEF4444)
        case .checkUpdate:
            cell.accessoryType = .disclosureIndicator
        case .version:
            cell.detailTextLabel?.text = versionString
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let kind = sections[indexPath.section].rows[indexPath.row].0
        switch kind {
        case .copyMode:
            showCopyModePicker()
        case .lanSync:
            startLanSync()
        case .cloudSync:
            startCloudSync()
        case .checkUpdate:
            checkForUpdate()
        case .clearAll:
            confirmClearAll()
        default:
            break
        }
    }

    // MARK: - 局域网互联

    private func startLanSync() {
        let ac = UIAlertController(title: "扫描局域网电脑", message: nil, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(ac, animated: true)
        AppContext.shared.queue.async { [weak self] in
            let peers = LanClient.discover()
            DispatchQueue.main.async {
                ac.dismiss(animated: true)
                guard let self else { return }
                if peers.isEmpty {
                    self.showAlert("未发现电脑", "请确认电脑端 OhMyMeme 已开启局域网服务（设置 → 局域网互联），且与本机在同一网络。")
                    return
                }
                self.pickPeer(peers)
            }
        }
    }

    private func pickPeer(_ peers: [LanClient.LanPeer]) {
        let ac = UIAlertController(title: "选择电脑", message: nil, preferredStyle: .actionSheet)
        for p in peers {
            let label = "\(p.name) (\(p.ip):\(p.port))" + (p.needSecret ? " 🔒" : "")
            ac.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                self?.askSecretIfNeeded(peer: p)
            })
        }
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.popoverPresentationController?.sourceView = view
        present(ac, animated: true)
    }

    private func askSecretIfNeeded(peer: LanClient.LanPeer) {
        if peer.needSecret {
            let ac = UIAlertController(title: "输入配对密钥", message: "\(peer.name) 开启了密钥保护。", preferredStyle: .alert)
            ac.addTextField { $0.placeholder = "配对密钥"; $0.isSecureTextEntry = true }
            ac.addAction(UIAlertAction(title: "取消", style: .cancel))
            ac.addAction(UIAlertAction(title: "连接", style: .default) { [weak self] _ in
                let secret = ac.textFields?.first?.text ?? ""
                self?.connectAndSync(peer: peer, secret: secret)
            })
            present(ac, animated: true)
        } else {
            connectAndSync(peer: peer, secret: "")
        }
    }

    private func connectAndSync(peer: LanClient.LanPeer, secret: String) {
        let ac = UIAlertController(title: "正在连接 \(peer.name)…", message: nil, preferredStyle: .alert)
        present(ac, animated: true)
        AppContext.shared.queue.async { [weak self] in
            let conn = try? LanClient.connect(ip: peer.ip, port: peer.port, secret: secret)
            DispatchQueue.main.async {
                ac.dismiss(animated: true)
                guard let self else { return }
                guard let conn else {
                    self.showAlert("连接失败", "无法连接 \(peer.name)，请检查电脑端是否运行。")
                    return
                }
                self.showSyncMenu(conn: conn)
            }
        }
    }

    private func showSyncMenu(conn: LanClient.LanConnection) {
        let ac = UIAlertController(title: "选择操作", message: nil, preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "拉取表情到手机", style: .default) { [weak self] _ in
            self?.runSync(conn: conn, direction: .pull)
        })
        ac.addAction(UIAlertAction(title: "推送表情到电脑", style: .default) { [weak self] _ in
            self?.runSync(conn: conn, direction: .push)
        })
        ac.addAction(UIAlertAction(title: "关闭", style: .cancel) { _ in conn.close() })
        ac.popoverPresentationController?.sourceView = view
        present(ac, animated: true)
    }

    private enum SyncDirection { case pull, push }

    private func runSync(conn: LanClient.LanConnection, direction: SyncDirection) {
        let ac = UIAlertController(
            title: direction == .pull ? "正在拉取…" : "正在推送…",
            message: nil,
            preferredStyle: .alert
        )
        present(ac, animated: true)
        AppContext.shared.queue.async { [weak self] in
            let result: LanClient.LanResult
            do {
                switch direction {
                case .pull:
                    result = try LanClient.pull(db: AppContext.shared.db, conn: conn)
                case .push:
                    result = try LanClient.push(db: AppContext.shared.db, conn: conn)
                }
            } catch {
                DispatchQueue.main.async {
                    ac.dismiss(animated: true)
                    conn.close()
                    self?.showAlert("同步失败", "\(error)")
                }
                return
            }
            DispatchQueue.main.async {
                ac.dismiss(animated: true)
                conn.close()
                guard let self else { return }
                let summary = direction == .pull
                    ? "已拉取 \(result.pulled) 个，跳过 \(result.skipped) 个，失败 \(result.errors) 个"
                    : "已推送 \(result.pushed) 个，跳过 \(result.skipped) 个，失败 \(result.errors) 个"
                var msg = summary
                if !result.failed.isEmpty {
                    msg += "\n\n失败文件：\n" + result.failed.prefix(5).joined(separator: "\n")
                }
                self.showAlert("同步完成", msg)
                NotificationCenter.default.post(name: .dataChanged, object: nil)
            }
        }
    }

    // MARK: - 云端同步

    private func syncTypeName() -> String {
        switch config.string("sync_type") {
        case "ftp": return "FTP"
        case "s3": return "S3"
        case "r2": return "Cloudflare R2"
        case "webdav": return "WebDAV"
        default: return "未配置"
        }
    }

    private func startCloudSync() {
        let ac = UIAlertController(title: "云端同步", message: "存储类型：\(syncTypeName())", preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "配置存储", style: .default) { [weak self] _ in
            self?.pickSyncType()
        })
        ac.addAction(UIAlertAction(title: "测试连接", style: .default) { [weak self] _ in
            self?.runCloudTest()
        })
        ac.addAction(UIAlertAction(title: "查看同步状态", style: .default) { [weak self] _ in
            self?.runCloudStatus()
        })
        ac.addAction(UIAlertAction(title: "推送表情到云端", style: .default) { [weak self] _ in
            self?.runCloudSync(.push)
        })
        ac.addAction(UIAlertAction(title: "从云端拉取表情", style: .default) { [weak self] _ in
            self?.runCloudSync(.pull)
        })
        ac.addAction(UIAlertAction(title: "清理远端孤儿文件", style: .default) { [weak self] _ in
            self?.runCleanupOrphans()
        })
        ac.addAction(UIAlertAction(title: "删除远端全部数据", style: .destructive) { [weak self] _ in
            self?.confirmDeleteAllRemote()
        })
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.popoverPresentationController?.sourceView = view
        present(ac, animated: true)
    }

    private func pickSyncType() {
        let ac = UIAlertController(title: "选择存储类型", message: nil, preferredStyle: .actionSheet)
        let options: [(String, String)] = [
            ("ftp", "FTP"),
            ("s3", "S3"),
            ("r2", "Cloudflare R2"),
            ("webdav", "WebDAV")
        ]
        for (type, name) in options {
            ac.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                guard let self else { return }
                self.config.set("sync_type", type)
                self.config.save()
                self.presentSyncConfig(for: type)
            })
        }
        ac.addAction(UIAlertAction(title: "不使用", style: .default) { [weak self] _ in
            self?.config.set("sync_type", "")
            self?.config.save()
        })
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.popoverPresentationController?.sourceView = view
        present(ac, animated: true)
    }

    private func presentSyncConfig(for type: String) {
        switch type {
        case "ftp":
            presentSyncConfig([
                (key: "ftp_host", placeholder: "FTP 服务器地址", secure: false),
                (key: "ftp_port", placeholder: "端口（默认 21）", secure: false),
                (key: "ftp_user", placeholder: "用户名", secure: false),
                (key: "ftp_password", placeholder: "密码", secure: true),
                (key: "ftp_path", placeholder: "远端路径（默认 /）", secure: false)
            ], title: "FTP 配置")
        case "s3":
            presentSyncConfig([
                (key: "s3_endpoint", placeholder: "Endpoint（如 https://s3.amazonaws.com）", secure: false),
                (key: "s3_region", placeholder: "Region（如 us-east-1）", secure: false),
                (key: "s3_bucket", placeholder: "Bucket", secure: false),
                (key: "s3_access_key", placeholder: "Access Key", secure: false),
                (key: "s3_secret_key", placeholder: "Secret Key", secure: true),
                (key: "s3_path", placeholder: "前缀路径（可选）", secure: false)
            ], title: "S3 配置")
        case "r2":
            presentSyncConfig([
                (key: "r2_account_id", placeholder: "Account ID", secure: false),
                (key: "r2_access_key_id", placeholder: "Access Key ID", secure: false),
                (key: "r2_secret_access_key", placeholder: "Secret Access Key", secure: true),
                (key: "r2_bucket", placeholder: "Bucket", secure: false),
                (key: "r2_path", placeholder: "前缀路径（可选）", secure: false)
            ], title: "Cloudflare R2 配置")
        case "webdav":
            presentSyncConfig([
                (key: "webdav_url", placeholder: "WebDAV 地址（http(s)://）", secure: false),
                (key: "webdav_user", placeholder: "用户名", secure: false),
                (key: "webdav_password", placeholder: "密码", secure: true),
                (key: "webdav_path", placeholder: "远端路径（可选）", secure: false),
                (key: "webdav_timeout", placeholder: "超时秒数（默认 30）", secure: false)
            ], title: "WebDAV 配置")
        default:
            break
        }
    }

    private func presentSyncConfig(_ fields: [(key: String, placeholder: String, secure: Bool)], title: String) {
        let ac = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for f in fields {
            ac.addTextField { tf in
                tf.placeholder = f.placeholder
                tf.isSecureTextEntry = f.secure
                tf.text = self.config.string(f.key)
                tf.autocapitalizationType = .none
                tf.autocorrectionType = .no
            }
        }
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            guard let self else { return }
            for (i, f) in fields.enumerated() {
                let val = ac.textFields?[i].text ?? ""
                if f.key == "ftp_port" || f.key == "webdav_timeout" {
                    self.config.set(f.key, Int(val) ?? 0)
                } else {
                    self.config.set(f.key, val)
                }
            }
            self.config.save()
        })
        present(ac, animated: true)
    }

    private func runCloudTest() {
        let ac = UIAlertController(title: "正在测试连接…", message: nil, preferredStyle: .alert)
        present(ac, animated: true)
        AppContext.shared.queue.async { [weak self] in
            let result = CloudSync.syncTest()
            DispatchQueue.main.async {
                ac.dismiss(animated: true)
                guard let self else { return }
                if result == "ok" {
                    self.showAlert("连接成功", "云端存储连接正常。")
                } else {
                    self.showAlert("连接失败", result)
                }
            }
        }
    }

    private func runCloudStatus() {
        let ac = UIAlertController(title: "正在获取状态…", message: nil, preferredStyle: .alert)
        present(ac, animated: true)
        AppContext.shared.queue.async { [weak self] in
            let status = CloudSync.checkSyncStatus(db: AppContext.shared.db)
            DispatchQueue.main.async {
                ac.dismiss(animated: true)
                self?.showAlert("同步状态", status)
            }
        }
    }

    private enum CloudDirection { case push, pull }

    private func runCloudSync(_ direction: CloudDirection) {
        let title = direction == .push ? "正在推送…" : "正在拉取…"
        let ac = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        present(ac, animated: true)
        AppContext.shared.queue.async { [weak self] in
            let result: CloudSync.SyncResult
            do {
                switch direction {
                case .push:
                    result = try CloudSync.push(db: AppContext.shared.db)
                case .pull:
                    result = try CloudSync.pull(db: AppContext.shared.db)
                }
            } catch {
                DispatchQueue.main.async {
                    ac.dismiss(animated: true)
                    self?.showAlert("同步失败", "\(error)")
                }
                return
            }
            DispatchQueue.main.async {
                ac.dismiss(animated: true)
                guard let self else { return }
                let summary = direction == .push
                    ? "已推送 \(result.uploaded) 个，跳过 \(result.skipped) 个，删除远端 \(result.deleted) 个，失败 \(result.errors) 个"
                    : "已下载 \(result.downloaded) 个，跳过 \(result.skipped) 个，删除本地 \(result.removedLocal) 个，失败 \(result.errors) 个"
                var msg = summary
                if !result.failed.isEmpty {
                    msg += "\n\n失败文件：\n" + result.failed.prefix(5).joined(separator: "\n")
                }
                self.showAlert("同步完成", msg)
                NotificationCenter.default.post(name: .dataChanged, object: nil)
            }
        }
    }

    private func runCleanupOrphans() {
        let ac = UIAlertController(title: "正在清理孤儿文件…", message: nil, preferredStyle: .alert)
        present(ac, animated: true)
        AppContext.shared.queue.async { [weak self] in
            let (ok, msg) = CloudSync.cleanupRemoteOrphans(delete: true)
            DispatchQueue.main.async {
                ac.dismiss(animated: true)
                self?.showAlert(ok ? "清理完成" : "清理失败", msg)
            }
        }
    }

    private func confirmDeleteAllRemote() {
        let ac = UIAlertController(
            title: "删除远端全部数据",
            message: "将删除远端所有表情包与清单，此操作不可恢复。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "继续", style: .destructive) { [weak self] _ in
            let ac2 = UIAlertController(title: "二次确认", message: "确定删除云端全部数据吗？", preferredStyle: .alert)
            ac2.addAction(UIAlertAction(title: "取消", style: .cancel))
            ac2.addAction(UIAlertAction(title: "确认删除", style: .destructive) { _ in
                self?.performDeleteAllRemote()
            })
            self?.present(ac2, animated: true)
        })
        present(ac, animated: true)
    }

    private func performDeleteAllRemote() {
        let ac = UIAlertController(title: "正在删除…", message: nil, preferredStyle: .alert)
        present(ac, animated: true)
        AppContext.shared.queue.async { [weak self] in
            let (ok, msg) = CloudSync.deleteAllRemote()
            DispatchQueue.main.async {
                ac.dismiss(animated: true)
                self?.showAlert(ok ? "删除完成" : "删除失败", msg)
            }
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let ac = UIAlertController(title: title, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "好", style: .default))
        present(ac, animated: true)
    }

    private func checkForUpdate() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let ac = UIAlertController(title: "正在检查更新…", message: nil, preferredStyle: .alert)
        present(ac, animated: true)
        AppContext.shared.queue.async { [weak self] in
            let info = UpdateChecker.checkLatest(currentVersion: current)
            DispatchQueue.main.async {
                ac.dismiss(animated: true)
                guard let self else { return }
                if !info.error.isEmpty {
                    self.showAlert("检查更新失败", info.error)
                    return
                }
                if !info.hasUpdate {
                    self.showAlert("已是最新版本", "当前版本 \(current)，最新版本 \(info.latest)。")
                    return
                }
                let message = info.notes.isEmpty ? "最新版本：\(info.latest)" : "最新版本：\(info.latest)\n\n\(info.notes)"
                let alert = UIAlertController(title: "发现新版本", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                alert.addAction(UIAlertAction(title: "去下载", style: .default) { _ in
                    let urlStr = UpdateChecker.mirrorDownloadUrl(info.downloadUrl)
                    if let url = URL(string: urlStr) {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                })
                self.present(alert, animated: true)
            }
        }
    }

    // MARK: - helpers

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    private func makeSwitch(value: Bool, handler: @escaping (Bool) -> Void) -> UISwitch {
        let sw = UISwitch()
        sw.isOn = value
        sw.onTintColor = UIColor(hex: 0x3B82F6)
        sw.addAction(UIAction { _ in handler(sw.isOn) }, for: .valueChanged)
        return sw
    }

    private func copyModeName(_ mode: Int) -> String {
        let names = ["不处理", "WebP 缩放", "转 GIF", "转 GIF 隐写原图"]
        guard mode >= 0, mode < names.count else { return names[0] }
        return names[mode]
    }

    private func showCopyModePicker() {
        let names = ["不处理", "WebP 缩放", "转 GIF", "转 GIF 隐写原图"]
        let current = config.int("copy_resize_mode")
        let ac = UIAlertController(title: "复制处理模式", message: nil, preferredStyle: .actionSheet)
        for (i, name) in names.enumerated() {
            ac.addAction(UIAlertAction(title: i == current ? "✓ \(name)" : name, style: .default) { [weak self] _ in
                self?.config.set("copy_resize_mode", i)
                self?.config.save()
                self?.tableView.reloadData()
            })
        }
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.popoverPresentationController?.sourceView = view
        present(ac, animated: true)
    }

    private func confirmClearAll() {
        let ac = UIAlertController(
            title: "清空本地全部数据",
            message: "将删除全部表情包、分组及相关数据，此操作不可恢复。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "继续", style: .destructive) { [weak self] _ in
            self?.confirmClearAllFinal()
        })
        present(ac, animated: true)
    }

    private func confirmClearAllFinal() {
        let ac = UIAlertController(
            title: "二次确认",
            message: "确定要清空本地全部表情包与数据吗？",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "确认清空", style: .destructive) { [weak self] _ in
            self?.performClearAll()
        })
        present(ac, animated: true)
    }

    private func performClearAll() {
        AppContext.shared.queue.async {
            AppContext.shared.db.deleteAll()
            let fm = FileManager.default
            try? fm.removeItem(at: StoragePaths.cacheDir)
            try? fm.removeItem(at: StoragePaths.thumbnailDir)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .dataChanged, object: nil)
            }
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(version) (\(build))"
    }
}