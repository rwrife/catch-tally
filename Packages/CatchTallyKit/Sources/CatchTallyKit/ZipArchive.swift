import Foundation

/// Minimal ZIP codec (store/no-compression) used by issue #6 backup bundles.
///
/// Why in-tree:
/// - Linux-testable (no Apple-only framework dependency)
/// - no shell tools/process spawning
/// - enough for deterministic app-owned archives (manifest + photo blobs)
enum ZipArchive {
    struct Entry: Sendable {
        var path: String
        var data: Data
    }

    enum ZipError: Error, Equatable, Sendable {
        case invalidArchive(String)
        case unsupportedCompression(UInt16)
        case crcMismatch(String)
        case duplicatePath(String)
        case unsupportedZip64
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    private struct CentralRecord {
        var path: String
        var crc32: UInt32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var method: UInt16
        var localHeaderOffset: UInt32
    }

    /// Create a ZIP archive containing the supplied files.
    /// - Note: uses method=store (0), no compression.
    static func create(entries: [Entry]) throws -> Data {
        var out = Data()
        var centralDirectory = Data()
        var seen = Set<String>()
        var entryCount: UInt16 = 0

        for entry in entries {
            guard !entry.path.isEmpty else { throw ZipError.invalidArchive("empty entry path") }
            guard seen.insert(entry.path).inserted else { throw ZipError.duplicatePath(entry.path) }

            let nameData = Data(entry.path.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw ZipError.invalidArchive("entry path too long: \(entry.path)")
            }
            guard entry.data.count <= Int(UInt32.max) else {
                throw ZipError.unsupportedZip64
            }

            let localOffset = UInt32(out.count)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)

            // Local file header
            out.appendLE(localHeaderSignature)
            out.appendLE(UInt16(20)) // version needed to extract
            out.appendLE(UInt16(0)) // flags
            out.appendLE(UInt16(0)) // method = stored
            out.appendLE(UInt16(0)) // mod time
            out.appendLE(UInt16(0)) // mod date
            out.appendLE(crc)
            out.appendLE(size)
            out.appendLE(size)
            out.appendLE(UInt16(nameData.count))
            out.appendLE(UInt16(0)) // extra length
            out.append(nameData)
            out.append(entry.data)

            // Central directory record
            centralDirectory.appendLE(centralHeaderSignature)
            centralDirectory.appendLE(UInt16(20)) // version made by
            centralDirectory.appendLE(UInt16(20)) // version needed
            centralDirectory.appendLE(UInt16(0)) // flags
            centralDirectory.appendLE(UInt16(0)) // method
            centralDirectory.appendLE(UInt16(0)) // mod time
            centralDirectory.appendLE(UInt16(0)) // mod date
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(size)
            centralDirectory.appendLE(size)
            centralDirectory.appendLE(UInt16(nameData.count))
            centralDirectory.appendLE(UInt16(0)) // extra length
            centralDirectory.appendLE(UInt16(0)) // comment length
            centralDirectory.appendLE(UInt16(0)) // disk number start
            centralDirectory.appendLE(UInt16(0)) // internal attrs
            centralDirectory.appendLE(UInt32(0)) // external attrs
            centralDirectory.appendLE(localOffset)
            centralDirectory.append(nameData)

            guard entryCount < UInt16.max else { throw ZipError.unsupportedZip64 }
            entryCount += 1
        }

        let centralOffset = UInt32(out.count)
        guard centralDirectory.count <= Int(UInt32.max) else { throw ZipError.unsupportedZip64 }
        out.append(centralDirectory)

        // End of central directory
        out.appendLE(endOfCentralDirectorySignature)
        out.appendLE(UInt16(0)) // disk number
        out.appendLE(UInt16(0)) // central directory disk
        out.appendLE(entryCount)
        out.appendLE(entryCount)
        out.appendLE(UInt32(centralDirectory.count))
        out.appendLE(centralOffset)
        out.appendLE(UInt16(0)) // comment length
        return out
    }

