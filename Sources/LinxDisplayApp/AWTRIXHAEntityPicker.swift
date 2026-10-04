import LinxDisplayCore
import SwiftUI

/// AWTRIX 实时预览每 250ms 发布一次更新。只在打开选择器时读取实体目录，
/// 将检索、排序与勾选状态留在独立会话，避免随设备画面重新遍历数千个实体。
struct AWTRIXHAEntityAdder: View {
    let alreadyAdded: Set<String>
    let loadEntities: () -> [HAEntity]
    let onAddBatch: ([String]) -> Void

    @State private var session: AWTRIXHAEntityPickerSession?
    @State private var showPicker = false

    var body: some View {
        Button {
            session = AWTRIXHAEntityPickerSession(entities: loadEntities(), lockedIDs: alreadyAdded)
            showPicker = true
        } label: {
            HStack(spacing: 8) {
                Text("添加实体（可多选）")
                Spacer()
                Text("\(alreadyAdded.count) 个已选").foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            if let session {
                AWTRIXHAEntityPicker(session: session) { ids in
                    showPicker = false
                    onAddBatch(ids)
                }
                .equatable()
            }
        }
    }
}

@MainActor
private final class AWTRIXHAEntityPickerSession: ObservableObject {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let searchText: String
    }

    struct Group {
        let domain: String
        let title: String
        let entries: [Entry]
    }

    enum Row: Identifiable {
        case domain(String, String, Int)
        case entity(Entry)

        var id: String {
            switch self {
            case .domain(let domain, _, _): return "domain:" + domain
            case .entity(let entry): return "entity:" + entry.id
            }
        }
    }

    let lockedIDs: Set<String>
    let maximum = 8
    let entityCount: Int
    private let groups: [Group]
    private var filteredGroups: [Group]
    private var expandedDomains: Set<String> = []
    private var appliedKeyword = ""
    @Published private(set) var rows: [Row] = []
    @Published private(set) var checkedIDs: [String] = []

    init(entities: [HAEntity], lockedIDs: Set<String>) {
        self.lockedIDs = lockedIDs
        var seen: Set<String> = []
        let supported = entities.filter {
            let domain = HAEntityPicker.domain(of: $0.entityId)
            return domain != "camera" && domain != "image" && seen.insert($0.entityId).inserted
        }
        entityCount = supported.count
        let indexedGroups = HAEntityPicker.groupByDomain(supported).map { group in
            let title = HAEntityPicker.chineseDomain(group.domain)
            return Group(domain: group.domain, title: title, entries: group.entities.map {
                Entry(id: $0.entityId, name: $0.displayName,
                      searchText: [$0.entityId, $0.displayName, title].joined(separator: "\n").lowercased())
            })
        }
        groups = indexedGroups
        filteredGroups = indexedGroups
        rebuildRows()
    }

    var selectionIsFull: Bool { lockedIDs.count + checkedIDs.count >= maximum }

    func isExpanded(_ domain: String) -> Bool {
        !appliedKeyword.isEmpty || expandedDomains.contains(domain)
    }

    func toggleDomain(_ domain: String) {
        guard appliedKeyword.isEmpty else { return }
        if expandedDomains.contains(domain) { expandedDomains.remove(domain) }
        else { expandedDomains.insert(domain) }
        rebuildRows()
    }

    func toggleEntity(_ id: String) {
        guard !lockedIDs.contains(id) else { return }
        if let index = checkedIDs.firstIndex(of: id) { checkedIDs.remove(at: index) }
        else if !selectionIsFull { checkedIDs.append(id) }
    }

    func search(_ keyword: String) {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard keyword != appliedKeyword else { return }
        appliedKeyword = keyword
        if keyword.isEmpty {
            filteredGroups = groups
        } else {
            filteredGroups = groups.compactMap { group in
                let matches = group.entries.filter { $0.searchText.contains(keyword) }
                return matches.isEmpty ? nil : Group(domain: group.domain, title: group.title, entries: matches)
            }
        }
        rebuildRows()
    }

    private func rebuildRows() {
        rows = filteredGroups.flatMap { group -> [Row] in
            let header: Row = .domain(group.domain, group.title, group.entries.count)
            return isExpanded(group.domain) ? [header] + group.entries.map(Row.entity) : [header]
        }
    }
}

private struct AWTRIXHAEntityPicker: View, Equatable {
    @ObservedObject var session: AWTRIXHAEntityPickerSession
    let onConfirm: ([String]) -> Void
    @State private var keyword = ""

    /// 预览更新只改变父页面；当前选择器依靠自身搜索/勾选状态更新。
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.session === rhs.session }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称、entity_id 或分类", text: $keyword)
                    .textFieldStyle(.plain)
                if !keyword.isEmpty {
                    Button { keyword = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("清空搜索")
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            ScrollView {
                // 展开分类后仍是同一层惰性行，避免一次创建整个传感器分类的所有视图。
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.rows.isEmpty {
                        Text("无匹配实体").foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    ForEach(session.rows) { row in
                        switch row {
                        case .domain(let domain, let title, let count):
                            domainRow(domain, title: title, count: count)
                        case .entity(let entry):
                            entityRow(entry)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text("\(session.entityCount) 个候选 · 已选 \(session.lockedIDs.count + session.checkedIDs.count) / 8")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("确认添加") { onConfirm(session.checkedIDs) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(session.checkedIDs.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 520, height: 460)
        .task(id: keyword) {
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            session.search(keyword)
        }
    }

    private func domainRow(_ domain: String, title: String, count: Int) -> some View {
        Button { session.toggleDomain(domain) } label: {
            HStack(spacing: 6) {
                Image(systemName: session.isExpanded(domain) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                Text(title).fontWeight(.medium)
                if title != domain { Text(domain).font(.caption2).foregroundStyle(.secondary) }
                Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
    }

    private func entityRow(_ entry: AWTRIXHAEntityPickerSession.Entry) -> some View {
        let locked = session.lockedIDs.contains(entry.id)
        let checked = locked || session.checkedIDs.contains(entry.id)
        return Button { session.toggleEntity(entry.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 12)).lineLimit(1)
                    Text(entry.id).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if locked { Text("已添加").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 6)
            .padding(.leading, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked || (!checked && session.selectionIsFull))
    }
}
