import Foundation

final class ConfigStore {
    static let shared = ConfigStore()

    /// 与桌面端 config.py DEFAULTS 对齐
    private static let defaults: [String: Any] = [
        "version": "",
        "hotkey": "Ctrl+Alt+N",
        "hotkey_show_at_mouse": false,
        "auto_start": false,
        "silent_start": false,
        "language": "zh-CN",
        "cache_max_size_mb": 500,
        "thumbnail_size": 150,
        "cache_dir": "",
        "sync_auto_fetch_index": false,
        "sync_auto_sync": false,
        "sync_type": "",
        "sync_interval_minutes": 60,
        "sync_delete_remote": false,
        "sync_remove_local": false,
        "sync_hide_upload_warning": false,
        "sync_threads": 3,
        "show_upload_progress": true,
        "show_upload_done": true,
        "show_download_progress": true,
        "show_download_done": true,
        "ftp_host": "",
        "ftp_port": 21,
        "ftp_user": "",
        "ftp_password": "",
        "ftp_path": "/",
        "s3_endpoint": "",
        "s3_region": "",
        "s3_bucket": "",
        "s3_access_key": "",
        "s3_secret_key": "",
        "s3_path": "",
        "s3_addressing_style": "virtual",
        "r2_account_id": "",
        "r2_access_key_id": "",
        "r2_secret_access_key": "",
        "r2_bucket": "",
        "r2_path": "",
        "webdav_url": "",
        "webdav_user": "",
        "webdav_password": "",
        "webdav_path": "",
        "webdav_timeout": 30,
        "copy_resize_mode": 1,
        "copy_resize_max": 200,
        "lan_port": 17852,
        "lan_secret": "",
        "tg_tdata_path": "",
        "theme": "dark",
        "window_x": -1,
        "window_y": -1,
        "auto_play_gif": true,
        "hover_to_play": false,
        "try_original_image": false,
        "show_uncategorized": true,
        "record_recent_use": true
    ]

    private static let secretKeys: Set<String> = [
        "s3_access_key",
        "s3_secret_key",
        "r2_access_key_id",
        "r2_secret_access_key",
        "ftp_password",
        "webdav_password",
        "lan_secret"
    ]

    private var data: [String: Any]
    private let lock = NSLock()

    private init() {
        data = Self.defaults
        load()
    }

    func value(_ key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return data[key]
    }

    func string(_ key: String) -> String {
        (value(key) as? String) ?? ""
    }

    func int(_ key: String) -> Int {
        (value(key) as? Int) ?? 0
    }

    func bool(_ key: String) -> Bool {
        (value(key) as? Bool) ?? false
    }

    func set(_ key: String, _ value: Any) {
        lock.lock()
        data[key] = value
        lock.unlock()
    }

    func reset() {
        lock.lock()
        data = Self.defaults
        lock.unlock()
        save()
    }

    func save() {
        lock.lock()
        var copy: [String: Any] = [:]
        for (k, v) in data {
            if Self.secretKeys.contains(k), let s = v as? String, !s.isEmpty {
                copy[k] = CryptoUtil.encrypt(s)
            } else {
                copy[k] = v
            }
        }
        lock.unlock()
        let file = StoragePaths.configFile
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard JSONSerialization.isValidJSONObject(copy),
              let json = try? JSONSerialization.data(withJSONObject: copy, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? json.write(to: file)
    }

    private func load() {
        let file = StoragePaths.configFile
        guard FileManager.default.fileExists(atPath: file.path),
              let jsonData = try? Data(contentsOf: file),
              let raw = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            save()
            return
        }
        lock.lock()
        for (k, v) in Self.defaults {
            if let rv = raw[k] {
                data[k] = rv
            }
        }
        for k in Self.secretKeys {
            if let s = data[k] as? String, !s.isEmpty {
                data[k] = CryptoUtil.decrypt(s)
            }
        }
        lock.unlock()
    }
}