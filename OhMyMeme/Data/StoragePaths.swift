import Foundation

enum StoragePaths {
    private static let fm = FileManager.default

    private static var documents: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 配置文件根目录：Documents/（对应桌面端 %APPDATA%/OhMyMeme）
    static var configRoot: URL {
        documents
    }

    /// 配置文件：Documents/config.json
    static var configFile: URL {
        documents.appendingPathComponent("config.json")
    }

    /// 本地数据目录：Documents/data/（对应桌面端 %LOCALAPPDATA%/OhMyMeme）
    static var dataDir: URL {
        let url = documents.appendingPathComponent("data", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 原图缓存目录
    static var cacheDir: URL {
        let url = dataDir.appendingPathComponent("cache", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 缩略图目录
    static var thumbnailDir: URL {
        let url = dataDir.appendingPathComponent("thumbnails", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 数据库文件
    static var dbPath: URL {
        dataDir.appendingPathComponent("memes.db")
    }
}