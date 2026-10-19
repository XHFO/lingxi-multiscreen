import Foundation
import Vision
import ImageIO
let folder=URL(fileURLWithPath:CommandLine.arguments[1])
for name in ["menu-qr-dark", "menu-qr-light"] {
    let url=folder.appendingPathComponent(name + ".png")
    let request=VNDetectBarcodesRequest();request.symbologies=[.qr];request.usesCPUOnly=true
    try VNImageRequestHandler(url:url).perform([request])
    precondition(request.results?.first?.payloadStringValue == "http://192.168.1.123/standalone", "QR decode failed: " + name)
    print(name + ": native 240×240 framebuffer QR decoded to exact LAN URL; no credentials")
}
