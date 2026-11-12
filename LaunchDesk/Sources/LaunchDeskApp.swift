import SwiftUI
import AppKit

@MainActor
final class TaskStore: ObservableObject {
    @Published var jobs: [LaunchJob] = []
    @Published var scope: JobScope = .user
    @Published var selected: String?
    @Published var busy = false
    @Published var error: String?
    @Published var notice = ""
    @Published var issues: [String] = []
    @Published var state: ServiceState?
    @Published var log = ""
    @Published var logKind = "StandardOutPath"
    var current: LaunchJob? { jobs.first { $0.id == selected } }

    func refresh(select path: String? = nil) {
        guard !busy else { return }
        busy = true
        let requestedScope = scope
        Task {
            do {
                let result = try await Task.detached { try LaunchService.list(requestedScope) }.value
                jobs = result.jobs
                issues = result.issues
                if let path { selected = path }
                if !jobs.contains(where: { $0.id == selected }) {
                    selected = jobs.first(where: { $0.label == "local.codex.ciallo-daily" })?.id ?? jobs.first?.id
                }
                busy = false
                inspect()
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }

    func inspect() {
        state = nil
        log = ""
        guard let job = current else { return }
        let kind = logKind
        Task {
            do {
                let result = try await Task.detached { try LaunchService.inspect(job) }.value
                let tail = await Task.detached { LaunchService.logTail(job.config[kind] as? String ?? "") }.value
                guard selected == job.id, logKind == kind else { return }
                state = result
                log = tail
            } catch { if selected == job.id { self.error = error.localizedDescription } }
        }
    }

    func perform(_ success: String, operation: @escaping () throws -> String?) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let path = try await Task.detached { try operation() }.value
                notice = success
                busy = false
                refresh(select: path)
            } catch {
                busy = false
                self.error = error.localizedDescription
                refresh()
            }
        }
    }

    func toggle(_ job: LaunchJob, enabled: Bool) {
        perform(enabled ? "任务已启用并加载" : "任务已停用") {
            try LaunchService.setEnabled(job, enabled: enabled)
            return job.id
        }
    }
}

