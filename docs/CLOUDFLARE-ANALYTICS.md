# Cloudflare 网站统计

在软件左侧打开「设备管理」，在「共享数据源」中添加 Cloudflare。流程与添加设备一致：先查看 Token 获取引导，再连接 Cloudflare、选择网站、验证统计并确认添加。之后在卡片管理中添加「Cloudflare 网站统计」，或在灵犀画板中添加同名模块。小纸 Pico、口袋先知、摘录以及支持软件图像卡片的设备共享当前选中的数据源。

## 获取与连接 Token

1. 点击向导中的「打开预配置创建页」。软件使用 Cloudflare 官方模板 URL 自动填写名称“多屏灵犀网站统计”及两项只读权限：**Zone → Analytics → Read**（网站统计）、**Zone → Zone → Read**（列出授权网站）。无需逐项选择权限。
2. 登录后，在 **Zone Resources** 中选择 **Include → Specific zone**，添加要展示的网站。链接不填写 `accountId=*` 或 `zoneId=all`；网站范围由你在 Cloudflare 确认。
3. 点击 **Continue to summary**，核对权限与网站范围后再点击 **Create Token**。复制完整 Token，返回软件点击「已有 Token，继续」。Token secret 只显示一次。
4. 已有 Token 可直接继续，无需重新创建。若 Cloudflare 没有应用模板参数，普通 [API Tokens 管理页](https://dash.cloudflare.com/profile/api-tokens/)和完整权限说明仍可作为手动入口。使用 API Token，不使用 Global API Key 或账户密码。
5. 软件读取网站列表并选择目标网站。若手动创建时未授予 Zone Read 权限，也可直接填写 32 位 Zone ID：打开 Cloudflare 目标网站的 **Overview（概述）**，在右侧 API 区域复制。接下来仍须实际读取该网站的 Analytics，验证成功后才可完成添加。

预配置链接只含公开权限模板和软件名称，不携带 Token、用户标识或站点信息，也不会自动创建凭据。参数格式依据 [Cloudflare API token template URLs 官方说明](https://developers.cloudflare.com/fundamentals/api/how-to/account-owned-token-template/)。

向导内提供相同引导和 [Cloudflare 官方文档](https://developers.cloudflare.com/analytics/graphql-api/getting-started/authentication/api-token-auth/)入口。官方 GraphQL 通用教程还包含账户级 Account Analytics 权限；这里采用网站级只读权限并限制具体站点。实际统计是否可读还受站点、套餐和数据集限制。

直到最后点击「添加数据源」或「保存修改」才会写入设置和 本机加密凭据文件。取消、返回或验证失败不会保存 Token。编辑时可保留已有凭据，Token 不会回填显示；替换失败时保留原凭据。Token 不包含在配置导出、画板原稿或设备图片中。

## 管理与显示

可以添加多个来源，分别命名、编辑和移除，并选择「使用此数据源」。当前全部 Cloudflare 卡片共用一个活动源，各设备会一起显示该来源；尚不支持每张卡片独立绑定不同来源。移除当前来源时自动使用剩余来源，没有剩余来源时等待重新添加。仍被其他来源引用的加密凭据不会随某一个来源移除而删除。

旧版单站点配置会自动迁移为一个数据源，并保留原 Zone、显示选项、统计缓存和凭据引用；无需重新粘贴 Token。未配置的空白设置不会生成占位数据源。卡片或画板模块设置中可选择活动源，调整显示选项，连接凭据统一在「设备管理 → 共享数据源」维护，不再混在日常显示选项里。

选择最近 24 小时、7 天或 30 天，可填写子域名筛选，例如 `www.example.com`。留空时统计整个 Zone。请求数表示 Cloudflare 边缘收到的客户端 HTTP 请求，包含资源和机器人请求，不是独立访客人数。流量使用边缘响应字节数，地区根据客户端 IP 统计，支持按流量或请求数排名。统计采用 Cloudflare 自适应 Analytics，可能经过采样；数据集和历史范围取决于账户套餐。

展示样式可选「全球热区」与「地区排行」。全球热区以世界点阵地图突出活跃地区，点的大小与深浅表示相对热度；小纸 Pico 输出 16 灰阶。地图按国家／地区汇总，尺寸较小的卡片优先保留指标。[底图来源与展示边界](CLOUDFLARE-WORLD-MAP.md)。

「数据源与显示 → 域名大小写」提供原样、小写、大写三种呈现。此选项随数据源保存并作用于原生工作台及设备渲染，不改写域名筛选、不清除缓存，也不触发额外统计请求。旧设置默认维持原样。

显示语言可在「中文 / English」间切换，工作台文案、设备看板标题、指标说明、地区名及更新时间一起切换；横竖两版使用同一语言。语言随数据源保存，默认中文，不影响系统其他页面的语言。Cloudflare 品牌、网站域名和标准计量单位保留原样。

原生工作台以 Cloudflare 橙色强调品牌和图表；Pico 继续使用纯 16 灰阶。横竖版使用简短的 REQ、TRAFFIC 与时间范围标签，给域名、数值和点阵地图留出独立空间。请求数仍表示请求次数，不代表访客人数。

软件每 5 至 60 分钟更新一次统计，设备推送仍沿用各设备自己的自动推送策略。断网、权限或范围错误保留上次数据并显示更新时间，缓存不会套用到另一站点、子域名或时间范围。切换数据源、替换 Token 或取消向导后，不接受先前请求的迟到结果。

Cloudflare 接入只发生在 Mac，Pico 固件不保存 API Token。Pico 渲染仍使用原生分辨率和 16 灰阶路径。

客户端回归可运行：`sh Tools/run-cloudflare-analytics-tests.sh`。向导草稿和凭据事务回归可运行：`sh Tools/run-cloudflare-source-draft-tests.sh`，覆盖未验证不可完成、取消零写入、保存失败回滚和共享凭据保留。这些测试使用本地响应和注入函数，不访问真实账户、用户设置或用户凭据目录；真实站点读数需要配置自己的授权。
