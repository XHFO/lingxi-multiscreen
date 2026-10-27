import Foundation
import LinxDisplayCore

/// Every delivery here is an injected closure. This test must never invoke the
/// system transport or change the user's media playback.
func testNowPlayingControl() async throws {
    actor Deliveries {
        var commands: [NowPlayingControlCommand] = []
        var timeouts: [TimeInterval] = []
        func append(_ command: NowPlayingControlCommand, timeout: TimeInterval) {
            commands.append(command); timeouts.append(timeout)
        }
    }
    let deliveries = Deliveries()
    let client = NowPlayingControlClient(transport: .init { command, timeout in
        await deliveries.append(command, timeout: timeout)
        return .accepted
    })
    let playing = NowPlayingInfo(title: "Test track", playbackRate: 1)
    let paused = NowPlayingInfo(title: "Paused track", playbackRate: 0)
    checkEqual(NowPlayingControlCommand.play.rawValue, 0, "播放命令使用MediaRemote值0")
    checkEqual(NowPlayingControlCommand.pause.rawValue, 1, "暂停命令使用MediaRemote值1")
    checkEqual(NowPlayingControlCommand.nextTrack.rawValue, 4, "下一曲使用MediaRemote值4")
    checkEqual(NowPlayingControlCommand.previousTrack.rawValue, 5, "上一曲使用MediaRemote值5")
    checkEqual(NowPlayingControlCommand.allCases.count, 4, "仅开放四种明确命令，没有toggle命令")
    check(NowPlayingControlClient.canControl(playing), "播放曲目允许控制")
    check(NowPlayingControlClient.canControl(paused), "暂停曲目仍允许恢复播放")
    check(!NowPlayingControlClient.canControl(.placeholder), "未播放占位不发送控制")
    check(!NowPlayingControlClient.canControl(NowPlayingInfo(title: " \n")), "空标题不发送控制")
    check(NowPlayingControlClient.canControl(NowPlayingInfo(title: "未在播放", duration: 180, playbackRate: 0)),
          "真实同名暂停曲目不与空占位混淆")

    for invalid in [NowPlayingInfo.placeholder, NowPlayingInfo(title: "") ] {
        do {
            _ = try await client.send(.play, current: invalid)
            check(false, "无媒体应拒绝控制")
        } catch NowPlayingControlError.noMedia {
            check(true, "无媒体返回明确错误")
        }
    }
    checkEqual(await deliveries.commands.count, 0, "无媒体验证在transport之前完成")
    for timeout in [TimeInterval(0), -1, .infinity, -.infinity, .nan] {
        do {
            _ = try await client.send(.pause, current: playing, timeout: timeout)
            check(false, "非法超时应拒绝控制")
        } catch NowPlayingControlError.invalidTimeout {
            check(true, "非法超时返回明确错误")
        }
    }
    checkEqual(await deliveries.commands.count, 0, "非法超时不会触发发送")

    for command in NowPlayingControlCommand.allCases {
        let receipt = try await client.send(command, current: paused, timeout: 3)
        checkEqual(receipt, .accepted, "\(command)只返回接受投递，不声称已执行")
    }
    checkEqual(await deliveries.commands, NowPlayingControlCommand.allCases, "四种命令各只投递一次且不转换成toggle")
    checkEqual(await deliveries.timeouts, Array(repeating: 3, count: 4), "等待时间原样传给transport")
    checkEqual(paused.playbackRate, 0, "accepted不乐观修改媒体状态")
    _ = try await client.send(.play, current: paused, timeout: 100_000)
    checkEqual(await deliveries.timeouts.last, 60, "超长超时限制为60秒避免时间转换溢出")

    for expected in [NowPlayingControlError.unsupported, .rejected, .timeoutOutcomeUnknown,
                     .invalidResponse, .transportUnavailable] {
        let rejectedDeliveries = Deliveries()
        let rejectedClient = NowPlayingControlClient(transport: .init { command, timeout in
            await rejectedDeliveries.append(command, timeout: timeout)
            throw expected
        })
        do {
            _ = try await rejectedClient.send(.nextTrack, current: playing)
            check(false, "\(expected)不应报告accepted")
        } catch let error as NowPlayingControlError {
            checkEqual(error, expected, "保留\(expected)错误边界")
        }
        checkEqual(await rejectedDeliveries.commands, [.nextTrack], "\(expected)后不会再次发命令或改路重试")
        check(!(expected.localizedDescription.isEmpty), "\(expected)有明确用户提示")
    }

    let cancelledDeliveries = Deliveries()
    let cancelledClient = NowPlayingControlClient(transport: .init { command, timeout in
        await cancelledDeliveries.append(command, timeout: timeout)
        return .accepted
    })
    let alreadyCancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await cancelledClient.send(.play, current: paused)
    }
    do {
        _ = try await alreadyCancelled.value
        check(false, "已取消操作不应发送")
    } catch is CancellationError {
        check(true, "已取消操作返回取消结果")
    }
    checkEqual(await cancelledDeliveries.commands.count, 0, "发送前取消完全不触及transport")

    let cancellationInTransport = NowPlayingControlClient(transport: .init { command, timeout in
        await cancelledDeliveries.append(command, timeout: timeout)
        withUnsafeCurrentTask { $0?.cancel() }
        return .accepted
    })
    let cancelledInFlight = Task {
        try await cancellationInTransport.send(.previousTrack, current: playing)
    }
    do {
        _ = try await cancelledInFlight.value
        check(false, "投递期间取消不应乐观报告成功")
    } catch is CancellationError {
        check(true, "投递后取消保持取消结果，不自动重发")
    }
    checkEqual(await cancelledDeliveries.commands, [.previousTrack], "投递后取消只发一次上一曲")

    func output(_ text: String) -> Data { Data(text.utf8) }
    checkEqual(try NowPlayingControlClient.parseTransportOutput(output(#"{"command":0,"status":"accepted"}"#),
        expectedCommand: .play), .accepted, "严格接受匹配命令的accepted回执")
    for (status, expected) in [("rejected", NowPlayingControlError.rejected), ("unsupported", .unsupported)] {
        do {
            _ = try NowPlayingControlClient.parseTransportOutput(output("{\"command\":1,\"status\":\"\(status)\"}"),
                expectedCommand: .pause)
            check(false, "\(status)回执不应accepted")
        } catch let error as NowPlayingControlError {
            checkEqual(error, expected, "解析\(status)回执")
        }
    }
    for malformed in ["", "garbage", "[]", "{}", #"{"status":"accepted"}"#,
                      #"{"command":4,"status":"accepted"}"#, #"{"command":false,"status":"accepted"}"#,
                      #"{"command":0,"status":true}"#, #"{"command":"0","status":"accepted"}"#,
                      #"{"command":0,"status":"success"}"#, #"{"command":0.1,"status":"accepted"}"#] {
        do {
            _ = try NowPlayingControlClient.parseTransportOutput(output(malformed), expectedCommand: .play)
            check(false, "损坏或错命令回执不应accepted")
        } catch NowPlayingControlError.invalidResponse {
            check(true, "损坏或错命令回执保持结果不明，不再发送")
        }
    }
}
