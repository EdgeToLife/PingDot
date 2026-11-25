import Foundation

/// Результат одного пинга.
enum PingResult: Sendable, CustomStringConvertible {
    case reply(ms: Double)
    case timeout
    case failure(String)

    /// Время ответа в мс или nil, если ответа нет.
    var ms: Double? {
        if case .reply(let ms) = self { return ms }
        return nil
    }

    var description: String {
        switch self {
        case .reply(let ms):        return formatMs(ms)
        case .timeout:              return "нет ответа"
        case .failure(let message): return "ошибка: \(message)"
        }
    }
}

/// Обычный ICMP Echo (как утилита ping), но без root и sudo:
/// macOS разрешает непривилегированным процессам сокеты SOCK_DGRAM + IPPROTO_ICMP.
final class Pinger: @unchecked Sendable {
    private let identifier = UInt16.random(in: 1...UInt16.max)
    private let lock = NSLock()
    private var sequence: UInt16 = 0

    /// Асинхронная обёртка: блокирующий пинг выполняется на фоновой очереди.
    func ping(_ host: String, timeout: TimeInterval) async -> PingResult {
        let id = identifier
        let seq = nextSequence()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Pinger.probe(host: host, id: id, seq: seq, timeout: timeout))
            }
        }
    }

    private func nextSequence() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }
}

extension Pinger {
    /// Один пинг: отправить Echo Request и ждать свой Echo Reply не дольше timeout.
    static func probe(host: String, id: UInt16, seq: UInt16, timeout: TimeInterval) -> PingResult {
        guard let target = resolveIPv4(host) else { return .failure("не удалось получить адрес \(host)") }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return systemFailure("socket") }
        defer { close(fd) }

        // Echo Request: тип 8, код 0, контрольная сумма, идентификатор, номер + 56 байт данных.
        var packet = [UInt8](repeating: 0, count: 64)
        packet[0] = 8
        packet[4] = UInt8(id >> 8)
        packet[5] = UInt8(id & 0xFF)
        packet[6] = UInt8(seq >> 8)
        packet[7] = UInt8(seq & 0xFF)
        for i in 8..<packet.count { packet[i] = UInt8(truncatingIfNeeded: i) }
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)

        let start = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(fd, bytes.baseAddress, bytes.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return systemFailure("sendto") }

        let deadline = start + UInt64(timeout * 1_000_000_000)
        var buffer = [UInt8](repeating: 0, count: 1500)

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return .timeout }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32((deadline - now + 999_999) / 1_000_000))
            if ready == 0 { return .timeout }
            if ready < 0 {
                if errno == EINTR { continue }
                return systemFailure("poll")
            }

            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        recvfrom(fd, bytes.baseAddress, bytes.count, 0, address, &fromLength)
                    }
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                return systemFailure("recvfrom")
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start

            // Такой сокет получает ВСЕ входящие ICMP (в том числе ответы на чужие пинги),
            // поэтому берём только свой: от нужного адреса, тип Echo Reply, наши id и номер.
            guard from.sin_addr.s_addr == target.sin_addr.s_addr,
                  let offset = icmpOffset(buffer, count: count),
                  buffer[offset] == 0, buffer[offset + 1] == 0,
                  buffer[offset + 4] == packet[4], buffer[offset + 5] == packet[5],
                  buffer[offset + 6] == packet[6], buffer[offset + 7] == packet[7]
            else { continue }

            return .reply(ms: Double(elapsed) / 1_000_000)
        }
    }

    /// На macOS ответ приходит вместе с IPv4-заголовком — находим, где начинается ICMP.
    private static func icmpOffset(_ buf: [UInt8], count: Int) -> Int? {
        var offset = 0
        if count >= 20, buf[0] >> 4 == 4 {
            offset = Int(buf[0] & 0x0F) * 4
            guard offset >= 20, buf[9] == UInt8(IPPROTO_ICMP) else { return nil }
        }
        return count >= offset + 8 ? offset : nil
    }

    /// Контрольная сумма Интернета (RFC 1071).
    private static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// IP-адрес как есть; имя (например "dns.google") — через системный резолвер. Только IPv4.
    private static func resolveIPv4(_ host: String) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        if inet_pton(AF_INET, host, &address.sin_addr) == 1 { return address }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        guard let raw = first.pointee.ai_addr, raw.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        return raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    /// Текст системной ошибки (errno) для последнего вызова.
    private static func systemFailure(_ call: String) -> PingResult {
        let code = errno
        return .failure("\(call): \(String(cString: strerror(code)))")
    }

    /// Консольная проверка без интерфейса: PingDot.app/Contents/MacOS/PingDot --check
    static func selfTest() {
        for seq in 1...3 {
            for host in Config.hosts {
                let result = probe(host: host, id: 0x7070, seq: UInt16(seq), timeout: Config.timeout)
                print("\(host)\t\(result)")
            }
        }
    }
}
