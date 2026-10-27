import Foundation
import CryptoKit
public struct ESPSerialPort { public let path: String; public init(path: String){self.path=path} }
public enum ESP8266FirmwareFlasher { public static func discoverM5StickS3SerialPorts()->[ESPSerialPort]{[]} }
private var assertions=0
func check(_ result: Bool, _ label: String) { assertions += 1; if !result{fatalError(label)} }
func rejects(_ label: String, _ body: () throws -> Void){ assertions += 1; do{try body();fatalError("accepted: "+label)}catch{} }
func asyncRejects(_ label: String,_ body: () async throws -> Void) async { assertions += 1;do{try await body();fatalError("accepted: "+label)}catch{} }
final class Fake: @unchecked Sendable {
 let dir:URL;var calls:[[String]]=[];var modern:Bool;var securityBad=false;var ptBad=false;var otaBad=false;var identityBad=false;var verifyBad=false;var mac="aa:bb:cc:dd:ee:ff";var flashed:Data?;var writes=0;var runs=0;var macReads=0;var swapMAC=false;var postWriteMetadataBad=false
 init(_ dir:URL,_ modern:Bool=false){self.dir=dir;self.modern=modern}
 func run(_ helper:URL,_ args:[String],_ timeout:TimeInterval,_ log:@escaping ReadPicoFirmwareFlasher.Log) async throws->ReadPicoProcessResult {
  calls.append(args)
  if args == ["version"] {return .init(status:0,output:modern ? "esptool v5.1.0":"esptool.py v4.11.0\n4.11.0")}
  if args == ["--help"] {return .init(status:0,output:["read_mac","get_security_info","flash_id","read_flash","verify_flash","write_flash","run"].map{modern ? $0.replacingOccurrences(of:"_",with:"-"):$0}.joined(separator:" "))}
  check(args[0...3] == ["--chip","esp32s3","--port","/dev/cu.usbmodemFAKE"],"fixed chip+port")
  let cmd=args[12].replacingOccurrences(of:"-",with:"_")
  if cmd == "read_mac" {macReads+=1;return .init(status:0,output:"Chip is ESP32-S3\nMAC: \(swapMAC && macReads>1 ? "00:11:22:33:44:55":mac)")}
  if cmd == "get_security_info" {return .init(status:0,output:"Flags: 0x00000000 (0b0)\nSecure Boot: Disabled\nFlash Encryption: \(securityBad ? "Enabled":"Disabled")\n")}
  if cmd == "flash_id" {return .init(status:0,output:"Detected flash size: 16MB")}
  if cmd == "run" {runs+=1;return .init(status:0,output:"run")}
  if cmd == "write_flash" {
   check(args[13...18] == (modern ? ["--flash-mode","keep","--flash-freq","keep","--flash-size","keep"]:["--flash_mode","keep","--flash_freq","keep","--flash_size","keep"]),"helper dialect")
   check(args[19] == "0x20000" && args.count==21,"APP-only one region")
   flashed=try Data(contentsOf:URL(fileURLWithPath:args[20]));writes+=1;return .init(status:0,output:"Hash of data verified")
  }
  if cmd == "read_flash" {
   let address=args[13],count=Int(args[14])!,url=URL(fileURLWithPath:args[15]);var data:Data
   if address == "0x8000" {data=try Data(contentsOf:dir.appendingPathComponent("pt.bin"));if ptBad || (postWriteMetadataBad && writes>0){data[10]^=1}}
   else if address == "0xf000" {data=try Data(contentsOf:dir.appendingPathComponent(otaBad ? "ota2.bin":"ota1.bin"))}
   else if let flashed {data=flashed;if verifyBad{data[0]^=1}}
   else if count==0x400000 {data=try Data(contentsOf:dir.appendingPathComponent("slot.bin"))}
   else {data=try Data(contentsOf:dir.appendingPathComponent("app.bin"));data.append(Data(repeating:255,count:count-data.count));if identityBad{data[80]=0}}
   check(data.count==count,"fake read length \(address) expected \(count) got \(data.count)")
   try data.write(to:url);return .init(status:0,output:"read")
  }
  fatalError("Unexpected helper command: \(args)")
 }
}
actor Gate {
 var started=false
 var pending:CheckedContinuation<Void,Never>?
 func pause() async {started=true;await withCheckedContinuation{pending=$0}}
 func release(){pending?.resume();pending=nil}
}
final class PhaseTrace: @unchecked Sendable {
 private let lock=NSLock();private var values:[ReadPicoFirmwarePhase]=[]
 func add(_ value:ReadPicoFirmwarePhase){lock.lock();values.append(value);lock.unlock()}
 var snapshot:[ReadPicoFirmwarePhase]{lock.lock();defer{lock.unlock()};return values}
}
final class ProcessProbe: @unchecked Sendable {
 private let lock=NSLock();private var observed=false
 var flasher:ReadPicoFirmwareFlasher?
 func observe(_ text:String){if text.contains("PROCESS_STARTED"){lock.lock();observed=true;lock.unlock()}}
 var started:Bool{lock.lock();defer{lock.unlock()};return observed}
}
@main struct Main {
 static func main() async throws {
  let dir=URL(fileURLWithPath:CommandLine.arguments[1]),port=ESPSerialPort(path:"/dev/cu.usbmodemFAKE"),helper=URL(fileURLWithPath:"/fake/esptool")
  let appURL=dir.appendingPathComponent("app.bin"),manURL=dir.appendingPathComponent("manifest.json"),app=try Data(contentsOf:appURL),manifest=try JSONDecoder().decode(ReadPicoFirmwareManifest.self,from:Data(contentsOf:manURL))
  let info=try ReadPicoFirmwareValidator.validate(app,manifest:manifest);check(info.project=="Read_Pico" && info.version=="0.0-test1","APP descriptor")
  let table=try Data(contentsOf:dir.appendingPathComponent("pt.bin"));check(try ReadPicoFirmwareValidator.partitions(table).count==6,"PT MD5+layout")
  for seq in [1,3] {let d=try Data(contentsOf:dir.appendingPathComponent("ota\(seq).bin"));check(try ReadPicoFirmwareValidator.otaSequence(d)==UInt32(seq),"OTA active odd")}
  rejects("OTA other slot"){_ = try ReadPicoFirmwareValidator.otaSequence(Data(contentsOf:dir.appendingPathComponent("ota2.bin")))}
  for length in [0,1,23,24,31,40,100,app.count-1] {rejects("truncated \(length)"){_ = try ReadPicoFirmwareValidator.image(app.prefix(length))}}
  for (offset,value) in [(0,UInt8(0)),(1,0),(12,13),(2,0),(3,0),(23,0),(212,15),(app.count-33,0),(app.count-1,0)] {
   var bad=app;bad[offset]=value;rejects("image field/checksum/hash \(offset)"){_ = try ReadPicoFirmwareValidator.image(bad)}
  }
  var mmu=app;mmu[288]=1;rejects("MMU alignment"){_ = try ReadPicoFirmwareValidator.image(mmu)}
  var wrong=manifest;wrong.version="other";rejects("manifest version"){_ = try ReadPicoFirmwareValidator.validate(app,manifest:wrong)}
  wrong=manifest;wrong.sha256=String(repeating:"0",count:64);rejects("manifest digest"){_ = try ReadPicoFirmwareValidator.validate(app,manifest:wrong)}
  wrong=manifest;wrong.appAddress=0x10000;rejects("manifest address"){_ = try ReadPicoFirmwareValidator.validate(app,manifest:wrong)}
  var corrupt=table;corrupt[10]^=1;rejects("PT MD5"){_ = try ReadPicoFirmwareValidator.partitions(corrupt)}
  corrupt=table;corrupt[80]=0;corrupt.replaceSubrange(208..<224,with:Data(Insecure.MD5.hash(data:corrupt.prefix(192))))
  rejects("different PT with valid MD5"){_ = try ReadPicoFirmwareValidator.partitions(corrupt)}
  rejects("encrypted"){try ReadPicoFirmwareValidator.security("Flags: 0x0\nSecure Boot: Disabled\nFlash Encryption: Enabled")}
  rejects("secureboot"){try ReadPicoFirmwareValidator.security("Flags: 0x1\nSecure Boot: Enabled\nFlash Encryption: Disabled")}
  rejects("missing security flags"){try ReadPicoFirmwareValidator.security("Secure Boot: Disabled\nFlash Encryption: Disabled")}
  for modern in [false,true] {
   let fake=Fake(dir,modern),flasher=ReadPicoFirmwareFlasher(runner:{ h,a,t,l in try await fake.run(h,a,t,l) })
   let result=try await flasher.flash(port:port,helperURL:helper,imageURL:appURL,manifestURL:manURL)
   check(result.bytes==app.count && fake.writes==1 && fake.runs==1,"update and run")
   check(fake.calls.filter{$0.contains(modern ? "read-flash":"read_flash")}.count==6,"metadata only plus independent APP/PT/OTA verification; no auto backup")
   check(!fake.calls.joined().contains("erase-flash") && !fake.calls.joined().contains("erase_flash"),"no erase command")
  }
  for failure in ["pt","ota","identity","security","verify","swapMAC","postWritePT"] {
   let fake=Fake(dir);fake.ptBad=failure=="pt";fake.otaBad=failure=="ota";fake.identityBad=failure=="identity";fake.securityBad=failure=="security";fake.verifyBad=failure=="verify";fake.swapMAC=failure=="swapMAC";fake.postWriteMetadataBad=failure=="postWritePT"
   let f=ReadPicoFirmwareFlasher(runner:{ h,a,t,l in try await fake.run(h,a,t,l) })
   await asyncRejects("fake \(failure)"){_ = try await f.flash(port:port,helperURL:helper,imageURL:appURL,manifestURL:manURL)}
   check(fake.runs==0 && fake.writes==(["verify","postWritePT"].contains(failure) ? 1:0),"failure stops write/run \(failure)")
  }
  let backupFake=Fake(dir),backuper=ReadPicoFirmwareFlasher(runner:{ h,a,t,l in try await backupFake.run(h,a,t,l) })
  let backupResult=try await backuper.backup(port:port,helperURL:helper,directory:dir)
  let location=backupResult.directory
  check(backupResult.restartError==nil,"backup requested restart")
  check(backupFake.writes==0 && backupFake.runs==1,"backup read only")
  let backup=try Data(contentsOf:location.appendingPathComponent("ota_0.bin"));check(backup.count==0x400000,"complete 4MiB backup")
  let backupManifest=try JSONDecoder().decode(ReadPicoFirmwareManifest.self,from:Data(contentsOf:location.appendingPathComponent("manifest.json")))
  check(backupManifest.deviceMAC=="aa:bb:cc:dd:ee:ff" && backupManifest.appBytes==app.count,"backup device+trim metadata")
  let restoreFake=Fake(dir),restorer=ReadPicoFirmwareFlasher(runner:{ h,a,t,l in try await restoreFake.run(h,a,t,l) })
  _ = try await restorer.restore(port:port,helperURL:helper,imageURL:location.appendingPathComponent("ota_0.bin"),manifestURL:location.appendingPathComponent("manifest.json"))
  check(restoreFake.flashed==app && restoreFake.writes==1 && restoreFake.runs==1,"restore APP only")
  let other=Fake(dir);other.mac="00:11:22:33:44:55";let otherRestorer=ReadPicoFirmwareFlasher(runner:{ h,a,t,l in try await other.run(h,a,t,l) })
  await asyncRejects("wrong device restore"){_ = try await otherRestorer.restore(port:port,helperURL:helper,imageURL:location.appendingPathComponent("ota_0.bin"),manifestURL:location.appendingPathComponent("manifest.json"))}
  check(other.writes==0,"wrong MAC stopped")

  let slotInfo=try ReadPicoFirmwareValidator.image(backup,allowSlotTail:true)
  check(slotInfo.imageBytes==app.count,"backup parses legitimate image before stale slot tail")
  rejects("normal APP rejects stale slot tail"){_ = try ReadPicoFirmwareValidator.image(backup)}
  let huge=dir.appendingPathComponent("oversized.bin");try Data(repeating:0,count:0x400001).write(to:huge)
  rejects("bounded image file read"){_ = try ReadPicoFirmwareValidator.readFile(huge,maximumBytes:0x400000)}
  var pending=try Data(contentsOf:dir.appendingPathComponent("ota1.bin"));pending.replaceSubrange(24..<28,with:[1,0,0,0])
  rejects("pending verification cannot be reset safely"){_ = try ReadPicoFirmwareValidator.otaSequence(pending)}
  var invalidCRC=try Data(contentsOf:dir.appendingPathComponent("ota1.bin"));invalidCRC[28]^=1
  rejects("OTA invalid CRC"){_ = try ReadPicoFirmwareValidator.otaSequence(invalidCRC)}
  for cancellation in ["direct","task","all"] {
   let gate=Gate(),fake=Fake(dir),flasher=ReadPicoFirmwareFlasher(runner:{h,a,t,l in
    if a.contains("read_mac"){await gate.pause()}
    return try await fake.run(h,a,t,l)
   })
   let operation=Task{try await flasher.flash(port:port,helperURL:helper,imageURL:appURL,manifestURL:manURL)}
   for _ in 0..<2000 {if await gate.started {break};try await Task.sleep(nanoseconds:1_000_000)}
   check(await gate.started,"fake long operation entered")
   if cancellation == "direct" {
    let usb=ReadPicoUSBTransferClient(runner:{_,_ in fatalError("USB transport opened while firmware owns port")})
    await asyncRejects("USB cannot open firmware-owned serial"){_ = try await usb.start(port:port.path)}
   }
   let competitor=ReadPicoFirmwareFlasher(runner:{h,a,t,l in try await fake.run(h,a,t,l)})
   await asyncRejects("same serial cannot be opened twice"){_ = try await competitor.inspect(port:port,helperURL:helper)}
   if cancellation == "task" {operation.cancel()}else if cancellation == "all" {ReadPicoFirmwareFlasher.cancelAllOperations()}else{flasher.cancel()}
   await gate.release()
   await asyncRejects("long operation cancellation"){_ = try await operation.value}
   check(fake.writes==0 && fake.runs==0,"cancel prevents later writes and run")
   let recovered=try await competitor.inspect(port:port,helperURL:helper)
   check(recovered.macAddress==fake.mac,"cancel releases serial guard")
  }
  do {
   let lease=try ReadPicoUSBSerialLease.acquire(path:port.path),fake=Fake(dir)
   let blocked=ReadPicoFirmwareFlasher(runner:{h,a,t,l in try await fake.run(h,a,t,l)})
   await asyncRejects("firmware cannot open USB-owned serial"){_ = try await blocked.inspect(port:port,helperURL:helper)}
   check(fake.calls.isEmpty,"USB lease conflict prevents helper invocation")
   lease.release()
   let recovered=try await blocked.inspect(port:port,helperURL:helper)
   check(recovered.macAddress==fake.mac,"USB lease release permits firmware inspection")
  }
  // 中文：每个不可取消阶段都走真实刷写编排，取消不能略过回读、元数据核对和启动。
  // English: Drive the real orchestration at each protected phase; never skip verification or run.
  for stage in ["write","verify-app","verify-pt","verify-ota","restart"] {
   for cancellation in ["direct","task","all"] {
    let gate=Gate(),fake=Fake(dir),trace=PhaseTrace()
    let f=ReadPicoFirmwareFlasher(runner:{h,a,t,l in
     let cmd=a.count>12 ? a[12]:""
     let target=stage=="write" && cmd=="write_flash" || stage=="restart" && cmd=="run" ||
      stage=="verify-app" && cmd=="read_flash" && a[15].hasSuffix("verify-app.bin") ||
      stage=="verify-pt" && cmd=="read_flash" && a[15].hasSuffix("verify-partitions.bin") ||
      stage=="verify-ota" && cmd=="read_flash" && a[15].hasSuffix("verify-ota.bin")
     if target{await gate.pause()}
     return try await fake.run(h,a,t,l)
    })
    let work=Task{try await f.flash(port:port,helperURL:helper,imageURL:appURL,manifestURL:manURL,phase:{trace.add($0)})}
    for _ in 0..<2000 {if await gate.started{break};try await Task.sleep(nanoseconds:1_000_000)}
    check(await gate.started,"protected phase reached \(stage)")
    check(!f.canCancel && ReadPicoFirmwareFlasher.hasNonCancellableOperations,"atomic protected flag \(stage)")
    check(!ReadPicoFirmwareFlasher.prepareForApplicationTermination(),"protected quit refuses without changing operation")
    check(!f.phase.allowsCancellation,"phase disables stop \(stage)")
    if cancellation=="task" {work.cancel()}else if cancellation=="all"{ReadPicoFirmwareFlasher.cancelAllOperations()}else{check(!f.cancel(),"protected cancel explicitly rejected")}
    let competitor=ReadPicoFirmwareFlasher(runner:{h,a,t,l in try await fake.run(h,a,t,l)})
    await asyncRejects("protected port stays occupied"){_ = try await competitor.inspect(port:port,helperURL:helper)}
    await gate.release();let result=try await work.value
    check(result.bytes==app.count && result.restartError==nil && fake.writes==1 && fake.runs==1,"protected cancellation finishes verified install \(stage)/\(cancellation)")
    check(trace.snapshot.contains(.writing) && trace.snapshot.contains(.verifying) && trace.snapshot.contains(.restarting) && trace.snapshot.last == .idle,"complete phase trace")
    check(!ReadPicoFirmwareFlasher.hasNonCancellableOperations && f.phase == .idle,"protected gate cleared only at end")
   }
  }
  // 中文：最终身份核验仍可停止，不能跨过写前边界启动任何写入。
  // English: Cancellation at the final identity check must still prevent every write.
  let boundaryGate=Gate(),boundaryFake=Fake(dir)
  let boundary=ReadPicoFirmwareFlasher(runner:{h,a,t,l in
   if a.contains("read_mac") && boundaryFake.macReads==1{await boundaryGate.pause()}
   return try await boundaryFake.run(h,a,t,l)
  })
  let boundaryWork=Task{try await boundary.flash(port:port,helperURL:helper,imageURL:appURL,manifestURL:manURL)}
  for _ in 0..<2000 {if await boundaryGate.started{break};try await Task.sleep(nanoseconds:1_000_000)}
  check(await boundaryGate.started && boundary.canCancel && !ReadPicoFirmwareFlasher.hasNonCancellableOperations,"prewrite identity cancellable")
  check(boundary.cancel(),"prewrite stop accepted");await boundaryGate.release()
  await asyncRejects("prewrite stop result"){_ = try await boundaryWork.value}
  check(boundaryFake.writes==0,"prewrite stop never writes")
  // 中文：已验证的备份与固件不能因启动失败被当成完全失败或丢失路径。
  // English: A restart failure must retain verified backups and verified install results.
  let partialFake=Fake(dir),partial=ReadPicoFirmwareFlasher(runner:{h,a,t,l in
   if a.contains("run"){return .init(status:1,output:"injected restart failure")}
   return try await partialFake.run(h,a,t,l)
  })
  let partialResult=try await partial.backup(port:port,helperURL:helper,directory:dir)
  check(partialResult.restartError?.contains("injected restart failure")==true,"backup partial success carries restart error")
  let partialManifest=try JSONDecoder().decode(ReadPicoFirmwareManifest.self,from:Data(contentsOf:partialResult.directory.appendingPathComponent("manifest.json")))
  _ = try ReadPicoFirmwareValidator.validate(Data(contentsOf:partialResult.directory.appendingPathComponent("ota_0.bin")),manifest:partialManifest,backup:true)
  check(partialFake.writes==0 && FileManager.default.fileExists(atPath:partialResult.directory.path),"validated backup path survives restart failure")
  let updatePartial=try await partial.flash(port:port,helperURL:helper,imageURL:appURL,manifestURL:manURL)
  check(updatePartial.bytes==app.count && updatePartial.restartError?.contains("injected restart failure")==true,"verified install partial success explicit")
  check(!ReadPicoFirmwareFlasher.hasNonCancellableOperations,"partial success releases port and quit gate")
  // 中文：在实际 Process 路径注入无设备助手，验证停止确实结束安全子进程、不会杀写入子进程。
  // English: Inject a real device-free child through Process to test actual termination policy.
  for protected in [false,true] {
   let probe=ProcessProbe(),fake=Fake(dir)
   let f=ReadPicoFirmwareFlasher(runner:{h,a,t,l in
    if a.contains(protected ? "write_flash":"read_mac") && !probe.started {
     let duration=protected ? "0.35":"5"
     let result=try await probe.flasher!.runProcess(URL(fileURLWithPath:"/bin/sh"),["-c","printf 'PROCESS_STARTED\\n'; exec /bin/sleep "+duration],10,{probe.observe($0);l($0)})
     if result.status != 0{return result}
    }
    return try await fake.run(h,a,t,l)
   });probe.flasher=f
   let work=Task{try await f.flash(port:port,helperURL:helper,imageURL:appURL,manifestURL:manURL)}
   for _ in 0..<2000 {if probe.started{break};try await Task.sleep(nanoseconds:1_000_000)}
   check(probe.started,"actual child launched")
   let stoppedAt=Date();check(f.cancel() == !protected,"real child stop respects phase")
   if protected {
    work.cancel();ReadPicoFirmwareFlasher.cancelAllOperations()
    let result=try await work.value
    check(result.restartError==nil && fake.writes==1 && fake.runs==1,"real write child survives stop and task cancellation")
   }else{
    await asyncRejects("real cancellable child terminated"){_ = try await work.value}
    check(Date().timeIntervalSince(stoppedAt)<2 && fake.writes==0,"safe stop waits for child exit without later writes")
   }
   check(!ReadPicoFirmwareFlasher.hasNonCancellableOperations,"real child releases operation gate")
   probe.flasher=nil
  }
  try await runFreshInstallTests(directory:dir,port:port,helper:helper)
  // 中文：退出接受后关闭检查到使用的竞争窗口，现有准备任务与全新实例都不能进入写入。
  // English: Accepted quit closes the check/use race for current preparation and newly created flashers.
  let quitProbe=ProcessProbe(),quitFake=Fake(dir)
  let quitting=ReadPicoFirmwareFlasher(runner:{h,a,t,l in
   if a.contains("read_mac") && !quitProbe.started {
    let result=try await quitProbe.flasher!.runProcess(URL(fileURLWithPath:"/bin/sh"),["-c","printf 'PROCESS_STARTED\\n'; exec /bin/sleep 5"],10,{quitProbe.observe($0);l($0)})
    if result.status != 0{return result}
   }
   return try await quitFake.run(h,a,t,l)
  });quitProbe.flasher=quitting
  let quitWork=Task{try await quitting.flash(port:port,helperURL:helper,imageURL:appURL,manifestURL:manURL)}
  for _ in 0..<2000 {if quitProbe.started{break};try await Task.sleep(nanoseconds:1_000_000)}
  check(quitProbe.started && quitting.canCancel,"quit starts with real cancellable child")
  let quitAt=Date()
  check(ReadPicoFirmwareFlasher.prepareForApplicationTermination(),"preparation quit accepted atomically")
  await asyncRejects("quit cancels current real helper"){_ = try await quitWork.value}
  check(Date().timeIntervalSince(quitAt)<2 && quitFake.writes==0 && !quitting.canCancel,"accepted quit waits real helper exit without writes")
  let futureFake=Fake(dir),future=ReadPicoFirmwareFlasher(runner:{h,a,t,l in try await futureFake.run(h,a,t,l)})
  await asyncRejects("quit blocks new instance registration"){_ = try await future.inspect(port:port,helperURL:helper)}
  await asyncRejects("quit blocks reused instance registration"){_ = try await quitting.inspect(port:port,helperURL:helper)}
  check(futureFake.calls.isEmpty && !ReadPicoFirmwareFlasher.hasNonCancellableOperations,"quit starts no future serial commands")
  quitProbe.flasher=nil
  print("PASS \(assertions) offline parser and fake-device assertions; no hardware accessed")
 }
}
