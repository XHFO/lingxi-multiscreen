import AppKit

/// 设备画板预览效果图的 hero 背景资源（随应用打包在 Resources/）
enum PreviewResources {
    /// MindReset read_0 official front shell. The example book has been removed
    /// to leave a transparent, native-aspect window for the current device frame.
    static let readPicoHeroImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "read_pico_hero", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    static let readPicoHeroPixelSize = CGSize(width: 2000, height: 3499)
    /// Active screen in hero pixels, y measured upwards. Exactly 684:1216.
    static let readPicoHeroScreenRect = CGRect(x: 119, y: 275, width: 1746, height: 3104)

    /// M5Stack StickS3 正面产品图；背景已透明，用于控制器主页面与按键提示预览。
    static let m5StickS3Image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "m5-sticks3-cutout", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    /// 摘录画板：quote_0 官方 hero 图（2000×671 横版）
    static let heroImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "quote_0_hero", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    /// quote_0 hero 图中屏幕显示区域的像素矩形（与 296×152 屏幕 1:1 对应，y 自底部向上）
    static let heroScreenRect = CGRect(x: 117, y: 108, width: 885, height: 452)

    /// 口袋先知画板：Rand/0 设备 hero 图（2000×2403 竖版）
    static let oracleHeroImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "rand0_hero", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    /// Rand/0 hero 图中屏幕显示区域的像素矩形（与 200×200 屏幕 1:1 对应，y 自底部向上；
    /// 用户已将屏幕区域标为纯黑便于精确定位）
    static let oracleHeroScreenRect = CGRect(x: 518, y: 899, width: 968, height: 976)

    /// Rand/0 屏幕圆角半径（hero 像素，实测约 60px），用于给画布加匹配的圆角遮罩
    static let oracleHeroScreenCornerRadius: CGFloat = 60
}
