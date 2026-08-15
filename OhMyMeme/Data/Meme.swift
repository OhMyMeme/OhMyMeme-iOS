import Foundation

struct Meme {
    let id: Int64
    let filename: String
    let fileHash: String
    let originalName: String
    let width: Int
    let height: Int
    let fileSize: Int64
    let mimeType: String
    let sortOrder: Int
    let stegoOfHash: String?
    let fromStego: Int
    let createdAt: String
    let updatedAt: String

    /// 显示名：original_name 优先，为空回退文件名去扩展名（与桌面端一致）
    var displayName: String {
        !originalName.isEmpty ? originalName : FileUtils.stem(fromName: filename)
    }

    init(
        id: Int64,
        filename: String,
        fileHash: String,
        originalName: String,
        width: Int,
        height: Int,
        fileSize: Int64,
        mimeType: String,
        sortOrder: Int,
        stegoOfHash: String?,
        fromStego: Int,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.filename = filename
        self.fileHash = fileHash
        self.originalName = originalName
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.sortOrder = sortOrder
        self.stegoOfHash = stegoOfHash
        self.fromStego = fromStego
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(row: [String: Any]) {
        self.init(
            id: (row["id"] as? Int).map(Int64.init) ?? 0,
            filename: (row["filename"] as? String) ?? "",
            fileHash: (row["file_hash"] as? String) ?? "",
            originalName: (row["original_name"] as? String) ?? "",
            width: (row["width"] as? Int) ?? 0,
            height: (row["height"] as? Int) ?? 0,
            fileSize: (row["file_size"] as? Int).map(Int64.init) ?? 0,
            mimeType: (row["mime_type"] as? String) ?? "image/png",
            sortOrder: (row["sort_order"] as? Int) ?? 0,
            stegoOfHash: row["stego_of_hash"] as? String,
            fromStego: (row["from_stego"] as? Int) ?? 0,
            createdAt: (row["created_at"] as? String) ?? "",
            updatedAt: (row["updated_at"] as? String) ?? ""
        )
    }
}