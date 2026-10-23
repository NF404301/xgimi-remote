import SwiftUI
import UniformTypeIdentifiers
import AVKit

private struct RemoteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? Color.primary.opacity(0.17) : Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 24))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct RemoteRootView: View {
    @StateObject private var remote = RemoteModel()
    @ObservedObject var beacon: BeaconSender
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var wakeStatus: String?
    @State private var wakeStatusTask: Task<Void, Never>?
    @State private var wakeCheckTask: Task<Void, Never>?
    @State private var settings = false
    @State private var favoriteSlot: Int?
    @State private var editingFavorites = false
    @State private var showLogs = false
    @State private var confirmSleep = false
    @State private var input = false
    @State private var text = ""
    @State private var directions = false
    @State private var drag: CGSize = .zero
    @State private var apk: URL?
    @State private var importFile = false
    @State private var uninstall: ProjectorApp?
    @State private var stopping: ProjectorApp?
    @State private var search = ""
    @State private var installTask: Task<Void, Never>?

    private var mainContent: some View {
        TabView(selection: $tab) {
            NavigationStack { remotePage }.tabItem { Label("遥控", systemImage: "appletvremote.gen4") }.tag(0)
            NavigationStack { appsPage }.tabItem { Label("应用", systemImage: "square.grid.2x2") }.tag(1)
            NavigationStack { devicePage }.tabItem { Label("设备", systemImage: "slider.horizontal.3") }.tag(2)
        }
        .tint(.primary)
        .sheet(isPresented: $settings) { ConnectionSettings(remote: remote) }
        .sheet(isPresented: $showLogs) { OperationLogView(remote: remote).onAppear { remote.reloadLogs() } }
        .sheet(isPresented: Binding(get: { favoriteSlot != nil }, set: { if !$0 { favoriteSlot = nil } })) {
            FavoritePicker(remote: remote) { app in
                if let slot = favoriteSlot { remote.setFavorite(app, slot: slot) }
                favoriteSlot = nil
            }
        }
        .onChange(of: beacon.status) { _, status in
            remote.record("蓝牙 · " + status)
            showWakeStatus(status, temporary: !beacon.busy)
        }
        .onChange(of: beacon.busy) { old, busy in
            if old && !busy { showWakeStatus(beacon.status, temporary: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && remote.recording { remote.record("App 离开前台；投影仪录屏最多 60 秒，返回后请结束并下载") }
        }
        .sheet(isPresented: $input) {
            NavigationStack {
                Form {
                    TextField("发送到投影仪", text: $text, axis: .vertical).lineLimit(3...6).autocorrectionDisabled()
                    Text("支持英文、数字和常用符号。中文可使用投影仪屏幕键盘。").font(.footnote).foregroundStyle(.secondary)
                    Button("发送文字") { let send = text; input = false; Task { await remote.sendText(send) } }.disabled(text.isEmpty)
                    Button("退格") { remote.press(67) }
                    Button("回车") { remote.press(66) }
                }.navigationTitle("键盘输入").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { input = false } } }
            }.presentationDetents([.medium, .large])
        }
    }

    private var confirmationContent: some View {
        mainContent
        .alert("让投影仪进入待机？", isPresented: $confirmSleep) {
            Button("取消", role: .cancel) { }
            Button("待机", role: .destructive) { Task { await remote.sleepProjector() } }
        } message: { Text("会中断当前播放，网络遥控随后断开。") }
        .alert("安装这个 APK？", isPresented: Binding(get: { apk != nil }, set: { if !$0 { apk = nil } })) {
            Button("取消", role: .cancel) { apk = nil }
            Button("安装") { if let file = apk { apk = nil; installTask = Task { await remote.install(file) } } }
        } message: { Text("\(apk?.lastPathComponent ?? "")\n将安装到投影仪；相同包名的应用可能被更新。") }
        .alert("卸载应用？", isPresented: Binding(get: { uninstall != nil }, set: { if !$0 { uninstall = nil } })) {
            Button("取消", role: .cancel) { uninstall = nil }
            Button("卸载", role: .destructive) { if let app = uninstall { uninstall = nil; Task { await remote.uninstall(app) } } }
        } message: { Text("\(uninstall?.name ?? "")\n\(uninstall?.id ?? "")\n应用及其本地数据将被删除。") }
        .alert("停止应用？", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
            Button("取消", role: .cancel) { stopping = nil }
            Button("停止", role: .destructive) { if let app = stopping { stopping = nil; Task { await remote.stopApp(app) } } }
        } message: { Text("停止 \(stopping?.name ?? "") 会中断它正在进行的播放或任务。") }
    }

