import Foundation
import Darwin

/// WRS1 is a bounded, text-only app snapshot. It carries no account authorization or full book text.
/// WRS1 是有界的纯文本应用快照，不包含账户授权和整书正文。
public struct ReadPicoWeReadTransfer: Sendable {
    public let generation: UInt32, bookCount: Int, noteCount: Int
    public let index: Data, chunks: [String: Data]
    public var bytes: Int { index.count + chunks.values.reduce(0) { $0 + $1.count } }
}
public struct ReadPicoWeReadExportReport: Sendable {
    public let generation: UInt32, bookCount: Int, noteCount: Int, filesWritten: Int, bytesWritten: Int
}
public enum ReadPicoWeReadCodec {
    public static let indexBytes = 16448, chunkBytes = 32768, chunkTextBytes = 32703
    private static func fail(_ text: String) -> ReadPicoWeReadError { .storage(text) }
    private static func u32(_ data: Data, _ p: Int) -> UInt32 {
        UInt32(data[p]) | UInt32(data[p+1]) << 8 | UInt32(data[p+2]) << 16 | UInt32(data[p+3]) << 24
    }
    private static func put(_ value: UInt32, _ data: inout Data, _ p: Int) {
        for i in 0..<4 { data[p+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
    private static func put64(_ value: UInt64, _ data: inout Data, _ p: Int) {
        for i in 0..<8 { data[p+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
    }
    private static func plain(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.properties.generalCategory == .control && $0.value != 9 && $0.value != 10 }
    }
    private static func field(_ value: String, into data: inout Data, at p: Int, bytes: Int, required: Bool = false) throws {
        let encoded = Data(value.utf8)
        guard encoded.count < bytes, !required || !encoded.isEmpty, plain(value), !value.contains("\n"), !value.contains("\t") else {
            throw fail("所选书籍的书名、作者或标识超过设备容量，或含不支持的字符；未截断原始资料。")
        }
        data.replaceSubrange(p..<(p+encoded.count), with: encoded)
    }
    private static func envelope(_ payload: Data) -> Data {
        var data = Data(repeating: 0, count: 12)
        put(0x31535058, &data, 0); put(UInt32(payload.count), &data, 4); put(readPicoCRC32(payload), &data, 8)
        data.append(payload); return data
    }
    public static func unwrapped(_ data: Data, bytes: Int) throws -> Data {
        guard data.count == bytes+12, u32(data, 0) == 0x31535058, u32(data, 4) == bytes else { throw fail("微信读书离线资料的长度校验失败。") }
        let payload = data.subdata(in: 12..<data.count)
        guard u32(data, 8) == readPicoCRC32(payload) else { throw fail("微信读书离线资料校验失败，原有文件保留。") }
        return payload
    }
    public static func validatedIndex(_ data: Data) throws -> (generation: UInt32, books: Int, notes: Int) {
        let index = try unwrapped(data, bytes: indexBytes)
        guard index.prefix(8) == Data("PWRIDX01".utf8), u32(index, 8) == 1, u32(index, 12) == indexBytes,
              u32(index, 16) != 0, u32(index, 20) <= 64, index[36..<64].allSatisfy({ $0 == 0 }) else {
            throw fail("微信读书离线索引版本不兼容，未覆盖原资料。")
        }
        let count = Int(u32(index, 20)); var notes: UInt64 = 0, ids = Set<String>()
        for slot in 0..<64 {
            let p = 64+slot*256
            if slot >= count {
                guard index[p..<(p+256)].allSatisfy({ $0 == 0 }) else { throw fail("微信读书离线索引含无效条目。") }; continue
            }
            var id = ""
            for (offset, size, required) in [(0,64,true),(64,128,true),(192,48,false)] {
                let bytes = index.subdata(in: (p+offset)..<(p+offset+size))
                guard let zero = bytes.firstIndex(of: 0), bytes[zero...].allSatisfy({ $0 == 0 }),
                      let text = String(data: bytes[..<zero], encoding: .utf8), !required || !text.isEmpty,
                      plain(text), !text.contains("\n"), !text.contains("\t") else { throw fail("微信读书离线索引的文字字段无效。") }
                if offset == 0 { id = text }
            }
            guard validBookID(id), ids.insert(id).inserted, u32(index,p+244) <= 256,
                  (u32(index,p+240) == 0) == (u32(index,p+244) == 0), index[(p+248)..<(p+256)].allSatisfy({ $0 == 0 }) else { throw fail("微信读书离线索引的书籍记录无效。") }
            notes += UInt64(u32(index,p+240))
        }
        guard notes == u32(index,24) else { throw fail("微信读书离线笔记数量不一致。") }
        return (u32(index,16),count,Int(notes))
    }
    public static func validBookID(_ value: String) -> Bool {
        (1...63).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }
    }
    private static func chunks(_ text: String) throws -> [Data] {
        guard plain(text) else { throw fail("笔记含设备不支持的控制字符，未截断或覆盖原文。") }
        var result: [Data] = [], current = Data()
        // Keep paragraphs together when possible, falling back to Unicode-scalar boundaries.
        // 优先保留整段；长段只在 Unicode 标量边界分块，绝不截断 UTF-8。
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let bytes = Data((String(paragraph)+"\n").utf8)
            if !current.isEmpty && current.count+bytes.count > chunkTextBytes { result.append(current); current = Data() }
            if bytes.count <= chunkTextBytes { current.append(bytes) }
            else {
                for scalar in (String(paragraph)+"\n").unicodeScalars {
                    let bytes = Data(String(scalar).utf8)
                    if current.count+bytes.count > chunkTextBytes { result.append(current); current = Data() }
                    current.append(bytes)
                }
            }
            guard result.count <= 256 else { throw ReadPicoWeReadError.tooLarge }
        }
        if !current.isEmpty { result.append(current) }
        guard result.count <= 256 else { throw ReadPicoWeReadError.tooLarge }; return result
    }
    public static func makeTransfer(_ snapshot: ReadPicoWeReadSnapshot, generation: UInt32) throws -> ReadPicoWeReadTransfer {
        guard generation != 0, snapshot.books.count <= 64, snapshot.noteCount <= Int(UInt32.max),
              snapshot.createdAt.timeIntervalSince1970.isFinite,
              snapshot.createdAt.timeIntervalSince1970 >= 0,
              snapshot.createdAt.timeIntervalSince1970 < Double(UInt64.max) else { throw ReadPicoWeReadError.tooLarge }
        var index = Data(repeating: 0, count: indexBytes), files: [String: Data] = [:], ids = Set<String>(), total = 0
        index.replaceSubrange(0..<8, with: Data("PWRIDX01".utf8)); put(1,&index,8); put(UInt32(indexBytes),&index,12)
        put(generation,&index,16); put(UInt32(snapshot.books.count),&index,20); put(UInt32(snapshot.noteCount),&index,24)
        put64(UInt64(snapshot.createdAt.timeIntervalSince1970),&index,28)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        for (slot, item) in snapshot.books.enumerated() {
            let book = item.book
            guard book.kind == .book, validBookID(book.id), ids.insert(book.id).inserted,
                  item.notes.count <= Int(UInt32.max), Set(item.notes.map(\.id)).count == item.notes.count else {
                throw fail("请选择最多 64 本具有有效标识的电子书；有声书、文章收藏及重复记录不进入此离线资料包。")
            }
            let p = 64+slot*256
            try field(book.id,into:&index,at:p,bytes:64,required:true)
            try field(book.title,into:&index,at:p+64,bytes:128,required:true)
            try field(book.author,into:&index,at:p+192,bytes:48)
            var paragraphs: [String] = []
            for note in item.notes {
                guard plain(note.quote), plain(note.text), plain(note.chapter), !note.id.isEmpty,
                      note.createdAt < 253402300800 else { throw fail("微信读书笔记的文字或日期无效，未覆盖已有资料。") }
                let date = note.createdAt == 0 ? "" : " · "+formatter.string(from: Date(timeIntervalSince1970: Double(note.createdAt)))
                var parts = ["【\(note.kind == .highlight ? "划线" : "想法")】\(date)"]
                if !note.chapter.isEmpty { parts.append("章节："+note.chapter) }
                if !note.quote.isEmpty { parts.append((note.kind == .thought ? "原文：" : "")+note.quote) }
                if !note.text.isEmpty { parts.append("想法："+note.text) }
                let text = parts.joined(separator: "\n"); total += text.utf8.count
                guard total <= 32*1024*1024 else { throw ReadPicoWeReadError.tooLarge }
                paragraphs.append(text)
            }
            let bodies = item.notes.isEmpty ? [] : try chunks(paragraphs.joined(separator: "\n\n"))
            put(UInt32(item.notes.count),&index,p+240); put(UInt32(bodies.count),&index,p+244)
            for (chunk, text) in bodies.enumerated() {
                var payload = Data(repeating: 0, count: chunkBytes)
                payload.replaceSubrange(0..<8,with:Data("PWRCHK01".utf8)); put(1,&payload,8); put(UInt32(chunkBytes),&payload,12)
                put(generation,&payload,16); put(UInt32(slot),&payload,20); put(UInt32(chunk),&payload,24)
                put(UInt32(bodies.count),&payload,28); put(UInt32(text.count),&payload,32)
                payload.replaceSubrange(64..<(64+text.count),with:text)
                let name = String(format:"g%08x-b%02x-c%03x.dat",generation,slot,chunk)
                files[name] = envelope(payload)
            }
        }
        let wrapped = envelope(index); _ = try validatedIndex(wrapped)
        return ReadPicoWeReadTransfer(generation:generation,bookCount:snapshot.books.count,noteCount:snapshot.noteCount,index:wrapped,chunks:files)
    }
}

/// A dedicated transaction, rather than an extension of the generic arbitrary file whitelist.
/// 专用事务只写微信读书命名空间，不扩大普通文件管理的路径白名单。
public actor ReadPicoWeReadTFExporter {
    private let store: ReadPicoTFStore
    public nonisolated let rootURL: URL
    private var writing = false
    public init(rootURL: URL) throws { let store = try ReadPicoTFStore(rootURL: rootURL); self.store = store; self.rootURL = store.rootURL }
    private func directory() throws -> URL {
        var current = rootURL
        let files = FileManager.default
        let rootDevice = try files.attributesOfItem(atPath:rootURL.path)[.systemNumber] as? NSNumber
        for part in ["apps","data","weread"] {
            current.appendPathComponent(part,isDirectory:true)
            if !files.fileExists(atPath:current.path) { try files.createDirectory(at:current,withIntermediateDirectories:false) }
            let a = try files.attributesOfItem(atPath:current.path)
            guard a[.type] as? FileAttributeType == .typeDirectory,
                  a[.systemNumber] as? NSNumber == rootDevice,
                  current.resolvingSymlinksInPath() == current.standardizedFileURL else { throw ReadPicoWeReadError.storage("微信读书资料目录不是卡片内的普通文件夹，已停止同步。") }
        }
        return current
    }
    private func read(_ url: URL, maximum: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let a = try FileManager.default.attributesOfItem(atPath:url.path)
        guard a[.type] as? FileAttributeType == .typeRegular, let size = a[.size] as? NSNumber, size.intValue <= maximum else { throw ReadPicoWeReadError.storage("微信读书资料不是有效的普通文件，已停止同步。") }
        let data = try Data(contentsOf:url); guard data.count == size.intValue else { throw ReadPicoWeReadError.storage("TF 卡读取不完整，已停止同步。") }; return data
    }
    private func publish(_ data: Data, to url: URL, replace: Bool) async throws {
        try Task.checkCancellation(); try await store.verifyAvailable(writing:true)
        let staging = url.deletingLastPathComponent().appendingPathComponent(".weread-\(UUID().uuidString).tmp")
        let fd = Darwin.open(staging.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,mode_t(0o600))
        guard fd >= 0 else { throw ReadPicoWeReadError.storage("无法建立微信读书传输暂存文件。") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at:staging) }
        try handle.write(contentsOf:data); try handle.synchronize()
        guard try read(staging,maximum:data.count) == data else { throw ReadPicoWeReadError.storage("微信读书离线资料写入校验未通过；原资料保留。") }
        try Task.checkCancellation(); try await store.verifyAvailable(writing:true)
        guard try directory() == url.deletingLastPathComponent(),
              !FileManager.default.fileExists(atPath:url.path) || replace else { throw ReadPicoWeReadError.storage("同代离线资料已经存在，未覆盖。") }
        if FileManager.default.fileExists(atPath:url.path) { _ = try read(url,maximum:ReadPicoWeReadCodec.indexBytes+12) }
        guard Darwin.rename(staging.path,url.path) == 0 else { throw ReadPicoWeReadError.storage("微信读书离线资料尚未提交，旧资料保留。") }
        let parentFD = Darwin.open(url.deletingLastPathComponent().path,O_RDONLY|O_DIRECTORY)
        if parentFD >= 0 { _ = fsync(parentFD); Darwin.close(parentFD) }
        guard try read(url,maximum:data.count) == data else { throw ReadPicoWeReadError.storage("TF 卡提交后的校验失败，请保持连接并重试。") }
    }
    @discardableResult public func write(_ snapshot: ReadPicoWeReadSnapshot,
                                         progress: (@Sendable (Int64,Int64,String)->Void)? = nil) async throws -> ReadPicoWeReadExportReport {
        guard !writing else { throw ReadPicoWeReadError.storage("微信读书同步正在进行，请等待完成。") }
        writing = true; defer { writing = false }
        try Task.checkCancellation(); try await store.verifyAvailable(writing:true)
        let folder = try directory()
        // Advisory lock also protects against a second exporter instance in this Mac session.
        // 文件锁防止同一 Mac 会话中另一导出器同时提交索引；不修改设备阅读位置。
        let lockURL = folder.appendingPathComponent(".sync-lock")
        let fd = Darwin.open(lockURL.path,O_RDWR|O_CREAT|O_NOFOLLOW,mode_t(0o600))
        guard fd >= 0 else { throw ReadPicoWeReadError.storage("无法取得微信读书同步锁。") }
        defer { Darwin.close(fd) }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { throw ReadPicoWeReadError.storage("另一项微信读书同步正在使用此 TF 卡。") }
        defer { _ = flock(fd,LOCK_UN) }
        let indexURL = folder.appendingPathComponent("index.dat")
        let old = try read(indexURL,maximum:ReadPicoWeReadCodec.indexBytes+12)
        let oldGeneration = try old.map { try ReadPicoWeReadCodec.validatedIndex($0).generation }
        let names = try FileManager.default.contentsOfDirectory(atPath:folder.path)
        guard names.count < 200000 else { throw ReadPicoWeReadError.tooLarge }
        var generation: UInt32 = 0
        for _ in 0..<32 {
            let candidate = UInt32.random(in:1...UInt32.max), prefix = String(format:"g%08x-",candidate)
            if !names.contains(where: { $0.hasPrefix(prefix) }) && oldGeneration != candidate { generation = candidate; break }
        }
        guard generation != 0 else { throw ReadPicoWeReadError.storage("无法建立新的微信读书资料代次，请重试。") }
        let transfer = try ReadPicoWeReadCodec.makeTransfer(snapshot,generation:generation)
        var done: Int64 = 0; let total = Int64(transfer.bytes)
        progress?(0,total,"copying")
        for name in transfer.chunks.keys.sorted() {
            try Task.checkCancellation()
            let data = transfer.chunks[name]!
            try await publish(data,to:folder.appendingPathComponent(name),replace:false)
            done += Int64(data.count); progress?(done,total,"copying")
        }
        try Task.checkCancellation(); try await store.verifyAvailable(writing:true)
        guard try read(indexURL,maximum:ReadPicoWeReadCodec.indexBytes+12) == old else { throw ReadPicoWeReadError.storage("离线索引在同步期间发生变化，未发布新资料。") }
        if let old { try await publish(old,to:folder.appendingPathComponent("index.bak"),replace:true) }
        progress?(done,total,"committing")
        try await publish(transfer.index,to:indexURL,replace:true)
        done += Int64(transfer.index.count); progress?(done,total,"complete")
        return ReadPicoWeReadExportReport(generation:generation,bookCount:transfer.bookCount,noteCount:transfer.noteCount,filesWritten:transfer.chunks.count+1,bytesWritten:transfer.bytes)
    }
}
