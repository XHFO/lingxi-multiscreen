import SwiftUI

/// 1 = 半宽，2 = 整行。半宽实体两两配对；单独剩下一个半宽时自动铺满整行，
/// 让「半宽 + 整行 + 半宽 + 半宽」这类任意组合也能紧密填充，不留下空洞。
struct HAEntityTileSpanKey: LayoutValueKey {
    static let defaultValue = 1
}

struct HAEntityFlowLayout: Layout {
    let tileHeight: CGFloat
    let gap: CGFloat

    private func frames(spans: [Int], width: CGFloat) -> [CGRect] {
        guard !spans.isEmpty, width > 0 else { return [] }
        let unit = max((width - gap) / 2, 0)
        var result: [CGRect] = []
        var row: [Int] = []
        var rowY: CGFloat = 0

        func flushRow() {
            guard !row.isEmpty else { return }
            if row.count == 1 {
                let index = row[0]
                result.append(CGRect(x: 0, y: rowY, width: width, height: tileHeight))
                _ = index
            } else {
                let first = row[0], second = row[1]
                result.append(CGRect(x: 0, y: rowY, width: unit, height: tileHeight))
                result.append(CGRect(x: unit + gap, y: rowY, width: unit, height: tileHeight))
                _ = (first, second)
            }
            row.removeAll()
            rowY += tileHeight + gap
        }

        for (index, span) in spans.enumerated() {
            if span >= 2 {
                flushRow()
                result.append(CGRect(x: 0, y: rowY, width: width, height: tileHeight))
                rowY += tileHeight + gap
            } else {
                row.append(index)
                if row.count == 2 { flushRow() }
            }
        }
        flushRow()
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let spans = subviews.map { $0[HAEntityTileSpanKey.self] }
        let rects = frames(spans: spans, width: width)
        let height = rects.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let spans = subviews.map { $0[HAEntityTileSpanKey.self] }
        let rects = frames(spans: spans, width: bounds.width)
        for (index, rect) in rects.enumerated() where index < subviews.count {
            subviews[index].place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                                  anchor: .topLeading,
                                  proposal: .init(width: rect.width, height: rect.height))
        }
    }
}
