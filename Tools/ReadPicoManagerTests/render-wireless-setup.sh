#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/readpico-wireless-setup-ui}"
mkdir -p "$output"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
root=Path.cwd(); output=Path(sys.argv[1]).resolve()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
core=[root/'Sources/LinxDisplayCore'/n for n in ('ReadPicoUSBTransfer.swift','ReadPicoUSBWireless.swift', 'ReadPicoBoardRouting.swift','ReadPicoPowerStatus.swift','ReadPicoManager.swift','ReadPicoLocalLibrary.swift','ReadPicoUSBBoard.swift','ReadPicoSafeEject.swift','ReadPicoBundledApps.swift')]
app=[root/'Sources/LinxDisplayApp'/n for n in ('ReadPicoCanvasDraft.swift','ReadPicoLockScreenDraft.swift','ReadPicoDraftGuard.swift','ReadPicoManagementWebView.swift','ReadPicoBundledAppsView.swift','ReadPicoLocalLibraryView.swift','ReadPicoUSBConnectionPanel.swift')]
manager=root/'Sources/LinxDisplayApp/ReadPicoManagerView.swift'
fixture=root/'Tools/ReadPicoManagerTests/WirelessSetupUIRender.swift'
origins=core+app+[manager,fixture,root/'Tools/ReadPicoManagerTests/render-wireless-setup.sh']
before={str(p.relative_to(root)):sha(p) for p in origins}
# The production Model's setter remains private. This isolated same-file extension only seeds
# display states, and never calls serial, filesystem, or external network operations.
(output/'ManagerWithUIFixture.swift').write_text(manager.read_text()+'''

extension ReadPicoManagerModel {
    func seedWirelessUIFixture(_ scene: String) {
        let networks: [ReadPicoUSBWirelessNetwork] = [
            .init(ssid: "家中 Wi-Fi", rssi: -43, requiresPassword: true, supported: true),
            .init(ssid: "访客网络", rssi: -64, requiresPassword: false, supported: true),
            .init(ssid: "企业网络", rssi: -71, requiresPassword: true, supported: false)]
        switch scene {
        case "wifi-connected":
            provisioningPhase = .connected; wirelessStatus = "已自动取得无线地址并完成配对。"
        case "select-network":
            provisioningPhase = .selectNetwork; wirelessNetworks = networks
            wirelessStatus = "Pico 尚未连接 Wi-Fi，请选择网络。"
        case "scanning":
            provisioningPhase = .scanning; wirelessStatus = "正在扫描 Pico 周围的 Wi-Fi 网络…"
        case "password-error":
            provisioningPhase = .failed; wirelessNetworks = networks; wirelessError = true
            wirelessStatus = "Pico 未能连接网络，请核对密码、信号和网络类型后重试。"
        case "usb-busy":
            busy = true; message = "正在等待 USB 传输完成，显示确认后继续。"
        default: break
        }
    }
}
''')
sdk=subprocess.check_output([str(root/'scripts/select-macos-sdk')],text=True).strip()
compiler=[str(root/'scripts/swiftc-sdk-compat'),'-sdk',sdk,'-swift-version','5']
subprocess.run(compiler+['-emit-library','-emit-module','-module-name','LinxDisplayCore']+[str(p) for p in core]+['-emit-module-path',str(output/'LinxDisplayCore.swiftmodule'),'-o',str(output/'libLinxDisplayCore.dylib')],check=True)
subprocess.run(compiler+['-parse-as-library','-I',str(output),'-L',str(output),'-lLinxDisplayCore','-Xlinker','-rpath','-Xlinker',str(output)]+[str(p) for p in app]+[str(output/'ManagerWithUIFixture.swift'),str(fixture),'-o',str(output/'render')],check=True)
subprocess.run([str(output/'render'),str(output/'screens')],check=True)
assert before=={str(p.relative_to(root)):sha(p) for p in origins},'Sources changed during native rendering'
report=json.loads((output/'screens/report.json').read_text())
assert report['result']=='PASS' and len(report['screens'])==24
(output/'source-binding.json').write_text(json.dumps(dict(result='PASS',source_sha256=before,screens={name:sha(output/'screens'/name) for name in report['screens']},scope='Unmodified production connection panel and Manager with isolated same-file state seed only.24 native scenes include offline, connected, network choice, scanning, password error and USB busy; compact/regular and light/dark. No physical device,user settings or external network.'),indent=2)+'\n')
PY
