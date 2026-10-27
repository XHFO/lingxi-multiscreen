import AppKit
import LinxDisplayCore
import SwiftUI

/// Official shelf/notes setup stays with its optional app, using the device workspace's USB owner.
/// 官方书架与笔记的配置放在可选应用旁，设备写入仍由工作台统一协调。
struct ReadPicoWeReadView: View {
    @ObservedObject var model: ReadPicoManagerModel
    private let onBusyChange: ((Bool) -> Void)?
    @State private var expanded = false
    @State private var key = ""
    @State private var books: [ReadPicoWeReadBook] = []
    @State private var selection = Set<String>()
    @State private var preview: ReadPicoWeReadSnapshot?
    @State private var message = "在 Mac 授权后，选择书籍，将个人划线和想法同步到 TF 卡。"
    @State private var failure = false
    @State private var loading = false
    @State private var task: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var showsPhoneGuide = false
    @State private var manualAuthorization = false
    @State private var phoneGuide: ReadPicoWeReadPhoneGuideModel?

    init(model: ReadPicoManagerModel, onBusyChange: ((Bool) -> Void)? = nil, initialExpanded: Bool = false,
         initialBooks: [ReadPicoWeReadBook] = [], initialSelection: Set<String> = [],
         initialPreview: ReadPicoWeReadSnapshot? = nil, initialMessage: String? = nil) {
        self.model = model
        self.onBusyChange = onBusyChange
        _expanded = State(initialValue: initialExpanded); _books = State(initialValue: initialBooks)
        _selection = State(initialValue: initialSelection); _preview = State(initialValue: initialPreview)
        if let initialMessage { _message = State(initialValue: initialMessage) }
    }

