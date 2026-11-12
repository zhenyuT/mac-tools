import SwiftUI
import AppKit

struct CialloPanel: View {
    let job: LaunchJob
    @State private var run: CialloRun?
    @State private var loadError: String?
    @State private var reading = false
    @State private var initial = true
    private var root: URL { CialloLogReader.root(for: job) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("最新一轮执行").font(.title3.bold())
                    Text(run?.title ?? "按日志目录读取最近一轮记录").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if reading { ProgressView().controlSize(.small) }
                Button { Task { await reload() } } label: { Label("刷新结果", systemImage: "arrow.clockwise") }.disabled(reading)
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let run {
                HStack {
                    Label(run.summary, systemImage: run.reportError != nil || run.clients.contains(where: { $0.status == .failed }) ? "exclamationmark.circle" : "clock.badge.checkmark")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if let start = run.startedAt, let end = run.finishedAt {
                        Text(String(format: "总耗时 %.1f 秒", max(0, end.timeIntervalSince(start)))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 20) {
                    if let start = run.startedAt { timestamp("开始", start) }
                    if let end = run.finishedAt { timestamp("结束", end) }
                }
                if let error = run.reportError {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(run.clients) { client in clientCard(client) }
                }
                Label("“已入队”表示消息已提交，日志中的状态不包含之后的模型回复进度。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if !run.hasResult {
                    Text("本轮还没有结束记录，可能仍在执行或曾经中断。面板会每 5 秒重新读取。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(run.clients) { client in
                    DisclosureGroup {
                        Text(client.logText).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                    } label: {
                        HStack {
                            Label(client.id + " 执行日志（末尾 64 KB）", systemImage: "doc.text")
                            Spacer()
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([client.logURL]) }
                                .font(.caption).disabled(!client.logExists)
                        }
                    }
                }
            } else if initial {
                Text("正在读取执行记录…").foregroundStyle(.secondary)
            } else {
                Label("尚未发现执行记录", systemImage: "clock").font(.headline)
                Text("下一轮运行后，将在这里显示两个客户端各自的结果。").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text(root.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("打开日志目录") { NSWorkspace.shared.open(root) }.disabled(!FileManager.default.fileExists(atPath: root.path))
            }
            Text("每 5 秒自动刷新 · 仅读取本机日志").font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: root.path) {
            await reload()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                await reload()
            }
        }
    }

    private func clientCard(_ client: CialloClientResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(client.id).font(.headline)
                Spacer()
                Text(client.status.rawValue).font(.caption.weight(.semibold)).foregroundStyle(color(client.status))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(color(client.status).opacity(0.12), in: Capsule())
            }
            HStack {
                Text("命令退出码").foregroundStyle(.secondary)
                Text(client.exitCode.map(String.init) ?? "尚无记录").monospacedDigit()
            }.font(.caption)
            if let reply = client.reply, !reply.isEmpty {
                Text(reply).font(.callout).textSelection(.enabled)
            }
            if let error = client.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let queueID = client.queueID { identifier("入队消息", queueID) }
            if let threadID = client.threadID { identifier("会话", threadID) }
            if !client.logExists { Text("详细日志文件暂不可用").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading).padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
    private func identifier(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(2)
        }
    }
    private func timestamp(_ title: String, _ date: Date) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)).monospacedDigit()
        }.font(.caption)
    }
    private func color(_ status: CialloClientStatus) -> Color {
        switch status {
        case .completed: return .green
        case .queued: return .orange
        case .failed: return .red
        case .ended: return .blue
        case .pending: return .secondary
        }
    }
    @MainActor
    private func reload() async {
        guard !reading else { return }
        reading = true
        let directory = root
        do {
            let value = try await Task.detached { try CialloLogReader.latest(in: directory) }.value
            guard !Task.isCancelled else { reading = false; return }
            run = value
            loadError = nil
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        initial = false
        reading = false
    }
}
