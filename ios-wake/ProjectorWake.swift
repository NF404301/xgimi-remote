import SwiftUI
import CoreBluetooth
import CoreLocation
import AppIntents
import UIKit

// iPhone only. These fields reproduce the iBeacon observed during the
// successful official-app wake. The user confirmed this iPhone app also wakes it.
final class BeaconSender: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    static let shared = BeaconSender()
    private var requestedBeaconID: UUID?
    @Published private(set) var status = "等待发送"
    @Published private(set) var busy = false
    private var peripheral: CBPeripheralManager?
    private var requested = false
    private var active: Bool { UIApplication.shared.applicationState == .active }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    @objc private func didBecomeActive() { startIfReady() }
    @objc private func didEnterBackground() {
        if busy { stop(message: "开机广播已暂停，请回到 App 重试") }
    }
    private var timeout: Timer?

    func requestWake() {
        stop()
        do { requestedBeaconID = try BeaconConfiguration.uuid(for: BeaconConfiguration.currentMAC) }
        catch { status = error.localizedDescription; return }
        requested = true
        busy = true
        status = "等待蓝牙就绪，请保持 App 在前台"
        // Start each explicit retry with a fresh manager; preserve the verified iBeacon fields.
        peripheral?.delegate = nil
        peripheral = CBPeripheralManager(delegate: self, queue: .main)
        // Also bound the time spent waiting for permission or a callback.
        timeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            self?.stop(message: "请求超时；请检查蓝牙权限并重试")
        }
        startIfReady()
    }

    func setActive(_ value: Bool) {
        // Read UIKit's actual state instead of trusting a potentially stale SwiftUI phase.
        if active { startIfReady() }
        else if UIApplication.shared.applicationState == .background { didEnterBackground() }
    }

    private func startIfReady() {
        guard requested, active, let peripheral else { return }
        switch peripheral.state {
        case .poweredOn:
            requested = false
            guard let beaconID = requestedBeaconID else { stop(message: "请先配置投影仪蓝牙地址"); return }
            let region = CLBeaconRegion(uuid: beaconID, major: 0, minor: 0,
                                        identifier: "projector-wake")
            let data = region.peripheralData(withMeasuredPower: NSNumber(value: 0))
            guard let advertisement = data as? [String: Any], !advertisement.isEmpty else {
                stop(message: "系统没有生成 iBeacon 广播数据")
                return
            }
            status = "正在请求发送开机广播…"
            peripheral.startAdvertising(advertisement)
        case .poweredOff: stop(message: "请开启 iPhone 蓝牙后重试")
        case .unauthorized: stop(message: "请在设置中允许此 App 使用蓝牙后重试")
        case .unsupported: stop(message: "此设备不支持所需蓝牙广播")
        case .unknown, .resetting: break
        @unknown default: stop(message: "未知蓝牙状态，请重试")
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === self.peripheral else { return }
        if peripheral.state != .poweredOn && peripheral.isAdvertising {
            stop(message: "蓝牙状态已变化，广播停止")
        }
        startIfReady()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === self.peripheral, busy else { peripheral.stopAdvertising(); return }
        if let error { stop(message: "广播失败：\(error.localizedDescription)"); return }
        guard active else { stop(message: "请保持 App 在前台后重试"); return }
        status = "正在发送开机信号 · 请靠近投影仪"
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            self?.stop(message: "信号发送完毕 · 请确认是否开机")
        }
    }

    func stop(message: String = "已停止") {
        timeout?.invalidate()
        timeout = nil
        requested = false
        peripheral?.stopAdvertising()
        busy = false
        status = message
    }
}

struct WakeProjectorIntent: AppIntent {
    static var title: LocalizedStringResource = "打开投影仪"
    static var description = IntentDescription("打开蓝牙发送页面，向 Z6X 第五代发送 20 秒开机广播。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        BeaconSender.shared.requestWake()
        return .result()
    }
}

struct ProjectorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WakeProjectorIntent(),
                    phrases: ["使用\(.applicationName)打开投影仪"],
                    shortTitle: "打开投影仪", systemImageName: "power")
        AppShortcut(intent: StandbyProjectorIntent(),
                    phrases: ["使用\(.applicationName)让投影仪待机"],
                    shortTitle: "投影仪待机", systemImageName: "moon")
    }
}

struct StandbyProjectorIntent: AppIntent {
    static var title: LocalizedStringResource = "投影仪待机"
    static var description = IntentDescription("通过局域网让投影仪待机，会中断当前播放。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = RemoteModel()
        try await model.sendStandby()
        model.record("快捷指令 · 待机指令已发送")
        return .result(dialog: "待机指令已发送")
    }
}

@main
struct ProjectorWakeApp: App {
    @StateObject private var sender = BeaconSender.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RemoteRootView(beacon: sender)
                .onAppear { sender.setActive(scenePhase == .active) }
                .onChange(of: scenePhase) { _, phase in sender.setActive(phase == .active) }
        }
    }
}
