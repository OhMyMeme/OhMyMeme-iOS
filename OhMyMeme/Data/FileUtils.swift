import Foundation
import CryptoKit

enum FileUtils {
    static let allowedExt = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"]

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 读取文件头魔数识别真实扩展名（与桌面端 adb_util._QQ_FILE_TYPES 一致）
    static func detectExt(_ head: Data) -> String {
        let bytes = [UInt8](head)
        let matches: ([UInt8]) -> Bool = { prefix in
            guard bytes.count >= prefix.count else { return false }
            return Array(bytes[0..<prefix.count]) == prefix
        }
        if matches([0x89, 0x50, 0x4E, 0x47]) { return ".png" }
        if matches([0xFF, 0xD8]) { return ".jpg" }
        if matches(Array("GIF87a".utf8)) || matches(Array("GIF89a".utf8)) { return ".gif" }
        if matches(Array("RIFF".utf8)) {
            if bytes.count >= 12,
               let s = String(data: Data(bytes[8..<12]), encoding: .ascii),
               s == "WEBP" {
                return ".webp"
            }
        }
        if matches(Array("BM".utf8)) { return ".bmp" }
        return ""
    }

    /// 对应桌面端 _is_animated：GIF89a 为动图；WebP 头含 ANIM chunk 为动图
    static func isAnimated(_ data: Data) -> Bool {
        let d = data.prefix(50)
        let bytes = [UInt8](d)
        if bytes.count >= 6, String(data: d.prefix(6), encoding: .ascii) == "GIF89a" {
            return true
        }
        if bytes.count >= 12,
           String(data: d.prefix(4), encoding: .ascii) == "RIFF",
           String(data: d.subdata(in: 8..<12), encoding: .ascii) == "WEBP" {
            return String(data: d, encoding: .ascii)?.contains("ANIM") ?? false
        }
        return false
    }

    static func isAnimated(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return isAnimated(handle.readData(ofLength: 50))
    }

    static func ext(fromName name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        return e.isEmpty ? "" : ".\(e)"
    }

    static func stem(fromName name: String) -> String {
        (name as NSString).deletingPathExtension
    }
}