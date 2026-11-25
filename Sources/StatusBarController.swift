import AppKit
import ServiceManagement

/// Кружок в строке меню и выпадающее меню с подробностями.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let monitor: Monitor
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let summaryItem = NSMenuItem()
    private var hostItems: [NSMenuItem] = []
    private var pingLength: CGFloat?
    private let showPingItem = NSMenuItem(title: "Показывать пинг в строке меню", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Запускать при входе в систему", action: nil, keyEquivalent: "")

    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    /// Табуляция, чтобы цифры в строках узлов стояли ровной колонкой.
    private lazy var hostColumn: NSParagraphStyle = {
        let font = self.font
        let widest = Config.hosts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 60
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: ceil(widest) + 16)]
        return style
    }()

    /// Цифра пинга рядом с кружком (запоминается между запусками).
    private var showPing: Bool {
        get { UserDefaults.standard.bool(forKey: "showPing") }
        set { UserDefaults.standard.set(newValue, forKey: "showPing") }
    }

    init(monitor: Monitor) {
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.font = .monospacedDigitSystemFont(
            ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        buildMenu()

        monitor.onChange = { [weak self] in self?.render() }
        monitor.start()
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(summaryItem)
        menu.addItem(.separator())
        for _ in Config.hosts {
            let item = NSMenuItem()
            hostItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        showPingItem.target = self
        showPingItem.action = #selector(toggleShowPing)
        menu.addItem(showPingItem)

        loginItem.target = self
        loginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Перерисовать кружок и меню по текущему состоянию монитора.
    private func render() {
        let summary = summaryText()

        if let button = statusItem.button {
            button.image = .dot(monitor.health.color, diameter: 11, canvas: 16)
            if showPing {
                button.imagePosition = .imageLeft
                button.title = " " + pingText()
                statusItem.length = pingModeLength(button)
            } else {
                button.imagePosition = .imageOnly
                button.title = ""
                statusItem.length = NSStatusItem.variableLength
            }
            button.toolTip = summary
            button.setAccessibilityLabel("Интернет: \(summary)")
        }

        summaryItem.attributedTitle = NSAttributedString(
            string: summary,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])

        for (item, stats) in zip(hostItems, monitor.hosts) {
            item.image = .dot(stats.health.color, diameter: 8, canvas: 12)
            item.attributedTitle = NSAttributedString(
                string: "\(stats.host)\t\(stats.details)",
                attributes: [.font: font, .paragraphStyle: hostColumn])
        }

        showPingItem.state = showPing ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func summaryText() -> String {
        switch monitor.health {
        case .good:
            return "Интернет в порядке"
        case .degraded:
            let problems = monitor.problems
            return problems.isEmpty ? "Связь нестабильна" : "Нестабильно: " + problems.joined(separator: ", ")
        case .checking:
            return "Проверяю связь…"
        case .down:
            return monitor.networkAvailable ? "Нет связи: узлы не отвечают" : "Нет подключения к сети"
        }
    }

    /// Цифра рядом с кружком: самый свежий удачный пинг. Всегда ровно три знакоместа —
    /// недостающие добиваются «цифровым пробелом» (U+2007), он той же ширины, что и цифра.
    private func pingText() -> String {
        var text = "–"
        if monitor.health != .down, let ms = monitor.latestPing {
            if ms < 1 {
                text = "<1"
            } else if ms >= 999.5 {
                text = ">1с"
            } else {
                text = "\(Int(ms.rounded()))"
            }
        }
        return text.padding(toLength: 3, withPad: "\u{2007}", startingAt: 0)
    }

    /// Фиксированная ширина значка в режиме с цифрой — под три цифры («999»),
    /// чтобы ни сам значок, ни соседние в строке меню не прыгали. Меряется один раз.
    private func pingModeLength(_ button: NSStatusBarButton) -> CGFloat {
        if let pingLength { return pingLength }
        let current = button.title
        button.title = " 999"
        let width = ceil(button.cell?.cellSize.width ?? 60) + 2
        button.title = current
        pingLength = width
        return width
    }

    @objc private func toggleShowPing() {
        showPing.toggle()
        render()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не получилось изменить автозапуск"
            alert.informativeText = "\(error.localizedDescription)\n\n"
                + "Можно добавить вручную: Системные настройки → Основные → Объекты входа."
            if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            alert.runModal()
        }
    }
}

extension Health {
    var color: NSColor {
        switch self {
        case .good:     return .systemGreen
        case .degraded: return .systemYellow
        case .checking: return .systemGray
        case .down:     return .systemRed
        }
    }
}

extension NSImage {
    /// Цветной кружок. Рисуется векторно — чёткий на Retina, цвета подстраиваются под тему.
    static func dot(_ color: NSColor, diameter: CGFloat, canvas: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
            let inset = (rect.width - diameter) / 2
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()   // тонкий контур: жёлтый видно и на светлой панели
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
