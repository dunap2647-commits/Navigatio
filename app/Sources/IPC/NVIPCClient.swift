import Foundation
public enum NIPCError: LocalizedError {
case daemonUnreachable
case protocolFailure(String)
public var errorDescription: String? {
switch self {
case .daemonUnreachable: return "Демон Navigatio не отвечает. Проверьте, что он установлен и запущен."
case .protocolFailure(let m): return m
}
}
}
public final class NVIPCClient {
public static let shared = NVIPCClient()
private let queue = DispatchQueue(label: "com.navigatio.ipc.client")
private var nextID: UInt64 = 1
private let socketPath = "/var/run/navigatiod.sock"
private init() {}
public func call(_ method: String,
params: [String: Any] = [:],
completion: @escaping (Result<[String: Any], Error>) -> Void) {
queue.async {
let id = self.nextID
self.nextID += 1
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else {
DispatchQueue.main.async { completion(.failure(NIPCError.daemonUnreachable)) }
return
}
defer { close(fd) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { p in
_ = strcpy(p, self.socketPath)
}
}
addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) {
$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
}
}
guard connected else {
self.deliver(.failure(NIPCError.daemonUnreachable), completion)
return
}
let payload: [String: Any] = ["id": id, "method": method, "params": params]
guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: []),
nipc_send_frame(fd, (encoded as NSData).bytes, encoded.count) == 0 else {
self.deliver(.failure(NIPCError.protocolFailure("Не удалось отправить запрос демону")), completion)
return
        let cap = Int(NIPC_MAX_FRAME) + 1
        
        // Выделяем память
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
        defer { buffer.deallocate() } // Освобождение памяти
        
        var received: size_t = 0
        let recvResult = nipc_recv_frame(fd, buffer, cap, &received)
        
        guard recvResult == 0 else {
            self.deliver(.failure(NIPCError.protocolFailure("Демон закрыл соединение до ответа")), completion)
            return
        }
        
        let data = Data(bytes: buffer, count: received)
guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
self.deliver(.failure(NIPCError.protocolFailure("Некорректный ответ демона")), completion)
return
}
if let ok = obj["ok"] as? Bool, ok {
let result = obj["result"] as? [String: Any] ?? [:]
self.deliver(.success(result), completion)
} else {
let errorDict = obj["error"] as? [String: Any]
let message = errorDict?["message"] as? String ?? "Неизвестная ошибка демона"
self.deliver(.failure(NIPCError.protocolFailure(message)), completion)
}
}
}
private func deliver(_ result: Result<[String: Any], Error>,
_ completion: @escaping (Result<[String: Any], Error>) -> Void) {
DispatchQueue.main.async { completion(result) }
}
}
