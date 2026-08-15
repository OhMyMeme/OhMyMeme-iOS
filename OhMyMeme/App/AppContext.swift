import Foundation

extension Notification.Name {
    static let configChanged = Notification.Name("OhMyMeme.configChanged")
    static let dataChanged = Notification.Name("OhMyMeme.dataChanged")
}

/// 应用级共享上下文：单线程后台队列跑数据库 / IO，UI 更新回主线程
final class AppContext {
    static let shared = AppContext()

    let queue = DispatchQueue(label: "com.ohmymeme.app.worker")
    let db: MemeDb
    let config: ConfigStore

    private init() {
        db = MemeDb(path: StoragePaths.dbPath.path)
        config = ConfigStore.shared
    }
}