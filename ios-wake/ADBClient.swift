import Foundation
import Network

enum RemoteError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

extension Data {
    mutating func le(_ number: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) })
    }
    func word(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << ($1 * 8) }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

// A fresh, bounded connection for each operation. All network work is async.
final class ADBClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "projector.adb.\(UUID().uuidString)")
    private var deadline: DispatchWorkItem?
    private var remote: UInt32 = 0
    private var syncBuffer = Data()

    init(host: String) throws {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil && !$0.isEmpty }) else {
            throw RemoteError.message("请输入投影仪的 IPv4 地址")
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: 5555, using: .tcp)
    }
    func close() { deadline?.cancel(); connection.cancel() }

    private func connect(timeout: Double) async throws {
        let gate = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.take() { continuation.resume() }
                case .failed(let error):
                    if gate.take() { continuation.resume(throwing: error) }
                case .cancelled:
                    if gate.take() { continuation.resume(throwing: RemoteError.message("连接超时，请检查投影仪和同一 Wi-Fi 网络")) }
                default: break
                }
            }
            let work = DispatchWorkItem { [weak self] in self?.connection.cancel() }
            deadline = work
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
    private func read(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let next: Data = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { data, _, _, error in
                    if let error { c.resume(throwing: error) }
                    else if let data, !data.isEmpty { c.resume(returning: data) }
                    else { c.resume(throwing: RemoteError.message("投影仪已断开连接")) }
                }
            }
            result.append(next)
        }
        return result
    }
    private func packet(_ command: String, _ a: UInt32 = 0, _ b: UInt32 = 0, _ body: Data = Data()) async throws {
        let commandData = Data(command.utf8)
        let code = commandData.word(0)
        var data = Data()
        data.le(code); data.le(a); data.le(b); data.le(UInt32(body.count))
        data.le(body.reduce(UInt32(0)) { $0 &+ UInt32($1) }); data.le(code ^ UInt32.max)
        data.append(body)
        try await send(data)
    }
    private func receive() async throws -> (String, UInt32, Data) {
        let h = try await read(24)
        guard h.word(20) == h.word(0) ^ UInt32.max, h.word(12) <= 16 * 1024 * 1024 else {
            throw RemoteError.message("投影仪返回了无效的数据包")
        }
        let body = try await read(Int(h.word(12)))
        guard body.reduce(UInt32(0), { $0 &+ UInt32($1) }) == h.word(16) else {
            throw RemoteError.message("投影仪数据校验失败")
        }
        return (String(decoding: h.prefix(4), as: UTF8.self), h.word(4), body)
    }
    private func open(_ service: String, timeout: Double) async throws {
        try await connect(timeout: timeout)
        try await packet("CNXN", 0x01000000, 4096, Data("host::\0".utf8))
        let hello = try await receive()
        if hello.0 == "AUTH" { throw RemoteError.message("投影仪要求 ADB 授权，此版本仅支持已授权的设备") }
        guard hello.0 == "CNXN" else { throw RemoteError.message("设备未提供支持的遥控接口") }
        try await packet("OPEN", 1, 0, Data((service + "\0").utf8))
        let reply = try await receive()
        guard reply.0 == "OKAY" else { throw RemoteError.message("投影仪未接受此操作") }
        remote = reply.1
    }
    func shell(_ command: String, timeout: Double = 12) async throws -> String {
        defer { close() }
        try await open("shell:" + command, timeout: timeout)
        var output = Data()
        while true {
            let p = try await receive()
            if p.0 == "WRTE" {
                output.append(p.2)
                guard output.count <= 24 * 1024 * 1024 else { throw RemoteError.message("返回内容过大") }
                try await packet("OKAY", 1, p.1)
            } else if p.0 == "CLSE" {
                try? await packet("CLSE", 1, p.1)
                return String(decoding: output, as: UTF8.self)
            } else if p.0 != "OKAY" { throw RemoteError.message("投影仪返回了意外响应") }
        }
    }
    private func syncWrite(_ bytes: Data) async throws {
        var index = 0
        while index < bytes.count {
            let end = min(index + 4096, bytes.count)
            try await packet("WRTE", 1, remote, bytes.subdata(in: index..<end))
            while true {
                let p = try await receive()
                if p.0 == "OKAY" { break }
                if p.0 == "WRTE" { syncBuffer.append(p.2); try await packet("OKAY", 1, p.1) }
                else { throw RemoteError.message("文件传输连接中断") }
            }
            index = end
        }
    }
    private func syncFrame(_ name: String, _ data: Data) async throws {
        var bytes = Data(name.utf8); bytes.le(UInt32(data.count)); bytes.append(data)
        try await syncWrite(bytes)
    }
    func pushAPK(_ file: URL, to path: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        defer { close() }
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        guard bytes.count > 4, bytes.count <= 200 * 1024 * 1024,
              Array(bytes.prefix(4)) == [0x50, 0x4b, 0x03, 0x04] else {
            throw RemoteError.message("请选择 200 MB 以内的标准 APK 文件；不支持 XAPK 或 APK 安装集合")
        }
        try await open("sync:", timeout: max(60, Double(bytes.count) / 100_000 + 30))
        try await syncFrame("SEND", Data((path + ",33188").utf8))
        var index = 0
        while index < bytes.count {
            try Task.checkCancellation()
            let end = min(index + 65536, bytes.count)
            try await syncFrame("DATA", bytes.subdata(in: index..<end))
            index = end
            progress(Double(index) / Double(bytes.count))
        }
        var done = Data("DONE".utf8); done.le(UInt32(Date().timeIntervalSince1970))
        try await syncWrite(done)
        while syncBuffer.count < 8 {
            let p = try await receive()
            guard p.0 == "WRTE" else { throw RemoteError.message("文件传输未确认完成") }
            syncBuffer.append(p.2); try await packet("OKAY", 1, p.1)
        }
        let result = String(decoding: syncBuffer.prefix(4), as: UTF8.self)
        guard result == "OKAY" else { throw RemoteError.message("投影仪拒绝了 APK 文件：\(String(decoding: syncBuffer.dropFirst(8), as: UTF8.self))") }
    }
}
