import AppKit
import LinxDisplayCore
import SwiftUI

/// Adds the shared source library to the existing Oracle/Excerpt image service.
/// Device transport and final grayscale conversion remain owned by AppModel.
@MainActor
struct SharedCanvasWallpaperButton: View {
    @ObservedObject var model: AppModel
    let owner: AppModel.CanvasOwner
    @State private var showPicker = false
    @State private var capturedContext: SharedCanvasWallpaperContext?
    @State private var pending: SharedCanvasWallpaperSelection?
    @State private var editing: SharedCanvasWallpaperSelection?

    var body: some View {
        Button("从壁纸库选择…") {
            guard let context = SharedCanvasWallpaperContext.capture(model: model, owner: owner) else { return }
            capturedContext = context; pending = nil; showPicker = true
        }
        .disabled(SharedCanvasWallpaperContext.capture(model: model, owner: owner) == nil)
        .sheet(isPresented: $showPicker, onDismiss: {
            if let pending { editing = pending; self.pending = nil }
            capturedContext = nil
        }) {
            SharedWallpaperPicker(title: "选择画板图片") { asset, image in
                guard let context = capturedContext else { return }
                pending = SharedCanvasWallpaperSelection(context: context, asset: asset, image: image)
            }
        }
        .sheet(item: $editing) { selection in
            SharedCanvasWallpaperEditor(model: model, selection: selection)
        }
    }
}

private struct SharedCanvasWallpaperContext {
    let owner: AppModel.CanvasOwner
    let deviceID: UUID
    let boardID: UUID
    let target: PicoPreviewTarget
    var key: String { "device.\(deviceID.uuidString).module.\(boardID.uuidString)" }

    @MainActor static func capture(model: AppModel, owner: AppModel.CanvasOwner) -> Self? {
        switch owner {
        case .oracle:
            let index = model.settings.oracleCanvasBoardIndex
            guard let id = model.activeDeviceID(for: .oracle), model.settings.oracleCanvasBoards.indices.contains(index),
                  PicoPreviewTarget.oracle.size == CGSize(width: ScreenRenderer.oracleCanvasSize, height: ScreenRenderer.oracleCanvasSize) else { return nil }
            return Self(owner: owner, deviceID: id, boardID: model.settings.oracleCanvasBoards[index].id, target: .oracle)
        case .excerpt:
            let index = model.settings.excerptCanvasBoardIndex
            guard let id = model.activeDeviceID(for: .excerpt), model.settings.excerptCanvasBoards.indices.contains(index),
                  PicoPreviewTarget.excerpt.size == CGSize(width: ScreenRenderer.excerptCanvasWidth, height: ScreenRenderer.excerptCanvasHeight) else { return nil }
            return Self(owner: owner, deviceID: id, boardID: model.settings.excerptCanvasBoards[index].id, target: .excerpt)
        case .keyboard, .aiMac: return nil
        }
    }
    @MainActor func isCurrent(in model: AppModel) -> Bool {
        guard let current = Self.capture(model: model, owner: owner) else { return false }
        return current.deviceID == deviceID && current.boardID == boardID && current.target == target
    }
}
private struct SharedCanvasWallpaperSelection: Identifiable {
    let id = UUID()
    let context: SharedCanvasWallpaperContext
    let asset: PicoNativeAsset
    let image: NSImage
}

@MainActor private struct SharedCanvasWallpaperEditor: View {
    @ObservedObject var model: AppModel
    let selection: SharedCanvasWallpaperSelection
    @ObservedObject private var library = PicoNativeLibrary.shared

    var body: some View {
        let use = library.use(for: selection.context.key)
        PicoPhotoEditor(image: selection.image, target: selection.context.target,
                        initial: use?.assetID == selection.asset.id ? use?.edit : nil,
                        applicationNote: "应用到当前画板，保留原图；显示模式与设备推送继续使用原有设置。",
                        apply: { edit in try await apply(edit) })
    }

    private func apply(_ edit: PicoPhotoEdit) async throws {
        guard selection.context.isCurrent(in: model) else {
            throw ReadPicoManagerError.invalid("当前设备或画板已改变，请在要编辑的画板中重新选择图片。")
        }
        let composed = PicoPhotoRenderer.composeColor(image: selection.image, edit: edit, target: selection.context.target)
        guard let cg = composed.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width == Int(selection.context.target.size.width), cg.height == Int(selection.context.target.size.height),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw ReadPicoManagerError.invalid("无法生成裁剪图片，当前画板保持原来的图片。")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-shared-wallpaper-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try png.write(to: temporary, options: .atomic)
        guard selection.context.isCurrent(in: model) else {
            throw ReadPicoManagerError.invalid("设备或画板已改变，请重新选择图片。")
        }
        try library.commitUse(assetID: selection.asset.id, key: selection.context.key, target: selection.context.target, edit: edit) {
            try model.setSharedCanvasImage(url: temporary, displayName: selection.asset.name, owner: selection.context.owner)
        }
        model.status = "已从壁纸库更新当前画板图片；设备推送沿用此画板的设置。"
    }
}
