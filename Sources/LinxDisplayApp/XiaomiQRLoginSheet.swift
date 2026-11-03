import SwiftUI

struct XiaomiQRLoginSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("扫码登录小米账号", systemImage: "qrcode").font(.headline)
                Spacer()
                Button("取消") { model.cancelXiaomiQRLogin() }.keyboardShortcut(.cancelAction)
            }
            if let image = model.xiaomiQRImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                ProgressView().frame(width: 260, height: 260)
            }
            Text(model.xiaomiQRStatus.isEmpty ? "请使用小米手机扫描二维码" : model.xiaomiQRStatus)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("扫码后若小米要求确认授权，软件会尝试自动完成；失败时会提示。")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 360)
    }
}