    var body: some View {
        DisclosureGroup("微信读书 · 书架与笔记", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 16) {
                Text("这是独立的离线应用，可查看书架、划线和想法。微信读书官方接口尚不提供整书正文下载。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                credentialControls
                if !books.isEmpty {
                    HStack {
                        Text("选择书籍").font(.headline)
                        Spacer()
                        Text("已选 \(selection.count) / 64").monospacedDigit().foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            bookList.frame(minWidth: 260, maxWidth: .infinity)
                            notePreview.frame(width: 280)
                        }
                        VStack(alignment: .leading, spacing: 16) { bookList; notePreview }
                    }
                    HStack {
                        Button("读取所选笔记") { loadNotes() }
                            .disabled(selection.isEmpty || loading || model.busy)
                        Spacer()
                        Button("同步到 Pico", systemImage: "arrow.triangle.2.circlepath") {
                            if let preview { model.syncWeRead(preview) }
                        }.buttonStyle(.borderedProminent)
                            .disabled(preview == nil || model.store == nil || loading || model.busy || !moduleInstalled)
                    }
                }
                if !moduleInstalled {
                    Label("先在上方添加「微信读书 · 书架与笔记」功能包。", systemImage: "square.and.arrow.down")
                        .font(.callout).foregroundStyle(.secondary)
                } else if model.store == nil {
                    Label("离线笔记需通过 USB 同步，请连接上方的 TF 文件管理。", systemImage: "cable.connector")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    if loading { ProgressView().controlSize(.small).accessibilityLabel("正在读取微信读书资料") }
                    Label(message, systemImage: failure ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(failure ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if loading { Button("取消") { cancel() } }
                }.font(.callout)
            }.padding(.top, 12)
        }
        .onChange(of: selection) { _, _ in preview = nil }
        .onChange(of: loading || showsPhoneGuide, initial: true) { _, value in onBusyChange?(value) }
        .sheet(isPresented: $showsPhoneGuide, onDismiss: {
            phoneGuide?.cancel(); phoneGuide = nil
        }) {
            if let phoneGuide { ReadPicoWeReadPhoneGuideView(model: phoneGuide) }
        }
        .onDisappear {
            // Revoke the phone session before the presentation's asynchronous teardown.
            phoneGuide?.cancel(); showsPhoneGuide = false; phoneGuide = nil
            cancel(); key = ""
            onBusyChange?(false)
        }
    }
    private var moduleInstalled: Bool {
        model.files.contains { $0.relativePath == "apps/tools/weread.pga" && $0.valid }
    }
    private var credentialControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("授权微信读书").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { primaryCredentialActions }
                VStack(alignment: .leading, spacing: 12) { primaryCredentialActions }
            }
            Text("手机与 Mac 连接同一个网络，扫码打开配置页填写 API Key。已有授权可直接读取书架。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("在这台 Mac 填写", isExpanded: $manualAuthorization) {
                VStack(alignment: .leading, spacing: 10) {
                    Link("获取微信读书官方 API Key ↗", destination: ReadPicoWeReadSecretStore.authorizationURL)
                    keyField
                    Button("保存授权") {
                        do { try ReadPicoWeReadSecretStore.save(key); authorizationSaved() }
                        catch { fail(error) }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("粘贴 wrk- 开头的密钥。密钥仅加密保存在本机，多台 Pico 共用此授权。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 10)
            }
        }.disabled(loading || model.busy || showsPhoneGuide)
    }
    private var keyField: some View {
        SecureField("粘贴新的 API Key，或使用已保存的授权", text: $key)
            .textFieldStyle(.roundedBorder).accessibilityLabel("微信读书官方 API Key")
    }
    @ViewBuilder private var primaryCredentialActions: some View {
        Button("手机扫码授权", systemImage: "qrcode") {
            key = ""
            phoneGuide = ReadPicoWeReadPhoneGuideModel(onAuthorized: { authorizationSaved() })
            showsPhoneGuide = true
        }.buttonStyle(.borderedProminent)
        Button("读取书架") { loadShelf() }
        Menu {
            Button("移除 Mac 上的授权", role: .destructive) {
                do { try ReadPicoWeReadSecretStore.remove(); key = ""; clearAccountContent(); failure = false; message = "已移除授权，设备中的离线笔记仍保留。" }
                catch { fail(error) }
            }
        } label: { Image(systemName: "ellipsis.circle") }.help("授权选项").accessibilityLabel("授权选项")
    }
    private func authorizationSaved() {
        key = ""; clearAccountContent(); failure = false
        message = "授权已加密保存到本机，可读取书架并选择书籍。"
    }
    private var bookList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(books) { book in
                    Toggle(isOn: Binding(get: { selection.contains(book.id) }, set: { selected in
                        if selected && selection.count < 64 { selection.insert(book.id) }
                        else if !selected { selection.remove(book.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title).font(.body).lineLimit(2)
                            if !book.author.isEmpty { Text(book.author).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }.toggleStyle(.checkbox)
                        .disabled(loading || (!selection.contains(book.id) && selection.count >= 64))
                }
            }.padding(8)
        }.frame(height: 250).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
    private var notePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("离线内容预览", systemImage: "text.book.closed").font(.headline)
            if let preview {
                Text("\(preview.books.count) 本书 · \(preview.noteCount) 条划线与想法").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(preview.books, id: \.book.id) { item in
                            Text(item.book.title).font(.headline)
                            if item.notes.isEmpty { Text("这本书暂无个人笔记").foregroundStyle(.secondary) }
                            ForEach(Array(item.notes.prefix(3))) { note in
                                VStack(alignment: .leading, spacing: 4) {
                                    if !note.chapter.isEmpty { Text(note.chapter).font(.caption).foregroundStyle(.secondary) }
                                    if !note.quote.isEmpty { Text(note.quote).lineLimit(5) }
                                    if !note.text.isEmpty { Text(note.text).lineLimit(5) }
                                }.font(.body)
                            }
                            if item.notes.count > 3 { Text("还有 \(item.notes.count - 3) 条，同步后可在设备查看").font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                }.frame(height: 210)
            } else {
                Text("勾选书籍并读取笔记后，在这里核对将同步的内容。").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func client() throws -> ReadPicoWeReadClient {
        // Uncommitted credentials never silently replace an existing account.
        guard key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadPicoWeReadError.storage("请先保存新的授权，再读取书架。")
        }
        return try ReadPicoWeReadClient(apiKey: ReadPicoWeReadSecretStore.read())
    }
    private func loadShelf() {
        guard !loading else { return }
        do {
            let client = try client(); begin("正在读取微信读书书架…")
            let id = requestID
            task = Task { @MainActor in
                do {
                    let shelf = try await client.fetchShelf(); try Task.checkCancellation()
                    guard requestID == id else { return }
                    books = shelf.books; selection.formIntersection(Set(books.map(\.id))); preview = nil
                    message = books.isEmpty ? "书架中没有可同步的电子书。" : "已读取 \(books.count) 本电子书，请选择要离线查看笔记的书籍。"
                    if shelf.albumCount > 0 || shelf.hasArticles { message += "听书专辑和文章收藏暂不支持离线笔记同步。" }
                } catch { if requestID == id { fail(error) } }
                if requestID == id { loading = false; task = nil }
            }
        } catch { fail(error) }
    }
    private func loadNotes() {
        guard !loading, !selection.isEmpty else { return }
        do {
            let client = try client(), chosen = books.filter { selection.contains($0.id) }
            begin("正在读取所选书籍的个人划线与想法…"); let id = requestID
            task = Task { @MainActor in
                do {
                    let value = try await client.fetchSnapshot(books: chosen, progress: { done, total in
                        Task { @MainActor in
                            if requestID == id && loading { message = "正在读取笔记 \(done) / \(total)…" }
                        }
                    })
                    try Task.checkCancellation(); guard requestID == id else { return }
                    preview = value; message = "已准备 \(value.books.count) 本书、\(value.noteCount) 条笔记。核对后同步到 Pico。"
                } catch { if requestID == id { fail(error) } }
                if requestID == id { loading = false; task = nil }
            }
        } catch { fail(error) }
    }
    private func begin(_ text: String) { requestID = UUID(); loading = true; failure = false; message = text }
    private func clearAccountContent() { books = []; selection = []; preview = nil }
    private func fail(_ error: Error) {
        failure = !(error is CancellationError); message = failure ? error.localizedDescription : "已取消读取，设备中的离线资料仍保留。"
    }
    private func cancel() {
        guard loading else { return }; requestID = nil; task?.cancel(); task = nil; loading = false
        failure = false; message = "已取消读取，设备中的离线资料仍保留。"
    }
}