    var body: some View {
        confirmationContent
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                guard url.pathExtension.lowercased() == "apk" else { remote.notice = "请选择标准 .apk 文件"; return }
                apk = url
            case .failure(let error): remote.notice = error.localizedDescription
            }
        }
        .onOpenURL { url in
            guard url.scheme == "projectorwake" else { return }
            if url.host == "wake" { wake() }
            if url.host == "sleep" { confirmSleep = true }
        }
        .task {
            while !Task.isCancelled {
                if scenePhase == .active { await remote.refresh() }
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    private var remotePage: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Button { settings = true } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) { Text("Z6X 第五代").font(.title2.weight(.semibold)); Image(systemName: "chevron.down").font(.caption.weight(.bold)) }
                            HStack(spacing: 6) {
                                Circle().fill(beacon.busy ? Color.blue : remote.online == true ? Color.green : Color.secondary).frame(width: 6, height: 6)
                                Text(beacon.busy ? beacon.status : wakeStatus ?? (remote.online == true ? "已连接 · \(remote.host)" : remote.online == false ? "未连接 · 可用蓝牙开机" : "正在连接…"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.updatesFrequently)
                            }
                        }.frame(minHeight: 52)
                    }.buttonStyle(.plain)
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Button { wake() } label: {
                            VStack(spacing: 5) { Image(systemName: "power").font(.title3); Text("开机").font(.caption2) }.frame(width: 48, height: 56)
                        }.buttonStyle(RemoteButtonStyle()).disabled(beacon.busy).accessibilityLabel("蓝牙开机")
                        Button { confirmSleep = true } label: {
                            VStack(spacing: 5) { Image(systemName: "moon").font(.title3); Text("待机").font(.caption2) }.frame(width: 48, height: 56)
                        }.buttonStyle(RemoteButtonStyle()).disabled(remote.online != true || remote.recording || remote.recordingBusy).accessibilityLabel("关机并进入待机")
                    }
                }
                VStack(spacing: 4) {
                    HStack {
                        Text("常用应用").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button(editingFavorites ? "完成" : "编辑") { editingFavorites.toggle() }
                            .font(.subheadline.weight(.medium)).frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel(editingFavorites ? "完成快捷应用编辑" : "编辑四个快捷应用")
                    }
                    favoritesRow
                    if editingFavorites { Text("点击任意位置，从投影仪已安装应用中选择").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                }
                Picker("遥控方式", selection: $directions) {
                    Label("触控板", systemImage: "hand.draw").tag(false)
                    Label("方向键", systemImage: "dpad").tag(true)
                }.pickerStyle(.segmented)
                touchArea
                HStack(spacing: 18) {
                    control("chevron.backward", "返回", 4)
                    control("house", "主页", 3)
                    control("line.3.horizontal", "菜单", 82)
                }
                HStack(spacing: 18) {
                    control("playpause.fill", "播放或暂停", 85, height: 76)
                    HStack(spacing: 0) {
                        Button { remote.press(25) } label: { Image(systemName: "minus").frame(maxWidth: .infinity).frame(height: 76) }.accessibilityLabel("降低音量")
                        Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1, height: 24)
                        Button { remote.press(24) } label: { Image(systemName: "plus").frame(maxWidth: .infinity).frame(height: 76) }.accessibilityLabel("提高音量")
                    }.font(.title3.weight(.medium)).background(.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 24))
                }
                HStack(spacing: 20) {
                    Button { input = true } label: { Label("键盘", systemImage: "keyboard").frame(maxWidth: .infinity).frame(minHeight: 48) }
                    Button { remote.press(164) } label: { Label("静音", systemImage: "speaker.slash").frame(maxWidth: .infinity).frame(minHeight: 48) }
                }.font(.subheadline).foregroundStyle(.secondary)
                if remote.online == true { Text("当前应用 · \(remote.foreground)").font(.caption).foregroundStyle(.secondary) }

            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24).frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
    }
    private var touchArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34).fill(.primary.opacity(0.055))
                .overlay(RoundedRectangle(cornerRadius: 34).stroke(.primary.opacity(0.08), lineWidth: 1))
            if directions {
                GeometryReader { geometry in
                    let size = min(geometry.size.width, geometry.size.height)
                    let keySize = size * 0.27
                    ZStack {
                        Circle().stroke(.primary.opacity(0.05), lineWidth: 1).padding(size * 0.08)
                        directionButton("chevron.up", "向上", 19, size: keySize).offset(y: -size * 0.31)
                        directionButton("chevron.down", "向下", 20, size: keySize).offset(y: size * 0.31)
                        directionButton("chevron.left", "向左", 21, size: keySize).offset(x: -size * 0.31)
                        directionButton("chevron.right", "向右", 22, size: keySize).offset(x: size * 0.31)
                        Button { remote.press(23) } label: {
                            Text("OK").font(.headline).frame(width: keySize, height: keySize).background(.primary.opacity(0.12), in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel("确认")
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "chevron.up").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    HStack {
                        Image(systemName: "chevron.left").foregroundStyle(.tertiary)
                        Spacer()
                        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.secondary)
                            .offset(x: max(-30, min(30, drag.width * 0.2)), y: max(-30, min(30, drag.height * 0.2)))
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }.font(.caption.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(28).allowsHitTesting(false)
                VStack { Spacer(); Text("滑动选择 · 轻点确认").font(.caption).foregroundStyle(.secondary).padding(.bottom, 22) }.allowsHitTesting(false)
            }
        }
        .aspectRatio(1.18, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 34))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { if !directions { drag = $0.translation } }
            .onEnded { v in
                guard !directions else { return }
                let x = v.translation.width, y = v.translation.height
                if max(abs(x), abs(y)) < 15 { remote.press(23) }
                else { remote.press(abs(x) > abs(y) ? (x > 0 ? 22 : 21) : (y > 0 ? 20 : 19)) }
                drag = .zero
            }, including: directions ? .subviews : .all)
        .accessibilityElement(children: directions ? .contain : .ignore)
        .accessibilityLabel(directions ? "方向控制区" : "触控板")
        .accessibilityHint("也可以切换为方向键操作")
        .accessibilityAction(named: "确认") { remote.press(23) }
        .accessibilityAction(named: "向上") { remote.press(19) }
        .accessibilityAction(named: "向下") { remote.press(20) }
        .accessibilityAction(named: "向左") { remote.press(21) }
        .accessibilityAction(named: "向右") { remote.press(22) }
    }
    private func directionButton(_ symbol: String, _ label: String, _ key: Int, size: CGFloat) -> some View {
        Button { remote.press(key) } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: max(44, size), height: max(44, size))
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private var favoritesRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<4, id: \.self) { slot in
                let id = remote.favorites[slot]
                let app = ProjectorApp(id: id)
                Button {
                    if editingFavorites || id.isEmpty { favoriteSlot = slot }
                    else { Task { await remote.openApp(app) } }
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: favoriteSymbol(id)).font(.title3).frame(height: 48).frame(maxWidth: .infinity)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(alignment: .topTrailing) {
                                if editingFavorites { Image(systemName: "pencil.circle.fill").font(.body).symbolRenderingMode(.palette).foregroundStyle(.white, .blue).padding(4) }
                            }
                        Text(id.isEmpty ? "添加应用" : app.name).font(.caption2).lineLimit(2).frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(editingFavorites || id.isEmpty ? "选择第\(slot + 1)个常用应用" : "打开\(app.name)")
                    .contextMenu {
                        Button("更换应用", systemImage: "arrow.triangle.2.circlepath") { favoriteSlot = slot }
                        Button("移除快捷入口", systemImage: "minus.circle") { remote.setFavorite(nil, slot: slot) }
                    }
            }
        }.accessibilityHint("长按入口可更换应用")
    }
    private func favoriteSymbol(_ id: String) -> String {
        if id.isEmpty { return "plus" }
        if id.contains("music") { return "music.note" }
        if id.contains("browser") { return "globe" }
        if id.contains("tv") || id.contains("emby") { return "play.rectangle" }
        return "app"
    }
    private func control(_ symbol: String, _ label: String, _ key: Int, height: CGFloat = 58) -> some View {
        Button { remote.press(key) } label: { Image(systemName: symbol).font(.title3.weight(.medium)).frame(maxWidth: .infinity).frame(minWidth: 44, minHeight: height) }
            .buttonStyle(RemoteButtonStyle()).accessibilityLabel(label)
    }
    private func showWakeStatus(_ text: String, temporary: Bool) {
        wakeStatusTask?.cancel()
        wakeStatus = text
        if temporary {
            wakeStatusTask = Task {
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                wakeStatus = nil
            }
        }
    }
    private func wake() {
        remote.record("请求蓝牙开机")
        showWakeStatus("准备蓝牙开机…", temporary: false)
        beacon.requestWake()
        wakeCheckTask?.cancel()
        wakeCheckTask = Task {
            // ADB can appear well after the light turns on; poll without claiming BLE delivery.
            for _ in 0..<8 {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                await remote.refresh()
                if remote.online == true {
                    remote.record("开机检测 · 投影仪已联网（不代表信号来源已确认）")
                    showWakeStatus("投影仪已联网", temporary: true)
                    return
                }
            }
        }
    }

    private var appsPage: some View {
        List {
            Section {
                Button { importFile = true } label: { Label("从文件安装 APK", systemImage: "square.and.arrow.down") }.disabled(remote.operation != nil)
                if let operation = remote.operation {
                    VStack(alignment: .leading, spacing: 8) { Text(operation); ProgressView(value: remote.uploadProgress) }.font(.callout)
                    if operation == "正在上传 APK" { Button("取消上传", role: .cancel) { installTask?.cancel() } }
                }
            } footer: { Text("只列出第三方应用。APK 直接从手机传到投影仪，不经过云端。") }
            Section("已安装 · \(remote.apps.count)") {
                if remote.appsLoading { ProgressView("正在读取应用…") }
                else if remote.apps.isEmpty { ContentUnavailableView("还没有应用列表", systemImage: "square.grid.2x2", description: Text("请确保投影仪在线，然后下拉刷新。")) }
                ForEach(remote.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { app in
                    HStack(spacing: 12) {
                        Image(systemName: "app.fill").font(.title2).foregroundStyle(.secondary).frame(width: 44, height: 44).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) { Text(app.name).font(.body.weight(.medium)); Text(app.id).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        Spacer()
                        Menu {
                            Button("打开", systemImage: "play") { Task { await remote.openApp(app) } }
                            Menu("设为首页快捷应用", systemImage: "star") {
                                ForEach(0..<4, id: \.self) { slot in
                                    Button("位置 \(slot + 1) · \(remote.favorites[slot].isEmpty ? "空位" : ProjectorApp(id: remote.favorites[slot]).name)") {
                                        remote.setFavorite(app, slot: slot)
                                    }
                                }
                            }
                            Button("停止", systemImage: "stop") { stopping = app }
                            Button("卸载", systemImage: "trash", role: .destructive) { uninstall = app }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("\(app.name)的操作").disabled(remote.operation != nil)
                    }.padding(.vertical, 3)
                }
            }
        }.navigationTitle("应用").searchable(text: $search, prompt: "应用名称或包名")
            .refreshable { await remote.loadApps() }.task { if remote.apps.isEmpty { await remote.loadApps() } }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await remote.loadApps() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新应用") } }
    }
    private var devicePage: some View {
        List {
            Section {
                LabeledContent("连接状态", value: remote.online == true ? "已连接" : "未连接")
                LabeledContent("IP 地址", value: remote.host)
                LabeledContent("运行状态", value: remote.online == true ? remote.powerState : "不可读取")
                LabeledContent("当前应用", value: remote.foreground)
                if let date = remote.updatedAt { LabeledContent("最近更新") { Text(date, style: .time) } }
            } footer: { if remote.online != true && remote.updatedAt != nil { Text("以下为最近一次读取的数据；连接失败不代表投影仪已关机。") } }
            Section {
                metric("可用内存", detail: "\(remote.bytes("memAvailable")) / \(remote.bytes("memTotal"))", fraction: remote.number("memTotal") > 0 ? remote.number("memAvailable") / remote.number("memTotal") : 0)
                metric("存储已用", detail: "\(remote.bytes("diskUsed")) / \(remote.bytes("diskTotal"))", fraction: remote.number("diskTotal") > 0 ? remote.number("diskUsed") / remote.number("diskTotal") : 0)
                LabeledContent("运行时间", value: remote.uptime)
                LabeledContent("1 分钟系统负载", value: remote.values["load"]?.split(separator: " ").first.map(String.init) ?? "—")
                Button { Task { await remote.cleanResources() } } label: {
                    if remote.operation == "正在清理资源" { ProgressView("正在清理…") }
                    else { Label("一键清理", systemImage: "sparkles") }
                }.disabled(remote.online != true || remote.operation != nil || remote.recording || remote.recordingBusy)
            } header: { Text("资源") } footer: { Text("清理可回收缓存与后台缓存进程，目标腾出 2 GiB 空间；实际释放量由系统决定。不会清除账号、下载文件或应用数据。") }
            Section("系统") {
                LabeledContent("型号", value: "Z6X 第五代")
                LabeledContent("Android", value: remote.values["android"] ?? "—")
                LabeledContent("固件", value: remote.values["build"] ?? "—")
                LabeledContent("安全补丁", value: remote.values["patch"] ?? "—")
                LabeledContent("输出分辨率", value: remote.values["resolution"] ?? "—")
            }
            Section {
                if let image = remote.screenImage { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("手动获取的投影仪屏幕快照") }
                Button { Task { await remote.takeScreenshot() } } label: {
                    if remote.screenshotLoading { ProgressView("正在获取画面…") } else { Label("获取当前画面", systemImage: "viewfinder") }
                }.disabled(remote.screenshotLoading || remote.online != true || remote.recordingBusy)
                if remote.screenImage != nil {
                    Button { Task { await remote.saveScreenshot() } } label: { Label("保存画面至相册", systemImage: "square.and.arrow.down") }
                }
            } header: { Text("屏幕预览") } footer: { Text("手动快照。受保护的播放内容可能显示为黑屏。") }
            Section {
                if remote.recording, let started = remote.recordingStarted {
                    HStack { Label("正在录制", systemImage: "record.circle").foregroundStyle(.red); Spacer(); Text(started, style: .timer).monospacedDigit() }
                }
                Button { Task { if remote.recording { await remote.finishRecording() } else { await remote.startRecording() } } } label: {
                    if remote.recordingBusy { ProgressView("正在处理录屏…") }
                    else { Label(remote.recording ? "结束并下载录屏" : "开始录屏", systemImage: remote.recording ? "stop.circle" : "record.circle") }
                }.disabled(remote.recordingBusy || (!remote.recording && (remote.online != true || remote.operation != nil)))
                if let url = remote.savedVideo {
                    VideoPlayer(player: AVPlayer(url: url)).frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 12))
                    Button { Task { await remote.saveVideoToPhotos() } } label: { Label("保存录屏至相册", systemImage: "photo.badge.arrow.down") }
                    ShareLink(item: url) { Label("分享 / 保存到文件", systemImage: "square.and.arrow.up") }
                }
            } header: { Text("屏幕录制") } footer: { Text("720p，无声音，最长 60 秒后自动结束并下载。请保持 App 在前台；离开后可返回继续下载。受保护内容可能无法录制。") }
            Section {
                Button { showLogs = true } label: { Label("操作日志", systemImage: "clock.arrow.circlepath") }
                Button("连接设置") { settings = true }
            }
        }.navigationTitle("设备").refreshable { await remote.refresh() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await remote.refresh() } } label: { if remote.refreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") } }.accessibilityLabel("刷新状态") } }
    }
    private func metric(_ title: String, detail: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title); Spacer(); Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            ProgressView(value: max(0, min(1, fraction))).tint(.blue)
        }.padding(.vertical, 6)
    }
}