@main
struct LaunchDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = TaskStore()
    init() {
        if CommandLine.arguments.contains("--self-test") {
            do { try SelfTests.run(); print("SELF TESTS PASSED"); exit(0) }
            catch { fputs("SELF TEST FAILED: \(error)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup("LaunchDesk · 定时管家") {
            MainView().environmentObject(store)
                .frame(minWidth: 1000, minHeight: 700)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .tint(Color(red: 0.22, green: 0.38, blue: 0.84))
        }
        .defaultSize(width: 1160, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建任务…") { NotificationCenter.default.post(name: .newLaunchJob, object: nil) }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("刷新任务") { store.refresh() }.keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
extension Notification.Name { static let newLaunchJob = Notification.Name("newLaunchJob") }

struct MainView: View {
    struct EditorRequest: Identifiable { let id = UUID(); let job: LaunchJob? }
    @EnvironmentObject private var store: TaskStore
    @State private var search = ""
    @State private var editor: EditorRequest?
    @State private var pendingToggle: LaunchJob?
    @State private var showDelete = false
    @State private var tab = "概览"
    private var filtered: [LaunchJob] {
        store.jobs.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.command.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 11) {
                    Image(systemName: "clock.badge.checkmark.fill").font(.system(size: 27)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LaunchDesk").font(.title3.weight(.bold))
                        Text("本机任务 · 有序运行").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 14)
                Picker("任务范围", selection: $store.scope) {
                    ForEach(JobScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
                }.labelsHidden().disabled(store.busy)
                TextField("搜索名称或命令", text: $search).textFieldStyle(.roundedBorder)
                HStack { Text("\(filtered.count) 个任务"); Spacer(); if store.busy { ProgressView().controlSize(.small) } }
                    .font(.caption).foregroundStyle(.secondary)
                List(selection: $store.selected) {
                    ForEach(filtered) { job in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                Circle().fill(job.enabled ? Color.green : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                                Text(job.label).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                            }
                            Text(job.schedule).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 7).tag(job.id)
                    }
                }.listStyle(.sidebar).padding(.horizontal, -12)
                Button { editor = EditorRequest(job: nil) } label: {
                    Label("新建我的任务", systemImage: "plus").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.busy)
                Text("当前用户可管理 · 系统任务可查看").font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.bottom, 16)
                .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 390)
        } detail: {
            if let job = store.current { detail(job) }
            else {
                VStack(spacing: 14) {
                    Image(systemName: "calendar.badge.clock").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text(store.busy ? "正在读取本机任务…" : "选择或新建一个任务").font(.title2)
                    Text("在一个窗口里设置时间、开关任务与查看运行日志").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem { Button { store.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(store.busy) }
        }
        .onAppear { store.refresh() }
        .onChange(of: store.scope) { search = ""; store.refresh() }
        .onChange(of: store.selected) { tab = store.current?.hasCialloPanel == true ? "最新执行" : "概览"; store.inspect() }
        .onChange(of: store.logKind) { store.inspect() }
        .onReceive(NotificationCenter.default.publisher(for: .newLaunchJob)) { _ in editor = EditorRequest(job: nil) }
        .sheet(item: $editor) { request in JobEditor(job: request.job).environmentObject(store) }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("停用将结束此任务当前正在运行的进程。", isPresented: Binding(get: { pendingToggle != nil }, set: { if !$0 { pendingToggle = nil } }), titleVisibility: .visible) {
            Button("停用并结束运行", role: .destructive) { if let job = pendingToggle { store.toggle(job, enabled: false) }; pendingToggle = nil }
        }
        .confirmationDialog("将任务移到废纸篓？已加载的任务会先停止。", isPresented: $showDelete, titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) {
                if let job = store.current { store.perform("任务已移到废纸篓") { try LaunchService.delete(job); return nil } }
            }
        }
    }

    private func detail(_ job: LaunchJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.label).font(.system(size: 25, weight: .bold)).textSelection(.enabled)
                        HStack(spacing: 9) {
                            Label(job.scope.rawValue, systemImage: job.editable ? "person.crop.circle" : "lock")
                            Text("·")
                            Text(status(job)).foregroundStyle(job.enabled ? .green : .secondary)
                        }.font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("启用任务", isOn: Binding(get: { job.enabled }, set: { enabled in
                        if !enabled && (store.state?.pid ?? job.pid ?? 0) > 0 { pendingToggle = job }
                        else { store.toggle(job, enabled: enabled) }
                    }))
                    .toggleStyle(.switch).disabled(!job.editable || store.busy).fixedSize()
                }
                HStack(spacing: 12) {
                    stat("运行计划", job.schedule, "calendar")
                    stat("加载状态", (store.state?.loaded ?? job.loaded ?? false) ? "已加载" : "未加载", "square.stack.3d.up")
                    stat("最近退出码", (store.state?.exitCode ?? job.exitCode).map(String.init) ?? "暂无记录", "checkmark.seal")
                }
                HStack {
                    Button { editor = EditorRequest(job: job) } label: { Label("编辑任务与时间", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.borderedProminent).disabled(!job.editable || store.busy)
                    if job.enabled && store.state?.loaded == false {
                        Button("加载计划") { store.toggle(job, enabled: true) }.disabled(!job.editable || store.busy)
                    }
                    Menu {
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                        Button("复制任务标识") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(job.label, forType: .string) }
                        Divider()
                        Button("移到废纸篓…", role: .destructive) { showDelete = true }.disabled(!job.editable || store.busy)
                    } label: { Image(systemName: "ellipsis") }
                    Spacer()
                    if !store.notice.isEmpty { Text(store.notice).font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(28)
            Divider()
            Picker("详情", selection: $tab) { ForEach(job.hasCialloPanel ? ["最新执行", "概览", "日志", "配置"] : ["概览", "日志", "配置"], id: \.self) { Text($0) } }
                .pickerStyle(.segmented).padding(.horizontal, 28).padding(.vertical, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if tab == "最新执行" && job.hasCialloPanel {
                        CialloPanel(job: job)
                    } else if tab == "概览" {
                        info("执行命令", job.arguments.joined(separator: "\n"), mono: true)
                        info("工作目录", job.config["WorkingDirectory"] as? String ?? "使用 launchd 默认目录")
                        info("计划时区", TimeZone.current.identifier + "（沿用 macOS 系统时区）")
                        if !job.extraTriggers.isEmpty {
                            Label("此任务还有其他触发条件：" + job.extraTriggers.joined(separator: "、"), systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        info("任务文件", job.url.path, mono: true)
                        if !job.editable { Text("此任务位于共享或系统目录，或通过符号链接提供。当前可查看配置和运行状态。").foregroundStyle(.secondary).font(.callout) }
                        if !store.issues.isEmpty { info("读取提示", store.issues.joined(separator: "\n")) }
                    } else if tab == "日志" {
                        HStack {
                            Picker("日志", selection: $store.logKind) { Text("标准输出").tag("StandardOutPath"); Text("错误输出").tag("StandardErrorPath") }
                                .pickerStyle(.segmented).frame(width: 230)
                            Spacer()
                            Button("重新读取") { store.inspect() }
                        }
                        Text(job.config[store.logKind] as? String ?? "未配置日志路径").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(store.log.isEmpty ? "日志为空" : store.log).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        Text("显示文件末尾最多 64 KB").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        info("原始配置", String(decoding: (try? PropertyListSerialization.data(fromPropertyList: job.config, format: .xml, options: 0)) ?? Data(), as: UTF8.self), mono: true)
                        info("launchd 状态", store.state?.text ?? "正在读取…", mono: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.bottom, 28)
            }
            Divider()
            HStack {
                Label("本地管理 · launchd", systemImage: "desktopcomputer")
                Spacer()
                Text("日历任务会在休眠唤醒后补触发")
            }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 12)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func status(_ job: LaunchJob) -> String {
        if !job.enabled { return "已停用" }
        if (store.state?.pid ?? job.pid ?? 0) > 0 { return "正在运行" }
        return (store.state?.loaded ?? job.loaded ?? false) ? "已启用 · 等待触发" : "已启用 · 等待加载"
    }
    private func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(15).frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
    private func info(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.callout.weight(.semibold))
            Text(value).font(mono ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct JobEditor: View {
    let job: LaunchJob?
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: JobDraft
    @State private var validationError: String?
    @State private var confirmReload = false
    init(job: LaunchJob?) { self.job = job; _draft = State(initialValue: JobDraft(job: job)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job == nil ? "新建定时任务" : "编辑任务").font(.title2.bold())
                    Text("保存后应用到当前用户的 launchd").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title2) }.buttonStyle(.plain)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("任务标识").font(.headline)
                        TextField("local.my-task", text: $draft.label).textFieldStyle(.roundedBorder).disabled(job != nil)
                        Text("唯一名称，例如 local.daily-backup").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("什么时候运行").font(.headline)
                        Picker("计划类型", selection: $draft.mode) { ForEach(ScheduleMode.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden()
                        if draft.mode == .daily || draft.mode == .weekly {
                            if draft.mode == .weekly {
                                HStack(spacing: 8) {
                                    ForEach(Array([1,2,3,4,5,6,0].enumerated()), id: \.element) { index, day in
                                        Button(["一","二","三","四","五","六","日"][index]) {
                                            if draft.weekdays.contains(day) { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                                        }.buttonStyle(.bordered).tint(draft.weekdays.contains(day) ? .blue : .gray)
                                            .background(draft.weekdays.contains(day) ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }.padding(.vertical, 4)
                            }
                            ForEach($draft.times) { $time in
                                HStack {
                                    Image(systemName: "clock").foregroundStyle(.secondary)
                                    DatePicker("运行时间", selection: timeBinding($time), displayedComponents: .hourAndMinute).labelsHidden()
                                        .datePickerStyle(.field)
                                    Text(TimeZone.current.identifier).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button { draft.times.removeAll { $0.id == time.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).disabled(draft.times.count == 1)
                                }.padding(9).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            }
                            Button { draft.times.append(TimeSlot(hour: 12)) } label: { Label("添加一个时间", systemImage: "plus") }
                        } else if draft.mode == .interval {
                            HStack { Text("每隔"); TextField("60", text: $draft.interval).textFieldStyle(.roundedBorder).frame(width: 100); Text("秒运行一次") }
                        } else if draft.mode == .advanced {
                            Text("可设置 Minute、Hour、Day、Weekday、Month。省略字段表示任意值，Weekday 的 0 和 7 都表示周日。").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $draft.calendarJSON).font(.system(.callout, design: .monospaced)).frame(height: 135).border(.quaternary)
                        } else {
                            Text("移除日历和固定间隔设置。任务已有的其他触发条件继续生效。").font(.callout).foregroundStyle(.secondary)
                        }
                        if let job, !job.extraTriggers.isEmpty { Text("其他触发条件：" + job.extraTriggers.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
                        Text("计划使用 macOS 当前系统时区。休眠时错过的日历触发会在唤醒后合并执行。").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        Text("执行命令与参数").font(.headline)
                        Text("第一行填写可执行文件的绝对路径，其余每行一个参数。路径里的空格直接保留。").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.argumentLines).font(.system(.callout, design: .monospaced)).frame(height: 110).border(.quaternary)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text("工作目录").font(.headline)
                        HStack {
                            TextField("可选，填写文件夹绝对路径", text: $draft.directory).textFieldStyle(.roundedBorder)
                            Button("选择…") { chooseDirectory() }
                        }
                    }
                    DisclosureGroup("输出日志路径") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("标准输出的绝对路径", text: $draft.stdout).textFieldStyle(.roundedBorder)
                            TextField("错误输出的绝对路径", text: $draft.stderr).textFieldStyle(.roundedBorder)
                        }.padding(.top, 8)
                    }
                    if job == nil {
                        Toggle("保存后启用任务", isOn: $draft.enableOnCreate)
                        Toggle("登录或加载时立即执行", isOn: $draft.runAtLoad)
                    }
                    if let validationError { Label(validationError, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red).font(.callout) }
                }.padding(24)
            }
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存并应用") {
                    do {
                        _ = try draft.validatedConfig(original: job)
                        if job != nil && (store.state?.pid ?? job?.pid ?? 0) > 0 { confirmReload = true }
                        else { save() }
                    } catch { validationError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(store.busy)
            }.padding(20)
        }.frame(width: 680, height: 760)
        .confirmationDialog("应用新配置将重新加载任务，当前运行的进程会结束。", isPresented: $confirmReload, titleVisibility: .visible) {
            Button("保存并重新加载") { save() }
        }
    }
    private func timeBinding(_ slot: Binding<TimeSlot>) -> Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: slot.wrappedValue.hour, minute: slot.wrappedValue.minute, second: 0, of: Date()) ?? Date() }, set: {
            let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
            slot.wrappedValue.hour = components.hour ?? 0
            slot.wrappedValue.minute = components.minute ?? 0
        })
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { draft.directory = panel.url?.path ?? "" }
    }
    private func save() {
        let currentDraft = draft
        store.perform("任务配置已保存") { try LaunchService.save(currentDraft, original: job).path }
        dismiss()
    }
}
