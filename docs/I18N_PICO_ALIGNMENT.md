# Mac ↔ Pico i18n key alignment

Date: 2026-10-26 (Asia/Shanghai). Branch: `local/2.0-land-pr1-homelink`.
Source Pico list: `XHFO/lingxi-readpico-private` `cursor/firmware-i18n-zh-en-69be` → `read_pico_firmware_slices/docs/I18N_KEY_LIST.md` (~302 keys).

## Approach

- Keep Mac String Catalog as-is: `Resources/Localization/zh-Hans.lproj` + `en.lproj`, development language Chinese for Mac-only chrome.
- For **overlapping concepts** on the ReadPico manager / Home Link / lock-style surface, adopt Pico **dotted keys** and Pico zh/en wording.
- Chinese keys remain as **aliases** in `en.lproj` so unmigrated `String(localized: "中文")` / SwiftUI `Text("中文")` call sites do not regress.
- Shared keys are centralized in `Sources/LinxDisplayCore/L10n.swift` (`PicoKeys`).

## Renamed (call sites now use Pico dotted keys)

| Was (Mac concept) | Pico key | Where |
|---|---|---|
| 本地地址 | `settings.home_link.field.local` | ReadPicoManagerView Home Link form |
| 家庭 Wi-Fi | `settings.home_link.field.wifi` | ReadPicoManagerView Home Link form |
| 访问令牌 | `settings.home_link.field.token` | ReadPicoManagerView Home Link form; en→HA token |
| 外部地址 | `settings.home_link.field.external` | ReadPicoManagerView; en→External HTTPS |
| CF Access 客户端 ID | `settings.home_link.field.cf_id` | ReadPicoManagerView |
| CF Access 客户端密钥 | `settings.home_link.field.cf_secret` | ReadPicoManagerView |
| 翻页时钟 | `settings.power.style.clock` | ReadPicoLockScreenView style picker |
| 划线摘录 | `settings.power.style.quotes` | ReadPicoLockScreenView style picker |
| 书库封面 | `settings.power.style.covers` | ReadPicoLockScreenView; zh→藏书封面, en→Covers |
| 保持当前页面 | `settings.power.style.page` | ReadPicoLockScreenView; en→Keep page |
| 自定义图片 (lock style only) | `settings.power.style.image` | ReadPicoLockScreenView index 4 only |

**Count renamed at call sites:** 11

## Shared-concept but left Mac-only (skipped)

| Mac string / surface | Pico key (if any) | Reason |
|---|---|---|
| 充电时显示灵犀画板 | `settings.power.style.board` | Mac clarifies charging behavior; Pico label is shorter「灵犀画板」/Lingxi board. Left Mac-only at lock style index 5. |
| 灵犀画板 (sidebar / CardKind) | `settings.power.style.board` | Mac chrome title is「Linx Canvas」; Pico board style is「Lingxi board」. Different product surfaces. |
| 自定义图片 (CardKind / AI Mac) | `settings.power.style.image` | Same Chinese phrase, different Mac card chrome — keep Chinese key. |
| 打印机 (Bambu/Formlabs card titles) | `nav.printers / settings.home_link.printers` | Mac uses singular「Printer」for device cards; Pico「Printers」is Home nav. Not force-renamed. |
| 取消 / 完成 / 返回 / 设置 / 保存 / 同步 / 刷新 | `common.* / settings.home_link.* / launcher.refresh` | Ubiquitous Mac chrome (sidebar, CF, C6, menus). Keys listed in tables for future shared use; call sites not globally renamed. |
| 开启 Home Assistant / 保存到阅读器 / 电源与唤醒 / 自动休眠 / … | `settings.home_link.on / save / settings.power.*` | Mac manager copy is longer and action-specific; Pico strings are device-chrome short labels. |
| 图片锁屏 / 小纸 Pico / 设备设置 | `—` | Mac-only IA; no Pico dotted equivalent in shared list for these manager chrome titles. |
| 关闭 (window Close) | `settings.home_link.off / settings.power.auto.off` | Mac「关闭」=Close; Pico off=Off. Ambiguous — not remapped. |

**Count skipped:** 8

## Pico keys catalogued on Mac (tables) but not wired to UI this pass

These exist in zh-Hans + en `Localizable.strings` for future shared use:

- `common.back`
- `common.cancel`
- `common.confirm`
- `common.done`
- `common.next`
- `common.prev`
- `launcher.refresh`
- `nav.apps`
- `nav.books`
- `nav.home`
- `nav.printers`
- `settings.home_link.monitor`
- `settings.home_link.off`
- `settings.home_link.on`
- `settings.home_link.printers`
- `settings.home_link.save`
- `settings.home_link.saved_toast`
- `settings.home_link.settings_title`
- `settings.home_link.setup_sub`
- `settings.home_link.setup_title`
- `settings.home_link.unset`
- `settings.power.auto.m1`
- `settings.power.auto.m10`
- `settings.power.auto.m3`
- `settings.power.auto.m30`
- `settings.power.auto.m5`
- `settings.power.auto.off`
- `settings.power.style.board`
- `settings.power.title`

