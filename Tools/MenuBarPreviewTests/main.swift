import AppKit

var count = 0
func check(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }
    count += 1
}

// AppKit view/layout contracts only; no app launch, live device or network.
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    for height: CGFloat in [76, 184, 300] {
        let view = MenuBarScreenPreview(imageAreaHeight: height)
        view.appearance = NSAppearance(named: appearance)
        view.show(image: nil, title: String(repeating: "工作室打印机", count: 15))
        check(view.frame.width == 264 && view.frame.height == height + 68, "Preview size")
        for child in view.subviews {
            check(view.bounds.contains(child.frame), "Subview exceeds preview bounds")
        }
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        check(labels.count == 2, "Header and explanatory label")
        check(labels.allSatisfy { ($0.font?.pointSize ?? 0) >= 11 }, "Readable system typography")
        let images = view.subviews.compactMap { $0 as? NSImageView }
        check(images.first?.imageScaling == .scaleProportionallyUpOrDown, "Preserve screen aspect ratio")
        let fixture = NSImage(size: NSSize(width: 142, height: 428))
        view.show(image: fixture, title: "正在播放")
        check(images.first?.image === fixture, "Reuse renderer image; no separate simulated frame")
        view.show(image: nil, title: "画面预览")
        check(images.first?.image == nil, "Release retained image when menu closes")
        let menu = NSMenu()
        let header = NSMenuItem(title: "画面预览", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.view = view
        menu.addItem(header)
        let action = NSMenuItem(title: "正在播放", action: Selector(("selectCard:")), keyEquivalent: "")
        action.state = .on
        menu.addItem(action)
        check(action.view == nil && action.state == .on, "Native selected command remains accessible")
    }
}
var fired = false
let timer = Timer(timeInterval: 0.01, repeats: false) { _ in fired = true }
RunLoop.main.add(timer, forMode: .eventTracking)
RunLoop.main.add(timer, forMode: .default)
let deadline = Date().addingTimeInterval(1)
while !fired && Date() < deadline { _ = RunLoop.main.run(mode: .eventTracking, before: deadline) }
check(fired, "Preview debounce fires during native menu tracking")
print("Menu preview AppKit contracts: \(count) passed")
