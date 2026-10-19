import AppKit

/// Only this noninteractive header is custom. All commands remain native menu
/// items so AppKit handles selection, arrows, Return, checkmarks and VoiceOver.
final class MenuBarScreenPreview: NSView {
    private let caption = NSTextField(labelWithString: "画面预览")
    private let imageView = NSImageView()
    private let note = NSTextField(labelWithString: "悬停预览 · 点击切换")

    init(imageAreaHeight: CGFloat = 184) {
        let height = imageAreaHeight + 68
        super.init(frame: NSRect(x: 0, y: 0, width: 264, height: height))
        caption.font = .menuFont(ofSize: 13)
        caption.textColor = .labelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.frame = NSRect(x: 16, y: height - 27, width: 232, height: 19)
        imageView.frame = NSRect(x: 16, y: 34, width: 232, height: imageAreaHeight)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("卡片画面预览")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 16, y: 9, width: 232, height: 18)
        addSubview(caption)
        addSubview(imageView)
        addSubview(note)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func show(image: NSImage?, title: String, explanation: String? = nil) {
        caption.stringValue = title
        imageView.image = image
        imageView.setAccessibilityLabel("\(title)画面预览")
        note.stringValue = explanation ?? (image == nil ? "暂无画面 · 点击卡片可切换" : "悬停预览 · 点击切换")
    }
}
