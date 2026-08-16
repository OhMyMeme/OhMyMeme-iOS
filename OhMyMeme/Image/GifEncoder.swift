import Foundation

/// 最小 GIF 编码器：median cut 量化到 256 色 + LZW 压缩，输出单帧 GIF89a。
/// 对应桌面端 gif_stego.py make_stego_gif / clipboard_util.py _static_to_gif 中
/// Pillow convert("P", ADAPTIVE, 256).save(GIF) 的作用（与安卓端 GifEncoder.kt 逐字节一致）。
///
/// LZW 码长升位时机与 GifFrameDecoder.lzwDecode 严格对应（已验证与 Pillow 解码逐字节一致）：
/// 每新增一条目后 nextCode 达 (1 shl codeSize) + 1 时升位。
enum GifEncoder {

    /// 将 RGBA 像素编码为 GIF89a 字节（丢弃 alpha，仅量化 RGB）
    static func encode(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        let (palette, indices) = quantize(rgba, width, height)
        var out: [UInt8] = []
        out += Array("GIF89a".utf8)
        writeLE16(&out, width)
        writeLE16(&out, height)
        out.append(0x80 | 0x70 | 0x07) // 全局色板、8 位分辨率、2^(7+1)=256 色
        out.append(0) // 背景色索引
        out.append(0) // 宽高比
        out += palette
        out.append(0x2C)
        writeLE16(&out, 0)
        writeLE16(&out, 0)
        writeLE16(&out, width)
        writeLE16(&out, height)
        out.append(0) // 无局部色板、无交织
        out.append(8) // 最小 LZW 码长
        let lzw = lzwEncode(indices)
        var i = 0
        while i < lzw.count {
            let len = min(255, lzw.count - i)
            out.append(UInt8(len))
            out += Array(lzw[i..<(i + len)])
            i += len
        }
        out.append(0)
        out.append(0x3B)
        return out
    }

