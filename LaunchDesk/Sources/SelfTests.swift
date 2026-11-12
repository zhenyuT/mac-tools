import Foundation

struct SelfTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw UserError(message) }
    }
    static func run() throws {
        try CialloLogTests.run()
        let label = "local.launchdesk.selftest." + UUID().uuidString.lowercased()
        let url = LaunchService.userFolder.appendingPathComponent(label + ".plist")
        let domain = "gui/\(getuid())"
        defer {
            if (try? LaunchService.command(["print", domain + "/" + label]).code) == 0 {
                try? LaunchService.checked(["bootout", domain + "/" + label])
            }
            try? FileManager.default.removeItem(at: url)
        }
        var draft = JobDraft()
        draft.label = label
        draft.argumentLines = "/usr/bin/true"
        draft.enableOnCreate = false
        draft.times = [TimeSlot(hour: (Calendar.current.component(.hour, from: Date()) + 12) % 24, minute: 41)]
        _ = try LaunchService.save(draft, original: nil)
        var job = try LaunchService.list(.user).jobs.first { $0.label == label }.unwrap("新任务未在列表出现")
        try require(!job.enabled, "新任务的停用状态未持久化")
        try require(!(try LaunchService.inspect(job)).loaded, "新建停用任务不应加载")
        try LaunchService.setEnabled(job, enabled: true)
        job = try LaunchService.list(.user).jobs.first { $0.label == label }.unwrap("任务丢失")
        try require(job.enabled, "启用状态未更新")
        try require((try LaunchService.inspect(job)).loaded, "启用后没有加载")
        try LaunchService.setEnabled(job, enabled: false)
        job = try LaunchService.list(.user).jobs.first { $0.label == label }.unwrap("任务丢失")
        var config = job.config
        config["EnvironmentVariables"] = ["LAUNCHDESK_TEST": "preserve me"]
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(to: url, options: .atomic)
        do {
            _ = try LaunchService.save(JobDraft(job: job), original: job)
            throw UserError("未拦截并发修改")
        } catch let error as UserError {
            try require(error.message.contains("其他程序修改"), "并发修改检测错误：\(error.message)")
        }
        job = try LaunchService.read(url, scope: .user)
        job.enabled = false
        var intervalDraft = JobDraft(job: job)
        intervalDraft.mode = .interval
        intervalDraft.interval = "3600"
        _ = try LaunchService.save(intervalDraft, original: job)
        job = try LaunchService.read(url, scope: .user)
        try require(job.config["StartInterval"] as? Int == 3600, "间隔未保存")
        try require(job.config["StartCalendarInterval"] == nil, "旧日历未移除")
        try require((job.config["EnvironmentVariables"] as? [String: String])?["LAUNCHDESK_TEST"] == "preserve me", "未知字段丢失")
        var weekly = JobDraft(job: job)
        weekly.mode = .weekly
        weekly.weekdays = [1, 3, 5]
        weekly.times = [TimeSlot(hour: 6), TimeSlot(hour: 11, minute: 30)]
        let weeklyConfig = try weekly.validatedConfig(original: job)
        try require((weeklyConfig["StartCalendarInterval"] as? [[String: Int]])?.count == 6, "周计划展开错误")
        // Round-trip through a real plist, covering the user's four weekday times.
        weekly.weekdays = [1, 2, 3, 4, 5]
        weekly.times = [TimeSlot(hour: 6), TimeSlot(hour: 8), TimeSlot(hour: 11, minute: 5), TimeSlot(hour: 16, minute: 10)]
        _ = try LaunchService.save(weekly, original: job)
        job = try LaunchService.read(url, scope: .user)
        let reopened = JobDraft(job: job)
        try require(reopened.mode == .weekly, "重新打开周计划时错误降级为高级日历")
        try require(reopened.weekdays == [1, 2, 3, 4, 5], "重新打开后星期不一致")
        try require(reopened.times.map(\.text) == ["06:00", "08:00", "11:05", "16:10"], "重新打开后时间不一致")
        let reopenedConfig = try reopened.validatedConfig(original: job)
        try require(reopenedConfig["StartCalendarInterval"] as? [[String: Int]] == job.calendarRules, "周计划再次保存不一致")
        let sparse = [["Hour": 6, "Minute": 0, "Weekday": 1], ["Hour": 8, "Minute": 0, "Weekday": 2]]
        try require(JobDraft.weeklySchedule(sparse) == nil, "不规则周计划被错误展开")
        let sunday = JobDraft.weeklySchedule([["Hour": 6, "Minute": 0, "Weekday": 7]])
        try require(sunday?.days == [0], "周日 7 未正确规范为 0")
        try require(JobDraft.weeklySchedule([["Hour": 6, "Minute": 0, "Weekday": 1, "Month": 12]]) == nil, "带月份限制的规则被错误简化")
        var advanced = weekly
        advanced.mode = .advanced
        advanced.calendarJSON = "[{\"Hour\":24}]"
        do {
            _ = try advanced.validatedConfig(original: job)
            throw UserError("错误日历未拒绝")
        } catch let error as UserError {
            try require(error.message.contains("字段或数值无效"), "日历校验错误")
        }
        try require(LaunchService.logTail("").contains("未配置"), "空日志处理错误")
        print("通过：创建、列表、持久启停、加载卸载、并发修改保护、未知字段保留、间隔和周计划、日历校验。")
    }
}

extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw UserError(message) }
        return value
    }
}
