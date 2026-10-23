import Foundation
import SwiftUI
import UIKit
import Photos

struct OperationEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let message: String
}

struct ProjectorApp: Identifiable, Hashable {
    let id: String
    var name: String {
        let names = ["com.netease.uuremote": "网易 UU 远程", "com.netease.filmlytv": "网易爆米花",
                     "com.netease.cloudmusic.tv": "网易云音乐", "com.dangbeimarket": "当贝市场",
                     "com.tencent.qqmusicjimisdk": "QQ 音乐", "com.emotn.browser": "Emotn 浏览器",
                     "com.trim.tv": "飞牛影视", "com.oversea.aslauncher": "桌面启动器",
                     "tv.emby.embyatv.tg": "Emby", "com.uptodown": "Uptodown",
                     "com.xgimi.atmosphere": "极米屏保"]
        return names[id] ?? id.split(separator: ".").last.map(String.init) ?? id
    }
}

@MainActor
final class RemoteModel: ObservableObject {
    @Published var host: String = UserDefaults.standard.string(forKey: "projectorHost") ?? "192.168.1.100"
    @Published var online: Bool? = nil
    @Published var refreshing = false
    // Operation results go to local history; no toast or modal notification.
    var notice = "" {
        didSet { if !notice.isEmpty { record(notice) } }
    }
    @Published var logs: [OperationEntry] = []
    @Published var favorites: [String] = []
    @Published var recording = false
    @Published var recordingStarted: Date?
    @Published var recordingBusy = false
    @Published var savedVideo: URL?
    private var recordingTask: Task<Void, Never>?
    private var recordingPath: String?
    private var recordingPID: Int?
    private var recordingHost: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: "operationLogs"),
           let entries = try? JSONDecoder().decode([OperationEntry].self, from: data) { logs = entries }
        if let pending = UserDefaults.standard.dictionary(forKey: "pendingRecording") as? [String: String],
           let path = pending["path"], path.hasPrefix("/data/local/tmp/projector-record-"),
           path.range(of: #"^/data/local/tmp/projector-record-[A-Fa-f0-9-]+\.mp4$"#, options: .regularExpression) != nil,
           let pid = Int(pending["pid"] ?? ""), pid > 1, let target = pending["host"] {
            recordingPath = path; recordingPID = pid; recordingHost = target; recording = true
        }
        let stored = UserDefaults.standard.stringArray(forKey: "favoriteApps") ?? Array(repeating: "", count: 4)
        if let name = UserDefaults.standard.string(forKey: "latestRecording") {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { savedVideo = url }
        }
        favorites = Array((stored + Array(repeating: "", count: 4)).prefix(4))
    }
    func reloadLogs() {
        if let data = UserDefaults.standard.data(forKey: "operationLogs"),
           let entries = try? JSONDecoder().decode([OperationEntry].self, from: data) { logs = entries }
    }
    func record(_ message: String) {
        reloadLogs()
        logs.insert(OperationEntry(id: UUID(), date: Date(), message: message), at: 0)
        logs = Array(logs.prefix(300))
        if let data = try? JSONEncoder().encode(logs) { UserDefaults.standard.set(data, forKey: "operationLogs") }
    }
    func setFavorite(_ app: ProjectorApp?, slot: Int) {
        guard favorites.indices.contains(slot) else { return }
        favorites[slot] = app?.id ?? ""
        UserDefaults.standard.set(favorites, forKey: "favoriteApps")
        notice = "已更新常用应用"
    }
    @Published var values: [String: String] = [:]
    @Published var updatedAt: Date?
    @Published var apps: [ProjectorApp] = []
    @Published var appsLoading = false
    @Published var operation: String?
    @Published var uploadProgress: Double = 0
    @Published var screenImage: UIImage?
    @Published var screenshotLoading = false
    private var tail: Task<Void, Never>?
    private var pending = 0

    static let statusCommand = """
    printf 'model='; getprop ro.product.model
    printf 'android='; getprop ro.build.version.release
    printf 'build='; getprop ro.build.display.id
    printf 'patch='; getprop ro.build.version.security_patch
    printf 'uptime='; cat /proc/uptime
    printf 'load='; cat /proc/loadavg
    awk '/MemTotal:/{print "memTotal=" $2} /MemAvailable:/{print "memAvailable=" $2}' /proc/meminfo
    df -k /data | awk 'NR==2{print "diskTotal=" $2; print "diskUsed=" $3; print "diskAvailable=" $4}'
    dumpsys power | sed -n 's/.*mWakefulness=/power=/p'
    dumpsys activity activities | sed -n 's/.*mResumedActivity: .* u0 \\([^ /]*\\)\\/.*/foreground=\\1/p'
    wm size | sed -n 's/Physical size: /resolution=/p'
    wm density | sed -n 's/Physical density: /density=/p'
    """

    func saveHost(_ newHost: String) throws {
        let cleaned = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try ADBClient(host: cleaned)
        guard !recording && !recordingBusy else { throw RemoteError.message("请先结束录屏并完成传输") }
        host = cleaned; UserDefaults.standard.set(cleaned, forKey: "projectorHost")
        online = nil; values = [:]; apps = []; updatedAt = nil
        Task { await refresh() }
    }
    func shell(_ command: String, timeout: Double = 12) async throws -> String {
        let client = try ADBClient(host: host)
        return try await client.shell(command, timeout: timeout)
    }
    func refresh() async {
        guard !refreshing, operation == nil else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let output = try await shell(Self.statusCommand)
            let pairs = output.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let read = Dictionary(pairs, uniquingKeysWith: { _, newer in newer })
            guard read["android"] != nil else { throw RemoteError.message("设备未返回有效状态") }
            values = read; online = true; updatedAt = Date()
        } catch { online = false }
    }
    func press(_ key: Int) {
        guard [3, 4, 19, 20, 21, 22, 23, 24, 25, 66, 67, 82, 85, 164].contains(key) else { return }
        guard pending < 12 else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        pending += 1
        let previous = tail
        tail = Task {
            await previous?.value
            defer { pending -= 1 }
            do {
                let result = try await shell("input keyevent \(key)")
                if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw RemoteError.message(result)
                }
                online = true
                let names = [3: "主页", 4: "返回", 19: "向上", 20: "向下", 21: "向左", 22: "向右", 23: "确认", 24: "音量加", 25: "音量减", 66: "回车", 67: "退格", 82: "菜单", 85: "播放 / 暂停", 164: "静音"]
                notice = "已发送：\(names[key] ?? "按键")"
            } catch { notice = "指令未完成，请检查连接：\(error.localizedDescription)"; online = false }
        }
    }
    // On this projector KEYCODE_SLEEP(223) broke subsequent BLE wake.
    // KEYCODE_POWER(26) standby was verified to allow this app to wake it.
    // Recheck actual state because the power key is a toggle.
    static let standbyCommand = """
    state=$(dumpsys power | sed -n 's/.*mWakefulness=//p' | head -n 1)
    if [ "$state" = "Awake" ]; then
      input keyevent 26
    else
      printf 'STANDBY_NOT_SENT:%s' "$state"
    fi
    """
    func sendStandby() async throws {
        let output = try await shell(Self.standbyCommand)
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("STANDBY_NOT_SENT:") {
            throw RemoteError.message("设备不在运行状态，未重复发送电源键；请刷新状态")
        }
        guard result.isEmpty else { throw RemoteError.message(result) }
    }
    func sleepProjector() async {
        guard operation == nil else { return }
        operation = "正在发送待机指令"; defer { operation = nil }
        do {
            try await sendStandby()
            notice = "待机指令已发送，投影仪网络随后会断开。开机请使用蓝牙。"
            online = false
        } catch { notice = "未确认待机指令完成：\(error.localizedDescription)" }
    }
    func loadApps() async {
        guard !appsLoading else { return }
        appsLoading = true; defer { appsLoading = false }
        do {
            let output = try await shell("pm list packages -3")
            let list = output.split(separator: "\n").compactMap { line -> ProjectorApp? in
                guard line.hasPrefix("package:") else { return nil }
                let id = String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                return Self.validPackage(id) ? ProjectorApp(id: id) : nil
            }
            apps = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            online = true
            record("读取应用列表 · \(apps.count) 个第三方应用")
        } catch { notice = "读取应用失败：\(error.localizedDescription)" }
    }
    static func validPackage(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$"#, options: .regularExpression) != nil
    }
    func openApp(_ app: ProjectorApp) async {
        guard Self.validPackage(app.id), operation == nil else { return }
        operation = "正在打开 \(app.name)"; defer { operation = nil }
        do {
            let output = try await shell("monkey -p \(app.id) -c android.intent.category.LAUNCHER 1")
            if output.contains("No activities found") || output.contains("aborted") {
                throw RemoteError.message("该应用没有可启动的桌面入口")
            }
            notice = "已发送打开 \(app.name) 的指令"
        } catch { notice = error.localizedDescription }
    }
    func stopApp(_ app: ProjectorApp) async {
        guard Self.validPackage(app.id), operation == nil else { return }
        operation = "正在停止 \(app.name)"; defer { operation = nil }
        do { _ = try await shell("am force-stop \(app.id)"); notice = "已停止 \(app.name)" }
        catch { notice = error.localizedDescription }
    }
    func uninstall(_ app: ProjectorApp) async {
        guard apps.contains(app), Self.validPackage(app.id), operation == nil else { return }
        operation = "正在卸载 \(app.name)"
        do {
            // Recheck it is a user-installed app immediately before removal.
            let list = try await shell("pm list packages -3")
            guard list.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "package:" + app.id }) else {
                throw RemoteError.message("仅允许卸载列表中的第三方应用")
            }
            let output = try await shell("pm uninstall \(app.id)", timeout: 40)
            guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "Success" else { throw RemoteError.message(output) }
            apps.removeAll { $0.id == app.id }; notice = "已卸载 \(app.name)"
        } catch { notice = "卸载失败：\(error.localizedDescription)" }
        operation = nil
    }
    func install(_ file: URL) async {
        guard operation == nil else { return }
        operation = "正在上传 APK"; uploadProgress = 0
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() }; operation = nil }
        let path = "/data/local/tmp/projector-\(UUID().uuidString).apk"
        do {
            let wire = try ADBClient(host: host)
            try await withTaskCancellationHandler {
                try await wire.pushAPK(file, to: path) { [weak self] fraction in
                    Task { @MainActor in self?.uploadProgress = fraction }
                }
            } onCancel: { wire.close() }
            operation = "正在安装 APK"
            let result = try await shell("pm install -r \(path); rm -f \(path)", timeout: 120)
            guard result.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Success" }) else {
                throw RemoteError.message(result)
            }
            notice = "APK 安装成功"; operation = nil
            await loadApps()
        } catch {
            // Only remove the unique file created for this operation.
            let targetHost = host
            let cleanup = Task.detached { try await ADBClient(host: targetHost).shell("rm -f \(path)") }
            _ = try? await cleanup.value
            notice = Task.isCancelled ? "已取消安装" : "安装失败：\(error.localizedDescription)"
        }
    }
    func takeScreenshot() async {
        guard !screenshotLoading, !recordingBusy else { return }
        screenshotLoading = true; defer { screenshotLoading = false }
        do {
            let encoded = try await shell("screencap -p | base64", timeout: 25)
            guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
                  let image = UIImage(data: data) else { throw RemoteError.message("无法读取屏幕图像") }
            screenImage = image
            notice = "已获取当前画面"
        } catch { notice = "获取画面失败：\(error.localizedDescription)" }
    }
    func sendText(_ text: String) async {
        guard !text.isEmpty, text.count <= 200 else { notice = "请输入 200 字以内的文字"; return }
        guard text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) else {
            notice = "当前输入接口仅支持英文、数字和符号，中文请使用投影仪输入法"; return
        }
        // Quote the entire argument; users cannot inject shell syntax.
        let escaped = text.replacingOccurrences(of: " ", with: "%s").replacingOccurrences(of: "'", with: "'\\''")
        do { _ = try await shell("input text '\(escaped)'"); notice = "文字已发送" }
        catch { notice = "输入失败：\(error.localizedDescription)" }
    }
    private func photoPermission() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw RemoteError.message("请在 iPhone 设置中允许添加照片，或使用分享按钮保存到文件")
        }
    }
    func saveScreenshot() async {
        guard let image = screenImage else { return }
        do {
            try await photoPermission()
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            notice = "画面已保存至相册"
        } catch { notice = "保存失败：\(error.localizedDescription)" }
    }
    func saveVideoToPhotos() async {
        guard let url = savedVideo else { return }
        do {
            try await photoPermission()
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
            notice = "录屏已保存至相册"
        } catch { notice = "保存失败：\(error.localizedDescription)" }
    }
    func startRecording() async {
        guard !recording, !recordingBusy, operation == nil else { return }
        recordingBusy = true; defer { recordingBusy = false }
        let path = "/data/local/tmp/projector-record-\(UUID().uuidString).mp4"
        let target = host
        do {
            let output = try await shell("setsid nohup sh -c 'echo $$ > \(path).pid; exec screenrecord --size 1280x720 --bit-rate 1500000 --time-limit 60 \(path)' >\(path).log 2>&1 < /dev/null & sleep 1; cat \(path).pid")
            guard let pid = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { throw RemoteError.message("无法启动录屏：\(output)") }
            try await Task.sleep(for: .milliseconds(700))
            let check = try await shell("if tr '\\000' ' ' < /proc/\(pid)/cmdline 2>/dev/null | grep -Fq '\(path)'; then echo RUNNING; fi; cat \(path).log")
            guard check.contains("RUNNING") else { throw RemoteError.message("录屏启动失败：\(check)") }
            recordingPID = pid; recordingPath = path; recordingHost = target
            recording = true; recordingStarted = Date()
            UserDefaults.standard.set(["path": path, "pid": String(pid), "host": target], forKey: "pendingRecording")
            notice = "开始录屏 · 最长 60 秒，无声音"
            recordingTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.recordingTask = nil
                await self?.finishRecording()
            }
        } catch {
            _ = try? await ADBClient(host: target).shell("rm -f \(path) \(path).log \(path).pid")
            notice = "录屏失败：\(error.localizedDescription)"
        }
    }
    func finishRecording() async {
        guard recording, !recordingBusy, let path = recordingPath, let pid = recordingPID, let target = recordingHost else { return }
        recordingTask?.cancel(); recordingTask = nil
        recordingBusy = true
        defer { recordingBusy = false }
        do {
            // Check the unique path before signalling, so a reused PID is never stopped.
            _ = try await ADBClient(host: target).shell("if tr '\\000' ' ' < /proc/\(pid)/cmdline 2>/dev/null | grep -Fq '\(path)'; then kill -2 \(pid); fi")
            var stopped = false
            for _ in 0..<12 {
                let state = try await ADBClient(host: target).shell("tr '\\000' ' ' < /proc/\(pid)/cmdline 2>/dev/null")
                if !state.contains(path) { stopped = true; break }
                try await Task.sleep(for: .seconds(1))
            }
            guard stopped else { throw RemoteError.message("录屏仍在结束，请稍后再次点击停止") }
            recording = false; recordingStarted = nil
            let sizeOutput = try await ADBClient(host: target).shell("stat -c %s \(path)")
            guard let size = Int(sizeOutput.trimmingCharacters(in: .whitespacesAndNewlines)), size > 32, size < 16 * 1024 * 1024 else {
                throw RemoteError.message("录屏为空或超过传输上限")
            }
            let encoded = try await ADBClient(host: target).shell("base64 \(path)", timeout: 90)
            guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), data.count == size,
                  String(decoding: data.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp" else { throw RemoteError.message("录屏数据不完整，请再次下载") }
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let local = folder.appendingPathComponent("Projector-\(UUID().uuidString).mp4")
            try data.write(to: local, options: .atomic)
            savedVideo = local
            UserDefaults.standard.set(local.lastPathComponent, forKey: "latestRecording")
            _ = try? await ADBClient(host: target).shell("rm -f \(path) \(path).log \(path).pid")
            recordingPath = nil; recordingPID = nil; recordingHost = nil
            UserDefaults.standard.removeObject(forKey: "pendingRecording")
            notice = "录屏已下载，可保存至相册或分享"
        } catch {
            // Keep the remote path available for retry instead of silently discarding a capture.
            recording = true
            notice = "结束或下载失败，可重试：\(error.localizedDescription)"
        }
    }
    func cleanResources() async {
        guard operation == nil, !recording, !recordingBusy else { return }
        operation = "正在清理资源"
        do {
            // Android's cache manager only trims disposable cache; never pm clear or rm app data.
            let output = try await shell("am kill-all; a=$?; pm trim-caches 2147483647; b=$?; echo CLEAN_RESULT:$a:$b", timeout: 60)
            guard output.contains("CLEAN_RESULT:0:0"), !output.contains("Exception"), !output.contains("Error:") else { throw RemoteError.message(output) }
            operation = nil
            await refresh()
            notice = "已清理后台缓存进程和系统可回收缓存"
        } catch { operation = nil; notice = "清理未完成：\(error.localizedDescription)" }
    }
    func number(_ key: String) -> Double { Double(values[key]?.split(separator: " ").first ?? "") ?? 0 }
    func bytes(_ key: String) -> String {
        guard values[key] != nil else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(number(key) * 1024), countStyle: .binary)
    }
    var uptime: String {
        guard values["uptime"] != nil else { return "—" }
        let minutes = Int(number("uptime")) / 60
        return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
    }
    var foreground: String {
        guard let id = values["foreground"], !id.isEmpty else { return "—" }
        return ProjectorApp(id: id).name
    }
    var powerState: String {
        switch values["power"] {
        case "Awake": return "运行中"
        case "Asleep": return "待机"
        case "Dreaming": return "屏保"
        case "Dozing": return "休眠"
        default: return "—"
        }
    }
}
