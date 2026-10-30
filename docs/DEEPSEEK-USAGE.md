# DeepSeek 官方用量

多屏灵犀通过 DeepSeek 官方接口读取账户余额，并在用户提供平台网页会话令牌时补充 Token 与花费明细。数据只在本机请求和缓存，不上传到第三方。

## 数据来源

1. **官方余额（公开 API）**
   - `GET https://api.deepseek.com/user/balance`
   - 请求头：`Authorization: Bearer <API Key>`、`Accept: application/json`
   - 返回 `is_available` 与按币种拆分的 `balance_infos`：
     `total_balance`（总余额）、`granted_balance`（赠送余额）、`topped_up_balance`（充值余额）。
   - 存在多币种时优先显示有余额的 USD，否则显示有余额的币种；都为零时优先 USD。

2. **今日 / 本月用量（平台网页接口）**
   - `GET https://platform.deepseek.com/api/v0/usage/amount?month=<月>&year=<年>`
   - `GET https://platform.deepseek.com/api/v0/usage/cost?month=<月>&year=<年>`
   - 请求头：`Authorization: Bearer <平台 userToken>`、`Accept: application/json`、`x-client-platform: web`
   - 聚合每日 `PROMPT_CACHE_HIT_TOKEN`、`PROMPT_CACHE_MISS_TOKEN`、`RESPONSE_TOKEN` 与 `REQUEST`，得到今日 / 本月 Token、花费与请求数。
   - 这是平台网页使用的未公开接口，可能随官方改版而变化；失败时卡片自动退回“只显示官方余额”，不会展示估算值。

## 配置

在「DeepSeek 用量」面板填写：

- **DeepSeek API Key**：在 <https://platform.deepseek.com/api_keys> 创建，用于读取官方余额。
- **平台会话令牌（可选）**：登录 <https://platform.deepseek.com/usage> 后，从浏览器开发者工具的 Local Storage 复制 `userToken`。用于读取 Token 与花费明细。
- 两个字段都只保存在本机 `settings.json`，不会写日志，也不会随画板推送到设备。

## 显示口径

- 键盘卡片大数字显示账户余额；信息框显示今日花费、今日 Token、本月花费、本月 Token。
- 未提供平台令牌时，信息框显示赠送余额、充值余额与 API 可用状态。
- AI Mac / C6 方形画板使用专用高密度布局；灵犀画板窄条显示余额与今日花费。
- `is_available=false` 时卡片标记“API 不可用”，不会把余额误报成可用。
- 小纸 Pico 固件暂不支持该模块类型，Pico 画板编辑器会隐藏它；其他设备画板可正常使用。
