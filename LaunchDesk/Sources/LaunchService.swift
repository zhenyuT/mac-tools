import Foundation
import AppKit

struct UserError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum JobScope: String, CaseIterable, Identifiable {
    case user = "我的任务", shared = "共享任务", system = "系统任务"
    var id: String { rawValue }
    var folders: [URL] {
        switch self {
        case .user: return [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")]
        case .shared: return [URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")]
        case .system: return [URL(fileURLWithPath: "/System/Library/LaunchAgents"), URL(fileURLWithPath: "/System/Library/LaunchDaemons")]
        }
    }
}

struct LaunchJob: Identifiable {
    let url: URL
    let data: Data
    let config: [String: Any]
    let scope: JobScope
    var enabled: Bool
    var loaded: Bool?
    var pid: Int?
    var exitCode: Int?
    var id: String { url.path }
    var label: String { config["Label"] as? String ?? url.deletingPathExtension().lastPathComponent }
    var hasCialloPanel: Bool { label == "local.codex.ciallo-daily" }
    var editable: Bool { scope == .user && !isSymlink && FileManager.default.isWritableFile(atPath: url.path) }
    var isSymlink: Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    var domain: String { url.path.contains("LaunchDaemons/") ? "system" : "gui/\(getuid())" }
    var target: String { "\(domain)/\(label)" }
    var arguments: [String] { config["ProgramArguments"] as? [String] ?? [config["Program"] as? String ?? ""] }
    var command: String { arguments.joined(separator: " ") }
    var calendarRules: [[String: Int]] {
        if let one = config["StartCalendarInterval"] as? [String: Int] { return [one] }
        return config["StartCalendarInterval"] as? [[String: Int]] ?? []
    }
    var schedule: String {
        let rules = calendarRules
        if !rules.isEmpty {
            if rules.allSatisfy({ Set($0.keys).isSubset(of: ["Hour", "Minute"]) && $0["Hour"] != nil && $0["Minute"] != nil }) {
                return "每天 " + rules.map { String(format: "%02d:%02d", $0["Hour"]!, $0["Minute"]!) }.joined(separator: "、")
            }
            if let weekly = JobDraft.weeklySchedule(rules) {
                let names = ["日", "一", "二", "三", "四", "五", "六"]
                let days = weekly.days == [1, 2, 3, 4, 5] ? "周一至周五" :
                    [1, 2, 3, 4, 5, 6, 0].filter { weekly.days.contains($0) }.map { "周" + names[$0] }.joined(separator: "、")
                return days + " " + weekly.times.map(\.text).joined(separator: "、")
            }
            return "日历计划 · \(rules.count) 条规则"
        }
        if let seconds = config["StartInterval"] as? Int { return "每 \(seconds) 秒" }
        return config["RunAtLoad"] as? Bool == true ? "登录 / 加载时运行" : "按需触发"
    }
    var extraTriggers: [String] {
        ["RunAtLoad", "KeepAlive", "WatchPaths", "QueueDirectories", "StartOnMount", "Sockets", "MachServices", "LaunchEvents"].filter {
            guard let value = config[$0] else { return false }
            return (value as? Bool) != false
        }
    }
}

struct ServiceState {
    var loaded = false
    var pid: Int?
    var exitCode: Int?
    var text = ""
}

struct TimeSlot: Identifiable {
    var id = UUID()
    var hour = 6
    var minute = 0
    var text: String { String(format: "%02d:%02d", hour, minute) }
}

enum ScheduleMode: String, CaseIterable, Identifiable {
    case daily = "每天", weekly = "每周", interval = "固定间隔", advanced = "高级日历", manual = "移除时间计划"
    var id: String { rawValue }
}

struct JobDraft {
    var label = "local.my-task"
    var argumentLines = "/usr/bin/true"
    var directory = ""
    var stdout = ""
    var stderr = ""
    var mode: ScheduleMode = .daily
    var times = [TimeSlot()]
    var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    var interval = "60"
    var calendarJSON = "[\n  {\"Hour\": 6, \"Minute\": 0}\n]"
    var enableOnCreate = true
    var runAtLoad = false

    init(job: LaunchJob? = nil) {
        guard let job else { return }
        label = job.label
        argumentLines = job.arguments.joined(separator: "\n")
        directory = job.config["WorkingDirectory"] as? String ?? ""
        stdout = job.config["StandardOutPath"] as? String ?? ""
        stderr = job.config["StandardErrorPath"] as? String ?? ""
        runAtLoad = job.config["RunAtLoad"] as? Bool ?? false
        let rules = job.calendarRules
        if !rules.isEmpty {
            if let json = try? JSONSerialization.data(withJSONObject: rules, options: [.prettyPrinted, .sortedKeys]) {
                calendarJSON = String(decoding: json, as: UTF8.self)
            }
            let timeKeys: Set<String> = ["Hour", "Minute"]
            if rules.allSatisfy({ Set($0.keys).isSubset(of: timeKeys) && $0["Hour"] != nil && $0["Minute"] != nil }) && job.config["StartInterval"] == nil {
                mode = .daily
                times = rules.map { TimeSlot(hour: $0["Hour"]!, minute: $0["Minute"]!) }
            } else if job.config["StartInterval"] == nil, let weekly = Self.weeklySchedule(rules) {
                mode = .weekly
                times = weekly.times
                weekdays = weekly.days
            } else { mode = .advanced }
        } else if let value = job.config["StartInterval"] as? Int {
            mode = .interval
            interval = String(value)
        } else { mode = .manual }
    }

    static func weeklySchedule(_ rules: [[String: Int]]) -> (times: [TimeSlot], days: Set<Int>)? {
        guard !rules.isEmpty else { return nil }
        var daysByTime: [Int: Set<Int>] = [:]
        for rule in rules {
            guard Set(rule.keys) == ["Hour", "Minute", "Weekday"],
                  let hour = rule["Hour"], (0...23).contains(hour),
                  let minute = rule["Minute"], (0...59).contains(minute),
                  let weekday = rule["Weekday"], (0...7).contains(weekday) else { return nil }
            daysByTime[hour * 60 + minute, default: []].insert(weekday % 7)
        }
        guard let days = daysByTime.values.first,
              daysByTime.values.allSatisfy({ $0 == days }) else { return nil }
        let times = daysByTime.keys.sorted().map { TimeSlot(hour: $0 / 60, minute: $0 % 60) }
        return (times, days)
    }

    func validatedConfig(original: LaunchJob?) throws -> [String: Any] {
        guard !label.isEmpty, label.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw UserError("任务标识只能使用英文字母、数字、点、下划线和连字符。")
        }
        let arguments = argumentLines.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let program = arguments.first, program.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: program) else {
            throw UserError("第一行需要填写可执行文件的绝对路径，例如 /usr/bin/python3。")
        }
        guard directory.isEmpty || (directory.hasPrefix("/") && (try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) else {
            throw UserError("工作目录需要是已存在的绝对路径。")
        }
        for path in [stdout, stderr] where !path.isEmpty {
            guard path.hasPrefix("/"), (try? URL(fileURLWithPath: path).deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw UserError("日志路径需要是绝对路径，且上级文件夹已存在。")
            }
        }
        var config = original?.config ?? [:]
        config["Label"] = label
        if original == nil || argumentLines != original!.arguments.joined(separator: "\n") {
            config["ProgramArguments"] = arguments
            config.removeValue(forKey: "Program")
        }
        for (key, value) in [("WorkingDirectory", directory), ("StandardOutPath", stdout), ("StandardErrorPath", stderr)] {
            if value.isEmpty { config.removeValue(forKey: key) } else { config[key] = value }
        }
        if original == nil { config["RunAtLoad"] = runAtLoad; config["Disabled"] = !enableOnCreate }
        config.removeValue(forKey: "StartCalendarInterval")
        config.removeValue(forKey: "StartInterval")
        switch mode {
        case .daily, .weekly:
            guard !times.isEmpty, times.allSatisfy({ (0...23).contains($0.hour) && (0...59).contains($0.minute) }) else { throw UserError("请添加至少一个有效的时间。") }
            if mode == .weekly && weekdays.isEmpty { throw UserError("请至少选择一周中的一天。") }
            var rules: [[String: Int]] = []
            for time in times {
                let rule = ["Hour": time.hour, "Minute": time.minute]
                if mode == .weekly {
                    rules += weekdays.sorted().map { rule.merging(["Weekday": $0]) { _, b in b } }
                } else { rules.append(rule) }
            }
            let unique = Set(rules.map { ($0["Weekday"] ?? -1) * 1440 + $0["Hour"]! * 60 + $0["Minute"]! })
            guard unique.count == rules.count else { throw UserError("计划中有重复时间，请删除重复项。") }
            config["StartCalendarInterval"] = rules
        case .interval:
            guard let value = Int(interval), value > 0, value <= Int(Int32.max) else { throw UserError("间隔需要填写大于零的秒数。") }
            config["StartInterval"] = value
        case .advanced:
            let object = try JSONSerialization.jsonObject(with: Data(calendarJSON.utf8))
            let rawRules: [[String: Any]]
            if let one = object as? [String: Any] { rawRules = [one] }
            else if let many = object as? [[String: Any]] { rawRules = many }
            else { throw UserError("高级日历应为 JSON 对象或对象数组。") }
            let ranges = ["Minute": 0...59, "Hour": 0...23, "Day": 1...31, "Weekday": 0...7, "Month": 1...12]
            guard !rawRules.isEmpty else { throw UserError("请填写至少一条日历规则。") }
            for rule in rawRules {
                for (key, value) in rule {
                    guard let range = ranges[key], let number = value as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue == Double(number.intValue), range.contains(number.intValue) else {
                        throw UserError("日历字段或数值无效。允许 Minute、Hour、Day、Weekday、Month。")
                    }
                }
            }
            config["StartCalendarInterval"] = rawRules
            // Preserve a simultaneous interval when editing an existing advanced calendar.
            if let previous = original?.config["StartInterval"] { config["StartInterval"] = previous }
        case .manual: break
        }
        return config
    }
}

struct LaunchService {
    static let manager = FileManager.default
    static var userFolder: URL { JobScope.user.folders[0] }

