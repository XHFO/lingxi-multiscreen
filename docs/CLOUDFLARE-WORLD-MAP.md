# Cloudflare 全球热区点阵

Cloudflare 网站统计提供「全球热区」与「地区排行」两种展示。全球热区使用真实国家／地区汇总数据，点的尺寸与深浅按所选请求数或流量相对峰值变化。支持彩色设备时沿用卡片主题强调色，小纸 Pico 接收语义数据，在设备本地按 684×1216 竖屏或 1216×684 横屏布局并以原生 16 灰阶显示；地图不依赖动画表达热度。

地图是国家／地区级示意，不代表城市或单个访问者的位置。未定位、没有可表示位置的地区仍参与地区排行，并在地图说明中列出数量，不为它们生成虚构位置。很小的卡片优先保留请求数和流量；版面足够时保留地图、排行与趋势。

底图由 [Natural Earth](https://www.naturalearthdata.com/about/terms-of-use/) 1:110m 国家边界生成。Natural Earth 数据属于公有领域。使用的 [GeoJSON 源文件](https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson) SHA-256 为 `6866c877d39cba9c357620878839b336d569f8c662d3cfab4cb1dbe2d39c977f`。

`scripts/build-cloudflare-world-dots.py` 从显式传入的本地 GeoJSON 生成 `CloudflareWorldDots.swift`，以 120×52 网格和小岛锚点生成离线图形。细小地区使用邻近的独占网格，避免多个地区叠在同一像素而夸大热度。运行时不下载底图、不接入地图 SDK。视觉方向参考网络流量地图，图形与排版自行实现，不使用 Cloudflare 的前端代码或地图资产。

`Tools/run-cloudflare-renderer-review.sh` 复用生产渲染方法，检查两种展示、请求／流量模式及不同尺寸的 CoreText 字形范围、文本重叠、趋势时间轴和像素边界。测试数据为固定样本，不代表真实站点统计。

小纸 Pico 的信息卡片从 0.40.0-dev71 起不再由电脑生成横竖两张整屏截图。Mac 发送有界 schema 1 数据快照，包括指标、地区汇总、趋势、字号、跨列和展示偏好；设备在方向改变时重新排版。纯图片和手绘仍使用原分辨率双方向位图。

全球热区使用同源的 `Resources/PicoBoard/cloudflare-world-dots.bwm`（4,588 字节），其格式、SHA-256 和来源记录在同目录 `board-resources.json`。Mac 只在全球热区模型中把该几何资源编码进 `world_map`；设备严格校验格式、大小和 CRC，与模型原子保存。它不含界面截图，也不要求用户另行安装地图文件。

Mac 的原生预览复用 `Sources/CPicoBoardRenderer` 中与固件逐字节相同的 C 解析器和排版器，通过 CoreGraphics/CoreText 绘制；预览最终量化到 16 灰阶。物理设备的字形由设备字库绘制，布局与数据协议共用。新专项回归验证横竖屏尺寸、灰阶、时区、字号、跨列、地图／排行和媒体排布，并把 Swift 编码的真实模型交给固件 C 解析器核验。旧的 `run-cloudflare-renderer-review.sh` 继续覆盖其他设备的电脑端渲染。
