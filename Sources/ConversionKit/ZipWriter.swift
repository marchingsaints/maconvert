import Foundation

/// Minimal zip archive writer for .docx and .pptx (both are zips of XML).
/// Deflates with the system zlib; no zip64, so archives stay under 4 GB.
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func add(_ path: String, _ data: Data, compress: Bool = true) {
        let name = Data(path.utf8)
        let crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
        // Already-compressed media (JPEG, PNG) is stored as-is.
        let packed = compress ? deflated(data) : nil
        let method: UInt16 = packed == nil ? 0 : 8
        let stored = packed ?? data
        let offset = UInt32(body.count)
        let (time, date) = Self.dosTimestamp(Date())

        var local = Data()
        local.le32(0x0403_4B50); local.le16(20); local.le16(0x0800) // version, UTF-8 names
        local.le16(method); local.le16(time); local.le16(date)
        local.le32(crc); local.le32(UInt32(stored.count)); local.le32(UInt32(data.count))
        local.le16(UInt16(name.count)); local.le16(0)
        body.append(local); body.append(name); body.append(stored)

        var entry = Data()
        entry.le32(0x0201_4B50); entry.le16(20); entry.le16(20); entry.le16(0x0800)
        entry.le16(method); entry.le16(time); entry.le16(date)
        entry.le32(crc); entry.le32(UInt32(stored.count)); entry.le32(UInt32(data.count))
        entry.le16(UInt16(name.count)); entry.le16(0); entry.le16(0); entry.le16(0); entry.le16(0)
        entry.le32(0); entry.le32(offset)
        central.append(entry); central.append(name)
        count += 1
    }

    mutating func add(_ path: String, _ xml: String) { add(path, Data(xml.utf8)) }

    func finish() -> Data {
        var out = body
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0); end.le16(count); end.le16(count)
        end.le32(UInt32(central.count)); end.le32(UInt32(body.count)); end.le16(0)
        out.append(central); out.append(end)
        return out
    }

    /// Raw DEFLATE (no zlib header), as zip expects.
    private func deflated(_ data: Data) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var out = Data(count: Int(deflateBound(&stream, uLong(data.count))))
        let ok = data.withUnsafeBytes { src in out.withUnsafeMutableBytes { dst -> Bool in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(src.count)
            stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(dst.count)
            return deflate(&stream, Z_FINISH) == Z_STREAM_END
        } }
        guard ok else { return nil }
        out.count = Int(stream.total_out)
        return out
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let time = UInt16(hour << 11 | minute << 5 | second / 2)
        let date = UInt16(year << 9 | month << 5 | day)
        return (time, date)
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

/// Escapes text for XML element content and attributes.
extension String {
    var xmlEscaped: String {
        var out = ""
        out.reserveCapacity(count)
        for scalar in unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            // XML 1.0 forbids most control characters; PDFs sometimes contain them.
            case "\u{9}", "\u{A}", "\u{D}": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value): continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