    static func command(_ args: [String]) throws -> (code: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func checked(_ args: [String]) throws {
        let result = try command(args)
        guard result.code == 0 else { throw UserError("launchctl \(args.first ?? "") 失败（\(result.code)）\n\(result.text.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    static func overrides(_ domain: String) throws -> [String: Bool] {
        let response = try command(["print-disabled", domain])
        guard response.code == 0 else { throw UserError("读取启用状态失败\n\(response.text)") }
        let regex = try NSRegularExpression(pattern: "\"([^\"]+)\"\\s*=>\\s*(true|false|enabled|disabled)")
        let text = response.text as NSString
        var values: [String: Bool] = [:]
        for match in regex.matches(in: response.text, range: NSRange(location: 0, length: text.length)) {
            let state = text.substring(with: match.range(at: 2))
            values[text.substring(with: match.range(at: 1))] = state == "true" || state == "disabled"
        }
        return values
    }

    static func read(_ url: URL, scope: JobScope) throws -> LaunchJob {
        let data = try Data(contentsOf: url)
        guard let config = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], config["Label"] is String else {
            throw UserError("任务文件缺少有效的 Label。")
        }
        return LaunchJob(url: url, data: data, config: config, scope: scope, enabled: !(config["Disabled"] as? Bool ?? false))
    }

    static func list(_ scope: JobScope) throws -> (jobs: [LaunchJob], issues: [String]) {
        let disabled = try overrides("gui/\(getuid())")
        let systemDisabled = scope == .user ? [:] : try overrides("system")
        let live = try command(["list"])
        guard live.code == 0 else { throw UserError("读取任务列表失败\n\(live.text)") }
        var loaded: [String: (Int?, Int?)] = [:]
        for line in live.text.split(separator: "\n").dropFirst() {
            let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if columns.count >= 3 { loaded[String(columns[2])] = (Int(columns[0]), Int(columns[1])) }
        }
        var jobs: [LaunchJob] = []
        var issues: [String] = []
        for folder in scope.folders {
            if !manager.fileExists(atPath: folder.path) { continue }
            for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) where file.pathExtension == "plist" {
                do {
                    var job = try read(file, scope: scope)
                    if job.domain.hasPrefix("gui/") {
                        job.enabled = !(disabled[job.label] ?? (job.config["Disabled"] as? Bool ?? false))
                        job.loaded = loaded[job.label] != nil
                        job.pid = loaded[job.label]?.0
                        job.exitCode = loaded[job.label]?.1
                    } else {
                        job.enabled = !(systemDisabled[job.label] ?? (job.config["Disabled"] as? Bool ?? false))
                    }
                    jobs.append(job)
                } catch { issues.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
            }
        }
        return (jobs.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }, issues)
    }

    static func inspect(_ job: LaunchJob) throws -> ServiceState {
        let response = try command(["print", job.target])
        if response.code == 113 { return ServiceState(text: "当前未加载到 launchd。") }
        guard response.code == 0 else { throw UserError("无法读取服务状态\n\(response.text)") }
        func number(_ key: String) -> Int? {
            let lines = response.text.components(separatedBy: "\n")
            return lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + " = ") }
                .flatMap { Int($0.components(separatedBy: " = ").last?.trimmingCharacters(in: .whitespaces) ?? "") }
        }
        return ServiceState(loaded: true, pid: number("pid"), exitCode: number("last exit code"), text: response.text)
    }

