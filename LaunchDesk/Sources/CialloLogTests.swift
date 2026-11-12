import Foundation

struct CialloLogTests {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchDesk-log-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SelfTests.require(try CialloLogReader.latest(in: root) == nil, "空日志目录处理错误")
        let day = root.appendingPathComponent("2026-11-12")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        func write(_ name: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]).write(to: day.appendingPathComponent(name))
        }
        func log(_ name: String, _ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
            try ("2026-11-12T11:00:00+08:00\npython command\n" + String(decoding: data, as: UTF8.self) + "\n").write(to: day.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("1100.started.json", ["startedAt": "2026-11-12T11:00:00.347673+08:00", "slot": 11])
        try write("1100.result.json", ["finishedAt": "2026-11-12T11:00:01.840081+08:00", "results": [
            ["client": "gpt-4", "exitCode": 0, "log": day.appendingPathComponent("1100-gpt-4.log").path],
            ["client": "gpt", "exitCode": 0, "log": day.appendingPathComponent("1100-gpt.log").path]]])
        try log("1100-gpt-4.log", ["status": "queued", "threadId": "thread-a", "queuedMessageId": "queue-a", "error": NSNull()])
        try log("1100-gpt.log", ["status": "completed", "threadId": "thread-b", "reply": "Ciallo {world}\nnew line"])
        var report = try CialloLogReader.latest(in: root).unwrap("未读取到执行结果")
        try SelfTests.require(report.clients[0].status == .queued, "入队消息被错误标记为已回复")
        try SelfTests.require(report.clients[1].status == .completed && report.clients[1].reply == "Ciallo {world}\nnew line", "复杂日志正文解析错误")
        try SelfTests.require(report.startedAt != nil && report.finishedAt != nil, "带微秒的时间解析错误")
        try write("1100.result.json", ["finishedAt": "2026-11-12T11:00:02+08:00", "results": [
            ["client": "gpt", "exitCode": 1, "log": day.appendingPathComponent("1100-gpt.log").path]]])
        report = try CialloLogReader.latest(in: root).unwrap("报告丢失")
        try SelfTests.require(report.clients[1].status == .failed, "失败退出码被日志成功状态掩盖")
        try write("1605.started.json", ["startedAt": "2026-11-12T16:05:00+08:00"])
        report = try CialloLogReader.latest(in: root).unwrap("新轮次丢失")
        try SelfTests.require(report.key == "1605" && !report.hasResult && report.clients.allSatisfy({ $0.status == .pending }), "新轮次执行中时错误展示旧结果")
        try Data("invalid result".utf8).write(to: day.appendingPathComponent("1605.result.json"))
        report = try CialloLogReader.latest(in: root).unwrap("异常轮次丢失")
        try SelfTests.require(report.key == "1605" && report.reportError != nil, "损坏的新报告未被提示")
        print("通过：最新轮次、入队与回复区分、失败退出码、部分日志、微秒时间及异常记录。")
    }
}