## Pico keys not used on Mac

Firmware / device-only chrome (Wi-Fi stack, transfer, manage QR, power toasts, dialog.wifi, most launcher/nav settings, full home_link empty/monitor status formatters, etc.). Total Pico keys: **302**. Catalogued on Mac this pass: **40**. Not used on Mac: **262**.

Full unused list (for grep):

- `settings.locale.chip`
- `settings.locale.saved`
- `settings.locale.save_failed`
- `nav.games`
- `settings.nav.title`
- `settings.nav.hint`
- `settings.nav.hint_settings`
- `settings.nav.add_title`
- `settings.nav.replace_title`
- `settings.nav.shown`
- `settings.nav.missing`
- `settings.nav.up`
- `settings.nav.down`
- `settings.nav.replace`
- `settings.nav.hide`
- `settings.nav.add`
- `settings.nav.reset`
- `settings.nav.keep_one`
- `settings.nav.keep_usable`
- `settings.nav.already`
- `settings.nav.full`
- `settings.nav.none_left`
- `settings.nav.save_failed`
- `launcher.title`
- `launcher.summary`
- `launcher.settings`
- `launcher.source.settings`
- `launcher.source.system`
- `launcher.source.tf_app`
- `launcher.source.tf_game`
- `settings.power.menu`
- `settings.power.off`
- `settings.power.restart`
- `settings.power.lock`
- `settings.power.lock_now`
- `settings.power.sleep`
- `settings.power.confirm_off`
- `settings.power.confirm_restart`
- `settings.power.auto`
- `settings.power.awake`
- `settings.power.doubletap.on`
- `settings.power.doubletap.off`
- `settings.power.doubletap.hint`
- `settings.power.appearance`
- `settings.power.rotation.on`
- `settings.power.rotation.off`
- `settings.power.hint`
- `settings.power.save_failed`
- `settings.power.cover_save_failed`
- `settings.power.locked.doubletap`
- `settings.power.locked.key`
- `settings.power.sleeping`
- `settings.power.off_state`
- `settings.power.low_power`
- `settings.power.restarting`
- `settings.power.toast.storage`
- `settings.power.toast.storage_transfer`
- `settings.power.toast.weread`
- `settings.power.toast.memory`
- `settings.power.toast.progress`
- `settings.power.toast.unsaved`
- `settings.power.toast.home`
- `settings.power.toast.network`
- `settings.power.toast.off_failed`
- `settings.power.toast.off_paint`
- `settings.power.toast.lock_failed`
- `settings.wifi.title`
- `settings.wifi.on`
- `settings.wifi.off`
- `settings.wifi.nearby`
- `settings.wifi.saved`
- `settings.wifi.scanning`
- `settings.wifi.rescan`
- `settings.wifi.add`
- `settings.wifi.transfer`
- `settings.wifi.detail`
- `settings.wifi.connect`
- `settings.wifi.connected`
- `settings.wifi.password`
- `settings.wifi.auto.on`
- `settings.wifi.auto.off`
- `settings.wifi.forget`
- `settings.wifi.forget_short`
- `settings.wifi.security.pass`
- `settings.wifi.security.open`
- `settings.wifi.state.preparing`
- `settings.wifi.state.disabled`
- `settings.wifi.state.connecting`
- `settings.wifi.state.connected`
- `settings.wifi.state.searching`
- `settings.wifi.state.failed`
- `settings.wifi.state.idle`
- `settings.wifi.hint.on`
- `settings.wifi.hint.off`
- `settings.wifi.ip`
- `settings.wifi.ip_label`
- `settings.wifi.row.connected`
- `settings.wifi.row.connecting`
- `settings.wifi.row.saved`
- `settings.wifi.row.unsupported`
- `settings.wifi.row.secured`
- `settings.wifi.row.open`
- `settings.wifi.signal.sep`
- `settings.wifi.signal.strong`
- `settings.wifi.signal.good`
- `settings.wifi.signal.fair`
- `settings.wifi.signal.weak`
- `settings.wifi.saved_empty`
- `settings.wifi.unsupported_body`
- `settings.wifi.detail.connected`
- `settings.wifi.detail.saved`
- `settings.wifi.detail.unsaved`
- `settings.wifi.detail.known`
- `settings.wifi.detail.secured`
- `settings.wifi.detail.open`
- `settings.wifi.scan.start`
- `settings.wifi.scan.result`
- `settings.wifi.scan.timeout`
- `settings.wifi.scan.cancelled`
- `settings.wifi.scan.incomplete`
- `settings.wifi.scan.searching`
- `settings.wifi.scan.after_connect`
- `settings.wifi.scan.preparing`
- `settings.wifi.scan.off_hint`
- `settings.wifi.scan.empty`
- `settings.wifi.scan.never`
- `settings.wifi.toast.unsupported`
- `settings.wifi.toast.ssid`
- `settings.wifi.toast.busy`
- `settings.wifi.toast.enable_fail`
- `settings.wifi.toast.scan_fail`
- `settings.wifi.editor.password`
- `settings.wifi.editor.ssid`
- `settings.wifi.label.off`
- `settings.wifi.label.idle`
- `settings.wifi.toast.pending`
- `settings.wifi.toast.generic`
- `settings.wifi.toast.wifi_on`
- `settings.wifi.toast.connect`
- `settings.wifi.toast.profile_saved`
- `settings.wifi.toast.profile`
- `settings.wifi.toast.transfer`
- `settings.wifi.toast.unavailable`
- `settings.wifi.toast.need_lan`
- `settings.wifi.toast.storage`
- `settings.wifi.toast.card_gone`
- `dialog.wifi.forget.title`
- `dialog.wifi.forget.body`
- `dialog.transfer.stop.title`
- `dialog.transfer.uploading`
- `dialog.transfer.stop_body`
- `dialog.transfer.stopping`
- `dialog.transfer.stop_failed`
- `dialog.transfer.retry`
- `dialog.transfer.stop`
- `settings.transfer.title`
- `settings.transfer.hub`
- `settings.transfer.same_wifi`
- `settings.transfer.hotspot`
- `settings.transfer.usb`
- `settings.transfer.storage`
- `settings.transfer.books`
- `settings.transfer.open_shelf`
- `settings.transfer.done_shelf`
- `settings.transfer.join`
- `settings.transfer.open_page`
- `settings.transfer.reselect`
- `settings.transfer.card.missing`
- `settings.transfer.card.exported`
- `settings.transfer.card.verified`
- `settings.transfer.card.mounted`
- `settings.transfer.card.bad`
- `settings.transfer.card.manage`
- `settings.transfer.hint.lan_ready`
- `settings.transfer.hint.lan`
- `settings.transfer.hint.ap`
- `settings.transfer.hint.usb`
- `settings.transfer.state.preparing`
- `settings.transfer.state.not_started`
- `settings.transfer.state.receiving`
- `settings.transfer.state.waiting`
- `settings.transfer.state.incomplete`
- `settings.transfer.state.connecting`
- `settings.transfer.state.stopped`
- `settings.transfer.mode.ap`
- `settings.transfer.mode.sta`
- `settings.transfer.qr.preparing`
- `settings.transfer.qr.pending`
- `settings.transfer.qr.step`
- `settings.transfer.qr.browser`
- `settings.transfer.password`
- `settings.transfer.same_net`
- `settings.transfer.url.reselect`
- `settings.transfer.url.pending`
- `settings.transfer.capacity`
- `settings.transfer.capacity.flash`
- `settings.transfer.capacity.card`
- `settings.transfer.capacity.limit`
- `settings.transfer.progress.receiving`
- `settings.transfer.progress.files_retry`
- `settings.transfer.progress.retry`
- `settings.transfer.progress.bytes`
- `settings.transfer.progress.done`
- `settings.manage.title`
- `settings.manage.weread_title`
- `settings.manage.refresh`
- `settings.manage.stop`
- `settings.manage.start`
- `settings.manage.connect`
- `settings.manage.qr_on`
- `settings.manage.qr_off`
- `settings.manage.weread_head`
- `settings.manage.active_head`
- `settings.manage.idle_head`
- `settings.manage.weread_body`
- `settings.manage.active_body`
- `settings.manage.idle_body`
- `settings.manage.ttl`
- `settings.manage.weread_fail`
- `settings.home_link.title`
- `settings.home_link.empty`
- `settings.home_link.open`
- `settings.home_link.settings_empty`
- `settings.home_link.printers_title`
- `settings.home_link.printers_settings`
- `settings.home_link.printers_empty`
- `settings.home_link.missing`
- `settings.home_link.syncing`
- `settings.home_link.local`
- `settings.home_link.external`
- `settings.home_link.host_old`
- `settings.home_link.status`
- `settings.home_link.wifi_on`
- `settings.home_link.wifi_off`
- `settings.home_link.access`
- `settings.home_link.unconfigured`
- `settings.home_link.settings`
- `settings.home_link.sync`
- `settings.home_link.setup_body`
- `settings.home_link.field_line`
- `settings.home_link.saved`
- `settings.home_link.flags`
- `settings.home_link.flag.on`
- `settings.home_link.flag.off`
- `settings.home_link.access_ready`
- `settings.home_link.access_none`
- `settings.home_link.toggles`
- `settings.home_link.save_failed`
- `settings.home_link.no_input`
- `settings.home_link.input_fail`
- `settings.home_link.printers_sub`
- `settings.home_link.printers_body`
- `settings.home_link.host_down`
- `settings.home_link.slot`
- `settings.home_link.empty_slot`
- `settings.home_link.no_state`
- `settings.home_link.progress`
- `settings.home_link.no_data`
- `settings.home_link.back_monitor`
- `settings.home_link.submitted`
- `settings.home_link.control_failed`
- `settings.home_link.input_title`

## Out of scope (unchanged)

- QR / LAN config contract
- CF accent / Cloudflare Analytics card language
- Sidebar IA
- Resources firmware rebind