    static func assertEditable(_ job: LaunchJob) throws {
        guard job.editable, job.url.deletingLastPathComponent().standardizedFileURL == userFolder.standardizedFileURL else {
            throw UserError("此版本支持修改当前用户的 LaunchAgents；共享和系统任务可查看。")
        }
    }

    static func setEnabled(_ job: LaunchJob, enabled: Bool) throws {
        try assertEditable(job)
        guard try Data(contentsOf: job.url) == job.data else { throw UserError("任务文件已变化，请刷新后重试。") }
        let wasEnabled = !(try overrides(job.domain)[job.label] ?? (job.config["Disabled"] as? Bool ?? false))
        let old = try inspect(job)
        try checked([enabled ? "enable" : "disable", job.target])
        do {
            if enabled && !old.loaded { try checked(["bootstrap", job.domain, job.url.path]) }
            if !enabled && old.loaded { try checked(["bootout", job.target]) }
        } catch {
            do { try checked([wasEnabled ? "enable" : "disable", job.target]) }
            catch { throw UserError("操作未完成，恢复原启用状态也失败，请刷新检查。\n\(error.localizedDescription)") }
            throw error
        }
    }

    static func save(_ draft: JobDraft, original: LaunchJob?) throws -> URL {
        let config = try draft.validatedConfig(original: original)
        let newData = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
        let url = original?.url ?? userFolder.appendingPathComponent(draft.label + ".plist")
        var wasLoaded = false
        var wroteNewFile = false
        var enabled = draft.enableOnCreate
        if let original {
            try assertEditable(original)
            guard try Data(contentsOf: url) == original.data else { throw UserError("任务文件已被其他程序修改，请刷新列表后重试。") }
            guard draft.label == original.label else { throw UserError("编辑已有任务时不能更改标识。") }
            wasLoaded = try inspect(original).loaded
            enabled = !(try overrides(original.domain)[original.label] ?? (original.config["Disabled"] as? Bool ?? false))
        } else {
            guard !manager.fileExists(atPath: url.path) else { throw UserError("已有同名任务，请更换标识。") }
            if try command(["print", "gui/\(getuid())/\(draft.label)"]).code == 0 { throw UserError("已有同名服务加载在当前用户会话中。") }
            try manager.createDirectory(at: userFolder, withIntermediateDirectories: true)
        }
        if wasLoaded { try checked(["bootout", original!.target]) }
        do {
            try newData.write(to: url, options: original == nil ? .withoutOverwriting : .atomic)
            wroteNewFile = original == nil
            if original == nil { try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            let target = "gui/\(getuid())/\(draft.label)"
            try checked([enabled ? "enable" : "disable", target])
            if enabled { try checked(["bootstrap", "gui/\(getuid())", url.path]) }
        } catch {
            let failure = error
            do {
                let target = "gui/\(getuid())/\(draft.label)"
                if (original != nil || wroteNewFile) && (try? command(["print", target]).code) == 0 { try checked(["bootout", target]) }
                if let original {
                    try original.data.write(to: url, options: .atomic)
                    try checked([enabled ? "enable" : "disable", original.target])
                    if wasLoaded { try checked(["bootstrap", original.domain, url.path]) }
                } else if wroteNewFile { try manager.removeItem(at: url) }
            } catch { throw UserError("保存失败且恢复原配置时遇到问题，请检查任务文件。\n原错误：\(failure.localizedDescription)\n恢复错误：\(error.localizedDescription)") }
            throw failure
        }
        return url
    }

    static func delete(_ job: LaunchJob) throws {
        try assertEditable(job)
        guard try Data(contentsOf: job.url) == job.data else { throw UserError("任务文件已变化，请刷新后重试。") }
        let state = try inspect(job)
        if state.loaded { try checked(["bootout", job.target]) }
        do { try manager.trashItem(at: job.url, resultingItemURL: nil) }
        catch {
            if state.loaded { try? checked(["bootstrap", job.domain, job.url.path]) }
            throw error
        }
    }

    static func logTail(_ path: String) -> String {
        guard !path.isEmpty else { return "此任务未配置日志文件。" }
        do {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            let length = try file.seekToEnd()
            try file.seek(toOffset: length > 65_536 ? length - 65_536 : 0)
            return String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return "日志尚未生成或无法读取。\n\(path)\n\(error.localizedDescription)" }
    }
}
