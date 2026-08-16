import Foundation

/// GIF 首帧像素解码结果
struct GifFrameResult {
    let width: Int
    let height: Int
    let rgb: [UInt8]
}

/// 最小 GIF 解码器：只渲染首个图像块为 RGB 像素。
/// 对应桌面端 gif_stego.py 的 _render_gif（Pillow 打开 GIF 后 convert）。
/// 透明索引不做 alpha 合成，直接映射调色板 RGB，与 Pillow 逐字节一致（与安卓端 GifFrameDecoder.kt 一致）。
enum GifFrameDecoder {

    static func decode(_ data: [UInt8]) -> GifFrameResult? {
        if data.count < 13 { return nil }
        guard isGifHeader(data) else { return nil }
        var pos = 6
        let width = max(le16(data, pos), 1)
        let height = max(le16(data, pos + 2), 1)
        let packed = Int(data[pos + 4]) & 0xFF
        let gctFlag = packed & 0x80 != 0
        let gctSize = 1 << ((packed & 0x07) + 1)
        pos += 7
        let globalPalette: [UInt8]? = gctFlag ? readPalette(data, pos, gctSize) : nil
        if globalPalette != nil { pos += gctSize * 3 }

        // 找到首个图像描述符
        while pos < data.count {
            switch Int(data[pos]) & 0xFF {
            case 0x21:
                pos += 2
                while pos < data.count && Int(data[pos]) != 0 {
                    let subLen = Int(data[pos]) & 0xFF
                    pos += 1 + subLen
                }
                pos += 1
            case 0x2C:
                let left = le16(data, pos + 1)
                let top = le16(data, pos + 3)
                let imgW = max(le16(data, pos + 5), 1)
                let imgH = max(le16(data, pos + 7), 1)
                let imgPacked = Int(data[pos + 9]) & 0xFF
                let lctFlag = imgPacked & 0x80 != 0
                let interlace = imgPacked & 0x40 != 0
                let lctSize = 1 << ((imgPacked & 0x07) + 1)
                pos += 10
                let palette = lctFlag ? readPalette(data, pos, lctSize) : globalPalette
                if lctFlag { pos += lctSize * 3 }
                guard let pal = palette else { return nil }
                let minCodeSize = Int(data[pos]) & 0xFF
                pos += 1
                var lzwData: [UInt8] = []
                while pos < data.count && Int(data[pos]) != 0 {
                    let subLen = Int(data[pos]) & 0xFF
                    let end = min(pos + 1 + subLen, data.count)
                    if pos + 1 < end {
                        lzwData += Array(data[(pos + 1)..<end])
                    }
                    pos += 1 + subLen
                }
                let indices = lzwDecode(minCodeSize, lzwData)
                return renderFrame(indices, width, height, left, top, imgW, imgH, interlace, pal)
            case 0x3B:
                return nil
            default:
                pos += 1
            }
        }
        return nil
    }

    private static func isGifHeader(_ data: [UInt8]) -> Bool {
        if data.count < 6 { return false }
        let s = String(decoding: data[0..<6], as: UTF8.self)
        return s == "GIF87a" || s == "GIF89a"
    }

    private static func renderFrame(
        _ indices: [Int],
        _ canvasW: Int,
        _ canvasH: Int,
        _ left: Int,
        _ top: Int,
        _ imgW: Int,
        _ imgH: Int,
        _ interlace: Bool,
        _ palette: [UInt8]
    ) -> GifFrameResult {
        var rgb = [UInt8](repeating: 0, count: canvasW * canvasH * 3)
        var pixel = 0
        for row in 0..<imgH {
            let destRow = interlace ? deinterlaceRow(row, imgH) : row
            for col in 0..<imgW {
                if pixel >= indices.count { return GifFrameResult(width: canvasW, height: canvasH, rgb: rgb) }
                let idx = indices[pixel]
                pixel += 1
                let src = idx * 3
                let dst = ((top + destRow) * canvasW + (left + col)) * 3
                if src + 2 < palette.count && dst + 2 < rgb.count {
                    rgb[dst] = palette[src]
                    rgb[dst + 1] = palette[src + 1]
                    rgb[dst + 2] = palette[src + 2]
                }
            }
        }
        return GifFrameResult(width: canvasW, height: canvasH, rgb: rgb)
    }

    /// GIF 交织行序：pass1 隔 8 取 0,8.. / pass2 取 4,12.. / pass3 隔 4 取 2,6.. / pass4 隔 2 取 1,3..
    private static func deinterlaceRow(_ row: Int, _ height: Int) -> Int {
        let p1 = (height + 7) / 8
        if row < p1 { return row * 8 }
        let p2 = (height + 3) / 8
        if row < p1 + p2 { return (row - p1) * 8 + 4 }
        let p3 = (height + 1) / 4
        if row < p1 + p2 + p3 { return (row - p1 - p2) * 4 + 2 }
        return (row - p1 - p2 - p3) * 2 + 1
    }

    private static func readPalette(_ data: [UInt8], _ offset: Int, _ size: Int) -> [UInt8] {
        var pal = [UInt8](repeating: 0, count: size * 3)
        let n = min(size * 3, max(data.count - offset, 0))
        if n > 0 {
            pal.replaceSubrange(0..<n, with: data[offset..<(offset + n)])
        }
        return pal
    }

    private static func le16(_ data: [UInt8], _ offset: Int) -> Int {
        if offset + 1 >= data.count { return 0 }
        return (Int(data[offset]) & 0xFF) | ((Int(data[offset + 1]) & 0xFF) << 8)
    }

    private static func lzwDecode(_ minCodeSize: Int, _ data: [UInt8]) -> [Int] {
        let clearCode = 1 << minCodeSize
        let endCode = clearCode + 1
        var codeSize = minCodeSize + 1
        var dict: [[Int]] = []
        func resetDict() {
            dict.removeAll()
            for i in 0..<clearCode { dict.append([i]) }
            dict.append([])
            dict.append([])
            codeSize = minCodeSize + 1
        }
        resetDict()
        var result: [Int] = []
        var previousCode = -1
        var bitBuffer = 0
        var bitCount = 0
        var bytePos = 0
        while true {
            while bitCount < codeSize {
                if bytePos >= data.count { return result }
                bitBuffer = bitBuffer | (Int(data[bytePos]) << bitCount)
                bytePos += 1
                bitCount += 8
            }
            let code = bitBuffer & ((1 << codeSize) - 1)
            bitBuffer = bitBuffer >> codeSize
            bitCount -= codeSize

            if code == clearCode {
                resetDict()
                previousCode = -1
                continue
            }
            if code == endCode { break }

            if previousCode == -1 {
                if code >= dict.count { break }
                result += dict[code]
                previousCode = code
                continue
            }
            let prev = dict[previousCode]
            let entry: [Int]
            if code < dict.count {
                entry = dict[code]
                dict.append(prev + [entry[0]])
            } else if code == dict.count {
                entry = prev + [prev[0]]
                dict.append(entry)
            } else {
                break
            }
            result += entry
            previousCode = code
            if dict.count == (1 << codeSize) && codeSize < 12 { codeSize += 1 }
        }
        return result
    }
}