private struct ConnectionSettings: View {
    @ObservedObject var remote: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var bluetoothMAC = ""
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IPv4 地址", text: $address).keyboardType(.decimalPad).autocorrectionDisabled()
                    if !error.isEmpty { Text(error).foregroundStyle(.red) }
                } header: { Text("投影仪地址") } footer: { Text("手机与投影仪连接同一个局域网。开机用蓝牙，在线遥控、应用和状态用 Wi-Fi。") }
                Section {
                    TextField("蓝牙 MAC，例如 02:11:22:33:44:55", text: $bluetoothMAC)
                        .keyboardType(.asciiCapable).textInputAutocapitalization(.characters).autocorrectionDisabled()
                } header: { Text("蓝牙开机地址") } footer: { Text("填写投影仪的蓝牙 MAC，不是 Wi-Fi MAC。可从投影仪系统设备信息中查询；此唤醒格式只在当前 Z6X 第五代验证。") }
                Section("连接方式") {
                    Label("Z6X 第五代关键开机流程已验证", systemImage: "checkmark.circle")
                    Text("请保持 App 在前台，靠近投影仪。局域网控制使用这台设备已开启的调试接口。")
                    Text("如果系统询问本地网络访问，请允许。可在 iPhone 设置中管理蓝牙和本地网络权限。")
                }.font(.callout)
            }.navigationTitle("连接设置").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do {
                            let normalized = try BeaconConfiguration.normalize(bluetoothMAC)
                            guard !BeaconSender.shared.busy else { throw RemoteError.message("请等待开机信号发送结束后再更改设备") }
                            try remote.saveHost(address)
                            try BeaconConfiguration.save(normalized)
                            remote.record("已更新设备连接配置")
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    } }
                }.onAppear { address = remote.host; bluetoothMAC = BeaconConfiguration.currentMAC }
        }.presentationDetents([.medium, .large])
    }
}