    /// Extract ZIP archive entries keyed by relative path.
    ///
    /// Supports only non-ZIP64 archives and method=store(0) entries.
    static func extract(_ data: Data) throws -> [String: Data] {
        let eocdOffset = try findEndOfCentralDirectory(in: data)
        let totalEntries = try data.readLEUInt16(at: eocdOffset + 10)
        let centralSize = try data.readLEUInt32(at: eocdOffset + 12)
        let centralOffset = try data.readLEUInt32(at: eocdOffset + 16)

        let centralStart = Int(centralOffset)
        let centralEnd = centralStart + Int(centralSize)
        guard centralStart >= 0, centralEnd <= data.count else {
            throw ZipError.invalidArchive("central directory out of bounds")
        }

        var records: [CentralRecord] = []
        var cursor = centralStart
        for _ in 0..<totalEntries {
            let sig = try data.readLEUInt32(at: cursor)
            guard sig == centralHeaderSignature else {
                throw ZipError.invalidArchive("bad central directory signature at \(cursor)")
            }

            let method = try data.readLEUInt16(at: cursor + 10)
            let crc = try data.readLEUInt32(at: cursor + 16)
            let compressed = try data.readLEUInt32(at: cursor + 20)
            let uncompressed = try data.readLEUInt32(at: cursor + 24)
            let nameLen = Int(try data.readLEUInt16(at: cursor + 28))
            let extraLen = Int(try data.readLEUInt16(at: cursor + 30))
            let commentLen = Int(try data.readLEUInt16(at: cursor + 32))
            let localOffset = try data.readLEUInt32(at: cursor + 42)

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= centralEnd else {
                throw ZipError.invalidArchive("central name out of bounds")
            }
            guard let path = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) else {
                throw ZipError.invalidArchive("non-utf8 zip path")
            }

            records.append(CentralRecord(
                path: path,
                crc32: crc,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                method: method,
                localHeaderOffset: localOffset))

            cursor = nameEnd + extraLen + commentLen
            guard cursor <= centralEnd else {
                throw ZipError.invalidArchive("central record overflow")
            }
        }

        var out: [String: Data] = [:]
        out.reserveCapacity(records.count)

        for record in records {
            if record.method != 0 {
                throw ZipError.unsupportedCompression(record.method)
            }
            guard !out.keys.contains(record.path) else {
                throw ZipError.duplicatePath(record.path)
            }

            let localStart = Int(record.localHeaderOffset)
            let localSig = try data.readLEUInt32(at: localStart)
            guard localSig == localHeaderSignature else {
                throw ZipError.invalidArchive("bad local header signature for \(record.path)")
            }

            let localNameLen = Int(try data.readLEUInt16(at: localStart + 26))
            let localExtraLen = Int(try data.readLEUInt16(at: localStart + 28))
            let payloadStart = localStart + 30 + localNameLen + localExtraLen
            let payloadEnd = payloadStart + Int(record.compressedSize)
            guard payloadStart >= 0, payloadEnd <= data.count else {
                throw ZipError.invalidArchive("payload out of bounds for \(record.path)")
            }

            let payload = data.subdata(in: payloadStart..<payloadEnd)
            guard payload.count == Int(record.uncompressedSize) else {
                throw ZipError.invalidArchive("stored size mismatch for \(record.path)")
            }
            let crc = CRC32.checksum(payload)
            guard crc == record.crc32 else {
                throw ZipError.crcMismatch(record.path)
            }
            out[record.path] = payload
        }

        return out
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        // EOCD min size is 22 bytes; comment max is 65535 bytes.
        let minimum = 22
        guard data.count >= minimum else {
            throw ZipError.invalidArchive("archive too small")
        }
        let maxSearch = min(data.count, minimum + Int(UInt16.max))
        let start = data.count - maxSearch
        let signature = Data([0x50, 0x4B, 0x05, 0x06])

        if maxSearch >= signature.count {
            var i = data.count - signature.count
            while i >= start {
                if data[i..<(i + signature.count)] == signature {
                    return i
                }
                i -= 1
            }
        }
        throw ZipError.invalidArchive("end of central directory not found")
    }
}

private enum CRC32 {
    private static let polynomial: UInt32 = 0xEDB8_8320

    static let table: [UInt32] = {
        (0..<256).map { i in
            var crc = UInt32(i)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ polynomial
                } else {
                    crc >>= 1
                }
            }
            return crc
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[idx]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLEUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw ZipArchive.ZipError.invalidArchive("read uint16 out of bounds at \(offset)")
        }
        return withUnsafeBytes { raw in
            UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    func readLEUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw ZipArchive.ZipError.invalidArchive("read uint32 out of bounds at \(offset)")
        }
        return withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}
