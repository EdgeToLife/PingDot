import AppKit
import Network

/// Состояние связи. Порядок важен: чем меньше значение, тем лучше.
enum Health: Int, Comparable {
    case good       // 🟢
    case degraded   // 🟡
    case checking   // ⚪ данных пока нет
    case down       // 🔴

    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
}

/// Статистика одного узла за последние Config.window пингов.
struct HostStats {
    let host: String
    let samples: [Double?]      // время ответа, мс; nil — пакет потерян
    let lastError: String?

    var lost: Int { samples.filter { $0 == nil }.count }
    var loss: Double { samples.isEmpty ? 0 : Double(lost) / Double(samples.count) }
    var last: Double? { samples.last ?? nil }
    var consecutiveFailures: Int { samples.reversed().prefix(while: { $0 == nil }).count }

    var median: Double? {
        let v = samples.compactMap { $0 }.sorted()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    /// Средний скачок между соседними удачными пингами.
    var jitter: Double? {
        let v = samples.compactMap { $0 }
        guard v.count >= 2 else { return nil }
        return zip(v, v.dropFirst()).map { abs($1 - $0) }.reduce(0, +) / Double(v.count - 1)
    }

    /// Состояние только этого узла (кружки у строк в меню).
    var health: Health {
        if consecutiveFailures >= Config.downAfter { return .down }
        if median == nil { return .checking }   // ещё не было ни одного ответа
        let problems = findProblems(lastLost: consecutiveFailures > 0, loss: loss, latency: median, jitter: jitter)
        return problems.isEmpty ? .good : .degraded
    }

    /// Строка для меню: «23 мс · медиана 22 мс · джиттер 2 мс · потери 0%».
    var details: String {
        guard !samples.isEmpty else { return "…" }
        var parts: [String] = []
        if let ms = last {
            parts.append(formatMs(ms))
        } else {
            parts.append(lastError.map { "ошибка: \($0)" } ?? "нет ответа")
        }
        if let m = median { parts.append("медиана \(formatMs(m))") }
        if let j = jitter { parts.append("джиттер \(formatMs(j))") }
        parts.append("потери \(formatPercent(loss))")
        return parts.joined(separator: " · ")
    }
}

/// Пороги жёлтого — одни и те же для отдельного узла и для общей оценки.
func findProblems(lastLost: Bool, loss: Double, latency: Double?, jitter: Double?) -> [String] {
    var list: [String] = []
    if lastLost { list.append("последний пинг потерян") }
    if loss >= Config.highLoss { list.append("потери \(formatPercent(loss))") }
    if let latency, latency >= Config.highLatencyMs { list.append("пинг \(formatMs(latency))") }
    if let jitter, jitter >= Config.highJitterMs { list.append("джиттер \(formatMs(jitter))") }
    return list
}

/// Пингует узлы по расписанию, ведёт статистику и решает, какого цвета кружок.
@MainActor
final class Monitor {
    private(set) var hosts: [HostStats] = []
    private(set) var health: Health = .checking
    private(set) var problems: [String] = []
    private(set) var networkAvailable = true
    var onChange: (@MainActor () -> Void)?

    /// Самый свежий удачный пинг среди узлов — для цифры в строке меню.
    var latestPing: Double? { hosts.compactMap(\.last).min() }

    private let pinger = Pinger()
    private let pathMonitor = NWPathMonitor()
    private var pathSignature = ""
    private var samples: [String: [Double?]] = [:]
    private var errors: [String: String] = [:]
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var wakeObserver: (any NSObjectProtocol)?
    private var activity: (any NSObjectProtocol)?

    func start() {
        // Без этого macOS может «усыпить» фоновое приложение (App Nap), и пинги пойдут реже.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Мониторинг интернет-соединения")

        // Сеть пропала, появилась или сменилась (Wi-Fi ↔ кабель, VPN) — реагируем сразу.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status != .unsatisfied
            let signature = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in self?.pathChanged(available: available, signature: signature) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "PingDot.network"))

        // После сна старая статистика не имеет смысла — начинаем заново.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }

        restart()
    }

    /// Сбросить историю и начать опрос заново.
    func restart() {
        generation += 1
        samples.removeAll()
        errors.removeAll()
        publish()

        loop?.cancel()
        let current = generation
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let next = clock.now + .seconds(Config.interval)
                await self?.probeAll(generation: current)
                try? await clock.sleep(until: next)
            }
        }
    }

    private func pathChanged(available: Bool, signature: String) {
        let changed = !pathSignature.isEmpty && signature != pathSignature
        pathSignature = signature
        networkAvailable = available
        if changed { restart() } else { publish() }
    }

    /// Один раунд: пингуем все узлы параллельно и дописываем результаты в историю.
    private func probeAll(generation current: Int) async {
        let pinger = self.pinger
        let hostList = Config.hosts
        let results = await withTaskGroup(of: (Int, PingResult).self, returning: [PingResult].self) { group in
            for (index, host) in hostList.enumerated() {
                group.addTask {
                    let result = await pinger.ping(host, timeout: Config.timeout)
                    return (index, result)
                }
            }
            var ordered = [PingResult](repeating: .timeout, count: hostList.count)
            for await (index, result) in group { ordered[index] = result }
            return ordered
        }
        guard current == generation else { return }   // пока ждали ответы, сеть сменилась

        for (host, result) in zip(hostList, results) {
            var history = samples[host] ?? []
            history.append(result.ms)
            samples[host] = Array(history.suffix(Config.window))
            if case .failure(let message) = result {
                errors[host] = message
            } else {
                errors[host] = nil
            }
        }
        publish()
    }

    private func publish() {
        hosts = Config.hosts.map { HostStats(host: $0, samples: samples[$0] ?? [], lastError: errors[$0]) }
        (health, problems) = assess()
        onChange?()
    }

    /// Итоговый цвет кружка.
    /// 🔴 — нет сети или молчат все узлы; ⚪ — ещё ни одного ответа. Иначе по отвечающим узлам:
    /// потери — суммарно (это потери на твоём канале), пинг и джиттер — по лучшему узлу
    /// (один далёкий или тормозящий сервер не портит картину).
    private func assess() -> (Health, [String]) {
        guard networkAvailable else { return (.down, []) }
        if !hosts.isEmpty && hosts.allSatisfy({ $0.health == .down }) { return (.down, []) }

        let responsive = hosts.filter { $0.health != .down && $0.median != nil }
        guard !responsive.isEmpty else { return (.checking, []) }

        let sent = responsive.reduce(0) { $0 + $1.samples.count }
        let lost = responsive.reduce(0) { $0 + $1.lost }
        let found = findProblems(
            lastLost: responsive.allSatisfy { $0.consecutiveFailures > 0 },
            loss: Double(lost) / Double(sent),
            latency: responsive.compactMap(\.median).min(),
            jitter: responsive.compactMap(\.jitter).min())
        return (found.isEmpty ? .good : .degraded, found)
    }
}

func formatMs(_ ms: Double) -> String { ms < 1 ? "<1 мс" : "\(Int(ms.rounded())) мс" }
func formatPercent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
