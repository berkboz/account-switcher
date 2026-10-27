import Foundation

// MARK: - LevelDB, just enough for Claude's Local Storage
//
// Claude Desktop keeps some UI state (the Code sidebar's groups and sections) in Chromium's Local
// Storage: a LevelDB database at <data folder>/Local Storage/leveldb. This reads the newest value
// of a few keys from its table files and logs, and adds new values as one batch in a new log file,
// which LevelDB replays the next time Claude opens the database. Existing files are never changed.
// Only run it while Claude is quit. Formats: github.com/google/leveldb/tree/main/doc

struct LevelDBError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = "Local Storage: \(message)" }
}

/// Reads LevelDB's varints and little-endian fixed-width integers.
struct ByteReader {
    let bytes: [UInt8]
    var pos: Int
    let end: Int
    init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil) {
        self.bytes = bytes; pos = start; self.end = end ?? bytes.count
    }
    var atEnd: Bool { pos >= end }

    mutating func byte() throws -> UInt8 {
        guard pos < end else { throw LevelDBError("truncated data") }
        pos += 1
        return bytes[pos - 1]
    }
    mutating func varint() throws -> UInt64 {
        var v: UInt64 = 0
        for shift in stride(from: UInt64(0), to: 64, by: 7) {
            let b = try byte()
            v |= UInt64(b & 0x7f) << shift
            if b < 0x80 { return v }
        }
        throw LevelDBError("bad varint")
    }
    mutating func fixed(_ n: Int) throws -> UInt64 {
        guard pos + n <= end else { throw LevelDBError("truncated data") }
        var v: UInt64 = 0
        for i in 0..<n { v |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
        pos += n
        return v
    }
    mutating func slice(_ n: Int) throws -> [UInt8] {
        guard n >= 0, pos + n <= end else { throw LevelDBError("truncated data") }
        pos += n
        return Array(bytes[(pos - n)..<pos])
    }
    mutating func lengthPrefixed() throws -> [UInt8] { try slice(Int(try varint())) }
}

