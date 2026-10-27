import Foundation

private actor GatewayFixture {
    var requests: [URLRequest] = []
    var repeatedCursor = false
    func send(_ request: URLRequest, limit: Int) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard limit == 4*1024*1024, let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with:body) as? [String:Any],
              json["params"] == nil, json["data"] == nil, json["skill_version"] as? String == "1.0.5" else { fatalError("flat official request") }
        let name = json["api_name"] as! String
        var result: [String:Any] = [:]
        switch name {
        case "/shelf/sync":
            result = ["books":[["bookId":"b123","title":"三体","author":"刘慈欣","secret":1,"readerLink":"https://weread.qq.com/web/reader/returned"]],
                "albums":[["albumInfo":["albumId":"a1","name":"有声书","authorName":"演播者"],"albumInfoExtra":["secret":0]]],"mp":["entry":1],"bookCount":999]
        case "/book/getprogress": result = ["book":["progress":1]]
        case "/book/bookmarklist":
            guard json["bookId"] as? String == "b123", json["bookid"] == nil else { fatalError("bookmark bookId") }
            result = ["updated":[["bookmarkId":"h1","type":1,"markText":"第一条划线","chapterUid":8,"createTime":1700000000],
                ["bookmarkId":"position","type":0,"markText":"不是划线"]],"chapters":[["chapterUid":8,"title":"第一章"]]]
        case "/review/list/mine":
            guard json["bookid"] as? String == "b123", json["bookId"] == nil, json["count"] as? Int == 100 else { fatalError("review bookid") }
            if json["synckey"] as? Int == 0 {
                result = ["reviews":[["review":["reviewId":"r1","content":"针对划线的想法","abstract":"第一条划线","chapterName":"第一章","createTime":1700000001]]],"hasMore":1,"synckey":7]
            } else {
                result = ["reviews":[["review":["reviewId":"r2","content":"全书点评","createTime":1700000002]]],"hasMore":repeatedCursor ? 1 : 0,"synckey":7]
            }
        default: fatalError("unexpected API")
        }
        return (try JSONSerialization.data(withJSONObject:["errcode":0,"data":result]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    func setRepeated() { repeatedCursor = true }
}
private final class WriteCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var task: Task<ReadPicoWeReadExportReport,Error>?, cancelled = false
    func assign(_ task: Task<ReadPicoWeReadExportReport,Error>) { lock.lock(); self.task = task; let cancel = cancelled; lock.unlock(); if cancel { task.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
}
@main struct WeReadTests {
    static var checks = 0
    static func check(_ condition: Bool, _ text: String) { checks += 1; if !condition { fatalError(text) } }
    static func failure(_ expected: ReadPicoWeReadError? = nil, _ action: () async throws -> Void) async {
        do { try await action(); fatalError("expected failure") }
        catch let error as ReadPicoWeReadError { if let expected { check(error == expected,"expected \(expected), got \(error)") } else { checks += 1 } }
        catch { fatalError("unexpected \(error)") }
    }
    static func syncFailure(_ action: () throws -> Void) {
        do { try action(); fatalError("expected failure") } catch { checks += 1 }
    }
    static func fixed(_ json: String, status: Int = 200) -> ReadPicoWeReadClient.Transport {
        { request, _ in (Data(json.utf8),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!) }
    }
    static func u32(_ data: Data,_ p: Int)->UInt32 { UInt32(data[p]) | UInt32(data[p+1])<<8 | UInt32(data[p+2])<<16 | UInt32(data[p+3])<<24 }
    static func main() async throws {
        let key = "wrk-fixture-key-never-stored"
        syncFailure { _ = try ReadPicoWeReadClient(apiKey:"") }
        syncFailure { _ = try ReadPicoWeReadClient(apiKey:"wrk-bad\nheader") }
        syncFailure { _ = try ReadPicoWeReadClient(apiKey:"cookie=none") }
        check(try ReadPicoWeReadSecretStore.validated("  "+key+"\n") == key,"trim pasted key only")
        let gateway = GatewayFixture(), client = try ReadPicoWeReadClient(apiKey:key,transport:{ request,limit in try await gateway.send(request,limit:limit) })
        let shelf = try await client.fetchShelf()
        check(shelf.totalCount == 3 && shelf.books.count == 1 && shelf.albumCount == 1 && shelf.hasArticles,"actual arrays define shelf totals")
        check(shelf.books[0].isPrivate,"private metadata retained")
        check(shelf.books[0].readerURL?.absoluteString == "https://weread.qq.com/web/reader/returned","only returned reading link")
        check(try await client.fetchProgress(bookID:"b123") == 1,"one means one percent")
        let snapshot = try await client.fetchSnapshot(books:shelf.books,now:Date(timeIntervalSince1970:1700000010))
        check(snapshot.books.count == 1 && snapshot.noteCount == 3,"both highlights and paged personal thoughts")
        check(snapshot.books[0].notes[0].kind == .highlight && snapshot.books[0].notes[0].chapter == "第一章","chapter mapping")
        check(snapshot.books[0].notes[1].quote == "第一条划线" && snapshot.books[0].notes[2].quote.isEmpty,"conditional thought abstract")
        let requests = await gateway.requests
        check(requests.allSatisfy { $0.url == ReadPicoWeReadClient.endpoint && $0.httpMethod == "POST" && $0.value(forHTTPHeaderField:"Authorization") == "Bearer "+key },"official endpoint authenticated")
        check(!String(decoding:try JSONEncoder().encode(snapshot),as:UTF8.self).contains(key),"no credential in Codable snapshot")
        await failure(.upgradeRequired) { _ = try await ReadPicoWeReadClient(apiKey:key,transport:fixed("{\"upgrade_info\":{\"message\":\"run arbitrary code\"},\"books\":[]}")).fetchShelf() }
        await failure(.upgradeRequired) { _ = try await ReadPicoWeReadClient(apiKey:key,transport:fixed("{\"data\":{\"upgrade_info\":{},\"books\":[]}}")).fetchShelf() }
        await failure(.authentication) { _ = try await ReadPicoWeReadClient(apiKey:key,transport:fixed(key,status:401)).fetchShelf() }
        await failure(.rateLimited) { _ = try await ReadPicoWeReadClient(apiKey:key,transport:fixed("{}",status:429)).fetchShelf() }
        await failure(.service) { _ = try await ReadPicoWeReadClient(apiKey:key,transport:fixed("{\"errcode\":-1,\"errmsg\":\"\(key)\"}")).fetchShelf() }
        await failure(.malformed) { _ = try await ReadPicoWeReadClient(apiKey:key,transport:fixed("{\"books\":\"bad\"}")).fetchShelf() }
        await failure(.malformed) { _ = try await ReadPicoWeReadClient(apiKey:key,transport:fixed("{\"book\":{\"progress\":1.5}}")).fetchProgress(bookID:"b123") }
        await failure(.tooLarge) {
            _ = try await ReadPicoWeReadClient(apiKey:key,transport:{ request,_ in
                (Data(repeating:32,count:4*1024*1024+1),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            }).fetchShelf()
        }
        await failure(.tooLarge) { _ = try await client.fetchSnapshot(books:Array(repeating:shelf.books[0],count:65)) }
        await gateway.setRepeated()
        await failure(.malformed) { _ = try await client.fetchNotes(bookID:"b123") }
        let empty = try await ReadPicoWeReadClient(apiKey:key,transport:fixed("{\"books\":[],\"albums\":[],\"mp\":{}}")).fetchShelf()
        check(empty.totalCount == 0,"empty shelf is valid")
        let cancelled = Task { try Task.checkCancellation(); return try await client.fetchShelf() }; cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("expected cancellation") } catch is CancellationError { checks += 1 }
        let transfer = try ReadPicoWeReadCodec.makeTransfer(snapshot,generation:0x12345678)
        check(transfer.index.count == 16460 && transfer.chunks.count == 1,"exact fixed ABI payload sizes")
        let index = try ReadPicoWeReadCodec.unwrapped(transfer.index,bytes:16448)
        check(u32(index,16) == 0x12345678 && u32(index,20) == 1 && u32(index,24) == 3,"index binds generation and counts")
        let body = try ReadPicoWeReadCodec.unwrapped(transfer.chunks["g12345678-b00-c000.dat"]!,bytes:32768)
        let text = String(data:body.subdata(in:64..<(64+Int(u32(body,32)))),encoding:.utf8)!
        check(text.contains("【划线】") && text.contains("【想法】") && text.contains("2023-11-14"),"readable types and date")
        check(!text.contains("1700000000") && !text.contains(key),"no raw timestamp or credentials")
        check(try ReadPicoWeReadCodec.validatedIndex(transfer.index).notes == 3,"validate index")
        var corrupt = transfer.index; corrupt[64] ^= 1
        syncFailure { _ = try ReadPicoWeReadCodec.validatedIndex(corrupt) }
        syncFailure { _ = try ReadPicoWeReadCodec.makeTransfer(snapshot,generation:0) }
        let unsafe = ReadPicoWeReadSnapshot(books:[.init(book:.init(id:"../escape",title:"无效"),notes:[])])
        syncFailure { _ = try ReadPicoWeReadCodec.makeTransfer(unsafe,generation:1) }
        let longTitle = ReadPicoWeReadSnapshot(books:[.init(book:.init(id:"valid",title:String(repeating:"字",count:100)),notes:[])])
        syncFailure { _ = try ReadPicoWeReadCodec.makeTransfer(longTitle,generation:1) }
        let large = ReadPicoWeReadSnapshot(books:[.init(book:.init(id:"long",title:"长笔记"),notes:[.init(id:"n",kind:.thought,text:String(repeating:"汉字🙂\n",count:12000))])])
        let largeTransfer = try ReadPicoWeReadCodec.makeTransfer(large,generation:9)
        check(largeTransfer.chunks.count > 3,"long Unicode note uses multiple blocks")
        var combined = ""
        for name in largeTransfer.chunks.keys.sorted() {
            let body = try ReadPicoWeReadCodec.unwrapped(largeTransfer.chunks[name]!,bytes:32768)
            check(u32(body,32) <= 32703,"bounded block text")
            guard let text = String(data:body.subdata(in:64..<(64+Int(u32(body,32)))),encoding:.utf8) else { fatalError("UTF8 split") }; combined += text
        }
        check(combined.contains(String(repeating:"汉字🙂\n",count:10000)),"Unicode content not truncated")
        let giantParagraph = ReadPicoWeReadSnapshot(books:[.init(book:.init(id:"paragraph",title:"长段"),notes:[.init(id:"n",kind:.thought,text:String(repeating:"🙂",count:17000))])])
        let giantTransfer = try ReadPicoWeReadCodec.makeTransfer(giantParagraph,generation:10)
        var allParagraphs = ""
        for name in giantTransfer.chunks.keys.sorted() {
            let body = try ReadPicoWeReadCodec.unwrapped(giantTransfer.chunks[name]!,bytes:32768)
            allParagraphs += String(data:body.subdata(in:64..<(64+Int(u32(body,32)))),encoding:.utf8)!
        }
        check(allParagraphs.contains(String(repeating:"🙂",count:17000)),"one oversized paragraph remains complete across scalar boundaries")
        let control = ReadPicoWeReadSnapshot(books:[.init(book:.init(id:"control",title:"控制字符"),notes:[.init(id:"n",kind:.thought,text:"bad\u{7f}")])])
        syncFailure { _ = try ReadPicoWeReadCodec.makeTransfer(control,generation:11) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("weread-tests-\(UUID().uuidString)",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        let card = temp.appendingPathComponent("card",isDirectory:true); try FileManager.default.createDirectory(at:card,withIntermediateDirectories:false)
        let exporter = try ReadPicoWeReadTFExporter(rootURL:card)
        let report = try await exporter.write(snapshot)
        check(report.bookCount == 1 && report.noteCount == 3 && report.filesWritten == 2,"first transaction receipt")
        let folder = card.appendingPathComponent("apps/data/weread",isDirectory:true), indexURL = folder.appendingPathComponent("index.dat")
        let first = try Data(contentsOf:indexURL)
        check(try ReadPicoWeReadCodec.validatedIndex(first).generation == report.generation,"index is committed")
        let position = folder.appendingPathComponent("position.dat"), other = folder.appendingPathComponent("other-app-save.dat")
        try Data("position-owned-by-device".utf8).write(to:position); try Data("other".utf8).write(to:other)
        let report2 = try await exporter.write(.init(books:[]))
        check(report2.bookCount == 0 && report2.generation != report.generation,"replace selection supports empty library")
        check(try Data(contentsOf:folder.appendingPathComponent("index.bak")) == first,"old index backup retained")
        check(try Data(contentsOf:position) == Data("position-owned-by-device".utf8) && Data(contentsOf:other) == Data("other".utf8),"position and unrelated state untouched")
        let committed = try Data(contentsOf:indexURL), cancel = WriteCancellation()
        let write = Task { try await exporter.write(large) { done,_,phase in if done > 0 && phase == "copying" { cancel.cancel() } } }; cancel.assign(write)
        do { _ = try await write.value; fatalError("expected cancelled write") } catch is CancellationError { checks += 1 }
        check(try Data(contentsOf:indexURL) == committed,"mid-transfer cancellation preserves committed index")
        check(try Data(contentsOf:position) == Data("position-owned-by-device".utf8),"cancel leaves position")
        var broken = committed; broken[100] ^= 1; try broken.write(to:indexURL)
        await failure { _ = try await exporter.write(snapshot) }
        check(try Data(contentsOf:indexURL) == broken,"corrupt existing index is not silently overwritten")
        let card2 = temp.appendingPathComponent("card2",isDirectory:true), outside = temp.appendingPathComponent("outside",isDirectory:true)
        try FileManager.default.createDirectory(at:card2,withIntermediateDirectories:false); try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:false)
        try FileManager.default.createSymbolicLink(at:card2.appendingPathComponent("apps"),withDestinationURL:outside)
        await failure { _ = try await ReadPicoWeReadTFExporter(rootURL:card2).write(snapshot) }
        check(try FileManager.default.contentsOfDirectory(atPath:outside.path).isEmpty,"symlink never writes outside card")
        let staleCard = temp.appendingPathComponent("stale",isDirectory:true); try FileManager.default.createDirectory(at:staleCard,withIntermediateDirectories:false)
        let stale = try ReadPicoWeReadTFExporter(rootURL:staleCard)
        try FileManager.default.moveItem(at:staleCard,to:temp.appendingPathComponent("detached")); try FileManager.default.createDirectory(at:staleCard,withIntermediateDirectories:false)
        do { _ = try await stale.write(snapshot); fatalError("stale volume accepted") } catch { checks += 1 }
        check(try FileManager.default.contentsOfDirectory(atPath:staleCard.path).isEmpty,"replacement mount never written")
        if CommandLine.arguments.count == 2 {
            let fixture = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
            try transfer.index.write(to:fixture.appendingPathComponent("index.dat"))
            for (name,data) in transfer.chunks { try data.write(to:fixture.appendingPathComponent(name)) }
        }
        print("PASS \(checks) WeRead official gateway, snapshot ABI and transactional TF checks; no account or hardware accessed")
    }
}
