import Foundation

// The runner's per-round report and the two command logs are read independently.
// An exit code of zero with status=queued confirms submission, not a model reply.
enum CialloClientStatus: String {
    case completed = "已回复", queued = "已入队", failed = "执行失败"
    case ended = "命令已结束", pending = "暂无结果"
}

struct CialloClientResult: Identifiable {
    let id: String
    let exitCode: Int?
    let status: CialloClientStatus
    let reply: String?
    let threadID: String?
    let queueID: String?
    let error: String?
    let logURL: URL
    let logExists: Bool
    let logText: String
}

struct CialloRun {
    let key: String
    let directory: URL
    let startedAt: Date?
    let finishedAt: Date?
    let hasResult: Bool
    let reportError: String?
    let clients: [CialloClientResult]

    var title: String {
        let day = directory.lastPathComponent
        guard key.count == 4, key.allSatisfy(\.isNumber) else { return day + " · " + key }
        return day + " " + key.prefix(2) + ":" + key.suffix(2)
    }
    var summary: String {
        if reportError != nil { return "结果记录异常" }
        if clients.contains(where: { $0.status == .failed }) { return "本轮有执行失败" }
        if !hasResult { return "尚无本轮结束记录" }
        if clients.contains(where: { $0.status == .pending }) { return "本轮记录不完整" }
        if clients.allSatisfy({ $0.status == .completed }) { return "两个客户端均已回复" }
        if clients.contains(where: { $0.status == .queued }) { return "消息已提交，包含入队消息" }
        return "本轮命令已结束"
    }
}

struct CialloLogReader {
    static func root(for job: LaunchJob) -> URL {
        if let script = job.arguments.first(where: { URL(fileURLWithPath: $0).lastPathComponent == "codex-morning-ciallo.py" }) {
            return URL(fileURLWithPath: script).deletingLastPathComponent().appendingPathComponent("logs/codex-morning", isDirectory: true)
        }
        let base = job.config["WorkingDirectory"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("data/scripts").path
        return URL(fileURLWithPath: base).appendingPathComponent("logs/codex-morning", isDirectory: true)
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: string) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: string)
    }

    static func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw UserError("结果记录应为 JSON 对象。")
        }
        return value
    }

    static func trailingObject(_ text: String) -> [String: Any]? {
        let lines = text.components(separatedBy: "\n")
        for index in lines.indices.reversed() where lines[index].hasPrefix("{") {
            if let value = try? JSONSerialization.jsonObject(with: Data(lines[index...].joined(separator: "\n").utf8)) as? [String: Any] {
                return value
            }
        }
        return nil
    }

    static func latest(in root: URL) throws -> CialloRun? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return nil }
        let days = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for directory in days {
            let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            let keys = Set(files.compactMap { file -> String? in
                for suffix in [".started.json", ".result.json"] where file.lastPathComponent.hasSuffix(suffix) {
                    return String(file.lastPathComponent.dropLast(suffix.count))
                }
                return nil
            })
            guard !keys.isEmpty else { continue }
            let newest = keys.max { a, b in
                let left = occurrenceDate(a, in: directory)
                let right = occurrenceDate(b, in: directory)
                return left == right ? a < b : left < right
            }!
            return read(key: newest, directory: directory)
        }
        return nil
    }

    private static func occurrenceDate(_ key: String, in directory: URL) -> Date {
        let start = directory.appendingPathComponent(key + ".started.json")
        if let object = try? object(start), let value = date(object["startedAt"]) { return value }
        if key.count == 4, let hour = Int(key.prefix(2)), let minute = Int(key.suffix(2)), (0...23).contains(hour), (0...59).contains(minute) {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(identifier: "Asia/Shanghai")
            parser.dateFormat = "yyyy-MM-dd HHmm"
            if let value = parser.date(from: directory.lastPathComponent + " " + key) { return value }
        }
        let result = directory.appendingPathComponent(key + ".result.json")
        if let object = try? object(result), let value = date(object["finishedAt"]) { return value }
        return (try? result.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func read(key: String, directory: URL) -> CialloRun {
        let manager = FileManager.default
        let start = try? object(directory.appendingPathComponent(key + ".started.json"))
        let resultURL = directory.appendingPathComponent(key + ".result.json")
        let hasResult = manager.fileExists(atPath: resultURL.path)
        var report: [String: Any] = [:]
        var reportError: String?
        if hasResult {
            do {
                report = try object(resultURL)
                guard report["results"] is [[String: Any]] else { throw UserError("结果记录缺少客户端结果列表。") }
            } catch { reportError = error.localizedDescription }
        }
        let results = report["results"] as? [[String: Any]] ?? []
        let clients = ["gpt-4", "gpt"].map { client -> CialloClientResult in
            let result = results.first { $0["client"] as? String == client }
            let path = result?["log"] as? String
            let logURL = path.map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent(key + "-" + client + ".log")
            let exists = manager.fileExists(atPath: logURL.path)
            let text = exists ? LaunchService.logTail(logURL.path) : "日志文件尚未生成或已被移走。"
            let output = exists ? trailingObject(text) : nil
            let exitCode = result?["exitCode"] as? Int
            let status: CialloClientStatus
            let outputError = nonNull(output?["error"])
            let resultError = nonNull(result?["error"])
            if exitCode.map({ $0 != 0 }) == true || ["failed", "interrupted"].contains(output?["status"] as? String ?? "") || outputError != nil || resultError != nil {
                status = .failed
            } else if output?["status"] as? String == "queued" {
                status = .queued
            } else if output?["status"] as? String == "completed" {
                status = .completed
            } else if exitCode == 0 { status = .ended }
            else { status = .pending }
            let error = resultError ?? outputError
            let errorText = error.map { value -> String in
                if let text = value as? String { return text }
                if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .fragmentsAllowed]) { return String(decoding: data, as: UTF8.self) }
                return String(describing: value)
            }
            return CialloClientResult(id: client, exitCode: exitCode, status: status,
                reply: output?["reply"] as? String, threadID: output?["threadId"] as? String,
                queueID: output?["queuedMessageId"] as? String, error: errorText,
                logURL: logURL, logExists: exists, logText: text)
        }
        return CialloRun(key: key, directory: directory, startedAt: date(start?["startedAt"]),
                         finishedAt: date(report["finishedAt"]), hasResult: hasResult,
                         reportError: reportError, clients: clients)
    }

    private static func nonNull(_ value: Any?) -> Any? {
        value is NSNull ? nil : value
    }
}