func putVarint(_ v: UInt64, _ out: inout [UInt8]) {
    var v = v
    while v >= 0x80 { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
    out.append(UInt8(v))
}

func putFixed(_ v: UInt64, _ n: Int, _ out: inout [UInt8]) {
    for i in 0..<n { out.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
}

let crc32cTable: [UInt32] = (0..<256).map { i in
    var c = UInt32(i)
    for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0x82F6_3B78 : c >> 1 }
    return c
}

/// LevelDB's masked CRC-32C of a log record's type byte and payload.
func maskedCRC(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var c: UInt32 = 0xffff_ffff
    for b in bytes { c = crc32cTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
    c = ~c
    return ((c >> 15) | (c << 17)) &+ 0xa282_ead8
}

func snappyDecompress(_ bytes: [UInt8]) throws -> [UInt8] {
    var r = ByteReader(bytes)
    let length = Int(try r.varint())
    var out: [UInt8] = []
    out.reserveCapacity(length)
    while !r.atEnd {
        let tag = try r.byte()
        if tag & 3 == 0 {
            var n = Int(tag >> 2)
            if n >= 60 { n = Int(try r.fixed(n - 59)) }
            out += try r.slice(n + 1)
            continue
        }
        let n: Int, offset: Int
        switch tag & 3 {
        case 1: n = 4 + Int((tag >> 2) & 7); offset = Int(tag >> 5) << 8 | Int(try r.byte())
        case 2: n = 1 + Int(tag >> 2); offset = Int(try r.fixed(2))
        default: n = 1 + Int(tag >> 2); offset = Int(try r.fixed(4))
        }
        guard offset > 0, offset <= out.count else { throw LevelDBError("bad compressed block") }
        let start = out.count - offset
        for i in 0..<n { out.append(out[start + i]) }    // the copy may overlap what it appends
    }
    guard out.count == length else { throw LevelDBError("bad compressed block") }
    return out
}

let logBlockSize = 32768

/// The records of a log file (or MANIFEST), reassembled from their fragments. A damaged block is
/// skipped, as LevelDB does; a torn record at the end is ignored.
func logRecords(_ data: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = [], pending: [UInt8]? = nil, pos = 0
    while pos + 7 <= data.count {
        let left = logBlockSize - pos % logBlockSize
        if left < 7 { pos += left; continue }
        let length = Int(data[pos + 4]) | Int(data[pos + 5]) << 8, type = data[pos + 6]
        let stored = UInt32(data[pos]) | UInt32(data[pos + 1]) << 8 | UInt32(data[pos + 2]) << 16 | UInt32(data[pos + 3]) << 24
        guard 7 + length <= left, pos + 7 + length <= data.count,
              type >= 1, type <= 4, maskedCRC(data[(pos + 6)..<(pos + 7 + length)]) == stored else {
            pending = nil
            pos += left
            continue
        }
        let payload = data[(pos + 7)..<(pos + 7 + length)]
        switch type {
        case 1: out.append(Array(payload)); pending = nil
        case 2: pending = Array(payload)
        case 3: pending? += payload
        default: if let p = pending { out.append(p + payload) }; pending = nil
        }
        pos += 7 + length
    }
    return out
}

/// Frames `payload` as one log record split into fragments, for a new, empty log file.
func logFile(_ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [], rest = payload[...], first = true
    repeat {
        let left = logBlockSize - out.count % logBlockSize
        if left < 7 { out += [UInt8](repeating: 0, count: left); continue }
        let n = min(left - 7, rest.count), last = n == rest.count
        let type: UInt8 = first ? (last ? 1 : 2) : (last ? 4 : 3)
        let fragment = [type] + rest.prefix(n)
        putFixed(UInt64(maskedCRC(fragment[...])), 4, &out)
        putFixed(UInt64(n), 2, &out)
        out += fragment
        rest = rest.dropFirst(n)
        first = false
    } while !rest.isEmpty
    return out
}

/// One Local Storage database. Reads only the keys it is asked for.
struct LevelDB {
    let dir: String
    private var newest: [[UInt8]: (seq: UInt64, value: [UInt8]?)] = [:]
    private var lastSequence: UInt64 = 0
    private var nextFile: UInt64 = 0

    init(_ dir: String, keys: Set<[UInt8]>) throws {
        self.dir = dir
        let fm = FileManager.default
        guard let current = try? String(contentsOfFile: "\(dir)/CURRENT", encoding: .utf8) else {
            throw LevelDBError("no database at \(dir)")
        }
        let manifest = try Self.read("\(dir)/\(current.trimmingCharacters(in: .whitespacesAndNewlines))")
        var tables = Set<UInt64>(), logNumber: UInt64 = 0, prevLog: UInt64 = 0
        for record in logRecords(manifest) {
            var r = ByteReader(record)
            while !r.atEnd {
                switch try r.varint() {
                case 1: _ = try r.lengthPrefixed()                              // comparator
                case 2: logNumber = try r.varint()
                case 3: nextFile = max(nextFile, try r.varint())
                case 4: lastSequence = max(lastSequence, try r.varint())
                case 5: _ = try r.varint(); _ = try r.lengthPrefixed()           // compaction pointer
                case 6: _ = try r.varint(); tables.remove(try r.varint())        // deleted file
                case 7:                                                          // new file
                    _ = try r.varint()
                    tables.insert(try r.varint())
                    _ = try r.varint(); _ = try r.lengthPrefixed(); _ = try r.lengthPrefixed()
                case 9: prevLog = try r.varint()
                case let tag: throw LevelDBError("unknown manifest entry \(tag)")
                }
            }
        }

        func remember(_ key: [UInt8], _ seq: UInt64, _ value: [UInt8]?) {
            guard keys.contains(key), seq >= (newest[key]?.seq ?? 0) else { return }
            newest[key] = (seq, value)
        }
        for number in tables {
            let path = ["ldb", "sst"].map { String(format: "%@/%06llu.%@", dir, number, $0) }
                .first { fm.fileExists(atPath: $0) }
            guard let path else { throw LevelDBError("table \(number) is missing") }
            for (internalKey, value) in try Self.tableEntries(try Self.read(path)) where internalKey.count >= 8 {
                let tag = try { var r = ByteReader(internalKey, from: internalKey.count - 8); return try r.fixed(8) }()
                remember(Array(internalKey.dropLast(8)), tag >> 8, tag & 0xff == 1 ? value : nil)
            }
        }

        // Logs the manifest has not folded into tables yet, oldest first, as LevelDB replays them.
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        for name in names {
            guard let number = UInt64(name.prefix { $0.isNumber }), name.count > 6 else { continue }
            nextFile = max(nextFile, number + 1)
        }
        let logs = names.filter { $0.hasSuffix(".log") }
            .compactMap { UInt64($0.dropLast(4)) }
            .filter { $0 >= logNumber || $0 == prevLog }.sorted()
        for number in logs {
            for record in logRecords(try Self.read(String(format: "%@/%06llu.log", dir, number))) {
                var r = ByteReader(record)
                var seq = try r.fixed(8)
                let count = try r.fixed(4)
                for _ in 0..<count {
                    switch try r.byte() {
                    case 1: let k = try r.lengthPrefixed(); remember(k, seq, try r.lengthPrefixed())
                    case 0: remember(try r.lengthPrefixed(), seq, nil)
                    default: throw LevelDBError("bad log entry")
                    }
                    lastSequence = max(lastSequence, seq)
                    seq += 1
                }
            }
        }
    }

    func get(_ key: [UInt8]) -> [UInt8]? { newest[key]?.value ?? nil }

    /// Stores `entries` as one batch in a new log file, numbered and sequenced after everything
    /// in the database so LevelDB replays it last.
    mutating func put(_ entries: [(key: [UInt8], value: [UInt8])]) throws {
        guard !entries.isEmpty else { return }
        var batch: [UInt8] = []
        putFixed(lastSequence + 1, 8, &batch)
        putFixed(UInt64(entries.count), 4, &batch)
        for e in entries {
            batch.append(1)
            putVarint(UInt64(e.key.count), &batch); batch += e.key
            putVarint(UInt64(e.value.count), &batch); batch += e.value
        }
        let path = String(format: "%@/%06llu.log", dir, nextFile)
        guard !FileManager.default.fileExists(atPath: path) else { throw LevelDBError("\(path) already exists") }
        try Data(logFile(batch)).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        for e in entries { newest[e.key] = (lastSequence + 1, e.value) }
        lastSequence += UInt64(entries.count)
        nextFile += 1
    }

    static func read(_ path: String) throws -> [UInt8] {
        guard let data = FileManager.default.contents(atPath: path) else { throw LevelDBError("cannot read \(path)") }
        return [UInt8](data)
    }

    /// The block at a handle (offset, size) read from `r`, decompressed.
    static func block(_ file: [UInt8], _ r: inout ByteReader) throws -> [UInt8] {
        let offset = Int(try r.varint()), size = Int(try r.varint())
        guard offset >= 0, size >= 0, offset + size + 5 <= file.count else { throw LevelDBError("bad block handle") }
        let raw = Array(file[offset..<(offset + size)])
        switch file[offset + size] {
        case 0: return raw
        case 1: return try snappyDecompress(raw)
        default: throw LevelDBError("unknown block compression")
        }
    }

    static func blockEntries(_ b: [UInt8]) throws -> [(key: [UInt8], value: [UInt8])] {
        guard b.count >= 4 else { throw LevelDBError("bad block") }
        var tail = ByteReader(b, from: b.count - 4)
        let restartsAt = b.count - 4 - 4 * Int(try tail.fixed(4))
        guard restartsAt >= 0 else { throw LevelDBError("bad block") }
        var r = ByteReader(b, to: restartsAt), key: [UInt8] = [], out: [(key: [UInt8], value: [UInt8])] = []
        while !r.atEnd {
            let shared = Int(try r.varint()), unshared = Int(try r.varint()), valueLength = Int(try r.varint())
            guard shared <= key.count else { throw LevelDBError("bad block") }
            key = Array(key[0..<shared]) + (try r.slice(unshared))
            out.append((key, try r.slice(valueLength)))
        }
        return out
    }

    static func tableEntries(_ file: [UInt8]) throws -> [(key: [UInt8], value: [UInt8])] {
        guard file.count >= 48 else { throw LevelDBError("bad table") }
        var magic = ByteReader(file, from: file.count - 8)
        guard try magic.fixed(8) == 0xdb47_7524_8b80_fb57 else { throw LevelDBError("bad table") }
        var footer = ByteReader(file, from: file.count - 48)
        _ = try footer.varint(); _ = try footer.varint()                         // metaindex handle
        var out: [(key: [UInt8], value: [UInt8])] = []
        for entry in try blockEntries(try block(file, &footer)) {
            var handle = ByteReader(entry.value)
            out += try blockEntries(try block(file, &handle))
        }
        return out
    }
}

// MARK: - Local Storage keys and values

/// The database key of a claude.ai Local Storage item.
func localStorageKey(_ name: String) -> [UInt8] {
    Array("_https://claude.ai".utf8) + [0, 1] + Array(name.utf8)
}

/// Chromium stores a value as Latin-1 (first byte 1) or UTF-16LE (first byte 0).
func localStorageString(_ bytes: [UInt8]) -> String? {
    switch bytes.first {
    case 1: return String(data: Data(bytes.dropFirst()), encoding: .isoLatin1)
    case 0: return String(data: Data(bytes.dropFirst()), encoding: .utf16LittleEndian)
    default: return nil
    }
}

func localStorageBytes(_ s: String) -> [UInt8] {
    if let latin1 = s.data(using: .isoLatin1) { return [1] + latin1 }
    return [0] + [UInt8](s.data(using: .utf16LittleEndian) ?? Data())
}