    private static func quantize(_ rgba: [UInt8], _ width: Int, _ height: Int) -> (palette: [UInt8], indices: [Int]) {
        let n = width * height
        var hist: [Int: Int] = [:]
        var pixels = [Int](repeating: 0, count: n)
        var s = 0
        for p in 0..<n {
            let r = Int(rgba[s]) & 0xFF
            let g = Int(rgba[s + 1]) & 0xFF
            let b = Int(rgba[s + 2]) & 0xFF
            s += 4
            let c = (r << 16) | (g << 8) | b
            pixels[p] = c
            hist[c, default: 0] += 1
        }
        if hist.count <= 256 {
            var palette = [UInt8](repeating: 0, count: 768)
            var map: [Int: Int] = [:]
            var idx = 0
            for (c, _) in hist {
                map[c] = idx
                palette[idx * 3] = UInt8((c >> 16) & 0xFF)
                palette[idx * 3 + 1] = UInt8((c >> 8) & 0xFF)
                palette[idx * 3 + 2] = UInt8(c & 0xFF)
                idx += 1
            }
            return (palette, pixels.map { map[$0] ?? 0 })
        }
        // median cut：按最长颜色通道中位数反复分裂到 <=256 盒
        var boxColors: [[Int]] = [Array(hist.keys)]
        var colorToBox: [Int: Int] = [:]
        for c in hist.keys { colorToBox[c] = 0 }
        while boxColors.count < 256 {
            var bestId = -1
            var bestScore: Int64 = -1
            for id in boxColors.indices {
                let list = boxColors[id]
                if list.count <= 1 { continue }
                var minR = 255; var maxR = 0
                var minG = 255; var maxG = 0
                var minB = 255; var maxB = 0
                for c in list {
                    let r = (c >> 16) & 0xFF
                    let g = (c >> 8) & 0xFF
                    let b = c & 0xFF
                    if r < minR { minR = r }
                    if r > maxR { maxR = r }
                    if g < minG { minG = g }
                    if g > maxG { maxG = g }
                    if b < minB { minB = b }
                    if b > maxB { maxB = b }
                }
                let score = Int64(max(maxR - minR, maxG - minG, maxB - minB)) * Int64(list.count)
                if score > bestScore {
                    bestScore = score
                    bestId = id
                }
            }
            if bestId == -1 { break }
            let list = boxColors[bestId]
            var minR = 255; var maxR = 0
            var minG = 255; var maxG = 0
            var minB = 255; var maxB = 0
            for c in list {
                let r = (c >> 16) & 0xFF
                let g = (c >> 8) & 0xFF
                let b = c & 0xFF
                if r < minR { minR = r }
                if r > maxR { maxR = r }
                if g < minG { minG = g }
                if g > maxG { maxG = g }
                if b < minB { minB = b }
                if b > maxB { maxB = b }
            }
            let spreadR = maxR - minR
            let spreadG = maxG - minG
            let spreadB = maxB - minB
            var sorted: [Int]
            if spreadR >= spreadG && spreadR >= spreadB {
                sorted = list.sorted { ($0 >> 16) & 0xFF < ($1 >> 16) & 0xFF }
            } else if spreadG >= spreadB {
                sorted = list.sorted { ($0 >> 8) & 0xFF < ($1 >> 8) & 0xFF }
            } else {
                sorted = list.sorted { $0 & 0xFF < $1 & 0xFF }
            }
            let mid = sorted.count / 2
            boxColors[bestId] = Array(sorted[0..<mid])
            let moved = Array(sorted[mid..<sorted.count])
            let newId = boxColors.count
            for c in moved { colorToBox[c] = newId }
            boxColors.append(moved)
        }
        var palette = [UInt8](repeating: 0, count: 768)
        for id in boxColors.indices {
            var sr: Int64 = 0; var sg: Int64 = 0; var sb: Int64 = 0; var sc: Int64 = 0
            for c in boxColors[id] {
                let cnt = Int64(hist[c] ?? 0)
                sr += Int64((c >> 16) & 0xFF) * cnt
                sg += Int64((c >> 8) & 0xFF) * cnt
                sb += Int64(c & 0xFF) * cnt
                sc += cnt
            }
            palette[id * 3] = UInt8(sr / sc)
            palette[id * 3 + 1] = UInt8(sg / sc)
            palette[id * 3 + 2] = UInt8(sb / sc)
        }
        return (palette, pixels.map { colorToBox[$0] ?? 0 })
    }

    /// GIF LZW 编码：LSB-first，clear/end 各占 1 码，码长升位时机与 GifFrameDecoder 一致
    private static func lzwEncode(_ indices: [Int]) -> [UInt8] {
        let clear = 256
        let end = 257
        var nextCode = 258
        var codeSize = 9
        var dict: [Int: Int] = [:]
        var out: [UInt8] = []
        var acc = 0
        var nbits = 0
        func emit(_ code: Int) {
            acc = acc | (code << nbits)
            nbits += codeSize
            while nbits >= 8 {
                out.append(UInt8(acc & 0xFF))
                acc = acc >> 8
                nbits -= 8
            }
        }
        emit(clear)
        if indices.isEmpty {
            emit(end)
        } else {
            var prefix = indices[0]
            for i in 1..<indices.count {
                let k = indices[i]
                let key = (prefix << 8) | k
                if let existing = dict[key] {
                    prefix = existing
                } else {
                    emit(prefix)
                    if nextCode < 4096 {
                        dict[key] = nextCode
                        nextCode += 1
                        if nextCode == (1 << codeSize) + 1 && codeSize < 12 { codeSize += 1 }
                    }
                    prefix = k
                }
            }
            emit(prefix)
            emit(end)
        }
        if nbits > 0 { out.append(UInt8(acc & 0xFF)) }
        return out
    }

    private static func writeLE16(_ out: inout [UInt8], _ v: Int) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
    }
}