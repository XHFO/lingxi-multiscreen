import Foundation
import CryptoKit

var assertions=0
func expect(_ value: Bool,_ label: String){assertions += 1;precondition(value,label)}
let root=FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-c6-internal-store-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at: root) }
let directory=root.appendingPathComponent("private")
let a=UUID(),b=UUID()
expect(C6SecretStore.read(deviceID:a,directory:directory).isEmpty,"empty install")
expect(!FileManager.default.fileExists(atPath:directory.path),"read does not create a key")
expect(C6SecretStore.save("fixture-a",deviceID:a,directory:directory),"store a")
expect(C6SecretStore.save("fixture-b",deviceID:b,directory:directory),"store b")
expect(C6SecretStore.read(deviceID:a,directory:directory)=="fixture-a","restart-independent a")
expect(C6SecretStore.read(deviceID:b,directory:directory)=="fixture-b","device isolation")
let urlA=directory.appendingPathComponent(a.uuidString + ".sealed")
let urlB=directory.appendingPathComponent(b.uuidString + ".sealed")
let data=try Data(contentsOf:urlA)
expect(data.range(of:Data("fixture-a".utf8))==nil,"no plaintext authorization")
expect((try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber)?.intValue==0o700,"private directory")
for url in [urlA,urlB,directory.appendingPathComponent("installation.key")] {
  expect((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue==0o600,"private files")
}
try data.write(to:urlB)
expect(C6SecretStore.read(deviceID:b,directory:directory).isEmpty,"copied authorization fails UUID-bound authentication")
var tampered=data;tampered[tampered.count-1] ^= 1;try tampered.write(to:urlA)
expect(C6SecretStore.read(deviceID:a,directory:directory).isEmpty,"tamper rejected")
expect(C6SecretStore.save("fixture-a2",deviceID:a,directory:directory),"recover by LAN session")
expect(C6SecretStore.save("",deviceID:a,directory:directory),"delete credential")
expect(C6SecretStore.read(deviceID:a,directory:directory).isEmpty,"no legacy Keychain resurrection")
let key=directory.appendingPathComponent("installation.key")
try Data([0]).write(to:key)
expect(!C6SecretStore.save("fixture-new",deviceID:a,directory:directory),"corrupt key never replaced silently")
let link=root.appendingPathComponent("link")
try FileManager.default.createSymbolicLink(at:link,withDestinationURL:directory)
expect(!C6SecretStore.save("fixture-link",deviceID:a,directory:link),"symlink store rejected")
print("C6 internal credential store: \(assertions) assertions; no Keychain API or system prompts; tests only use isolated temporary fixtures")