private struct FavoritePicker: View {
    @ObservedObject var remote: RemoteModel
    var select: (ProjectorApp?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("清空这个快捷位", systemImage: "minus.circle") { select(nil) }
                } footer: { Text("选择下方任意应用；回到首页后点击即可打开。") }
                if !remote.appsLoading && remote.apps.isEmpty {
                    ContentUnavailableView("暂未读取到应用", systemImage: "square.grid.2x2", description: Text("请确认投影仪在线，再下拉刷新。"))
                }
                ForEach(remote.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { app in
                    Button { select(app) } label: {
                        VStack(alignment: .leading, spacing: 4) { Text(app.name); Text(app.id).font(.caption).foregroundStyle(.secondary) }.frame(minHeight: 44)
                    }
                }
                if remote.appsLoading { ProgressView("正在读取应用…") }
            }.navigationTitle("选择常用应用").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "搜索应用")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .task { await remote.loadApps() }.refreshable { await remote.loadApps() }
        }
    }
}

private struct OperationLogView: View {
    @ObservedObject var remote: RemoteModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if remote.logs.isEmpty { ContentUnavailableView("暂无操作记录", systemImage: "clock") }
                ForEach(remote.logs) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.message).font(.callout).textSelection(.enabled)
                        Text(entry.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }
            }.navigationTitle("操作日志").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) { Text("仅保存在本机，保留最近 300 条，不记录输入文字内容。").font(.caption).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity).background(.regularMaterial) }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
