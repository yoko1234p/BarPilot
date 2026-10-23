import Foundation

public enum AutomationCondition: Codable, Equatable {
    case frontApplication(bundleID: String)
    case displayCount(minimum: Int, maximum: Int)
    case batteryBelow(percent: Int, onBatteryOnly: Bool)
    case schedule(startMinute: Int, endMinute: Int, weekdays: [Int])

    public var label: String {
        switch self {
        case .frontApplication(let id): return L10n.text("前景 App：") + id
        case .displayCount(let low, let high):
            return L10n.text("螢幕 %1$@–%2$@ 個", String(describing: low), String(describing: high))
        case .batteryBelow(let percent, let batteryOnly):
            return L10n.text("電池低於 %1$@%", String(describing: percent)) + (batteryOnly ? L10n.text("（電池供電）") : "")
        case .schedule(let start, let end, let weekdays):
            let days = weekdays.filter { (1...7).contains($0) }.map {
                [
                    L10n.text("weekday.sun"), L10n.text("weekday.mon"), L10n.text("weekday.tue"),
                    L10n.text("weekday.wed"), L10n.text("weekday.thu"), L10n.text("weekday.fri"),
                    L10n.text("weekday.sat"),
                ][$0 - 1]
            }.joined(separator: "、")
            return L10n.text("週%1$@ ", String(describing: days))
                + String(format: "%02d:%02d–%02d:%02d", start / 60, start % 60, end / 60, end % 60)
        }
    }

    public func matches(_ context: AutomationContext) -> Bool {
        switch self {
        case .frontApplication(let id): return !id.isEmpty && context.frontApplication == id
        case .displayCount(let low, let high):
            return low > 0 && high >= low && (low...high).contains(context.displayCount)
        case .batteryBelow(let threshold, let batteryOnly):
            guard let percent = context.batteryPercent, (1...100).contains(threshold) else { return false }
            return percent < threshold && (!batteryOnly || context.onBattery)
        case .schedule(let start, let end, let weekdays):
            guard (0..<1440).contains(start), (0..<1440).contains(end), start != end else { return false }
            if start < end { return weekdays.contains(context.weekday) && (start..<end).contains(context.minute) }
            // After midnight belongs to the previous day of a crossing-midnight schedule.
            if context.minute >= start { return weekdays.contains(context.weekday) }
            let previous = context.weekday == 1 ? 7 : context.weekday - 1
            return context.minute < end && weekdays.contains(previous)
        }
    }
}

public struct AutomationContext: Equatable {
    public var frontApplication: String?
    public var displayCount: Int
    public var batteryPercent: Int?
    public var onBattery: Bool
    public var weekday: Int
    public var minute: Int
    public init(
        frontApplication: String?, displayCount: Int, batteryPercent: Int?, onBattery: Bool, date: Date,
        calendar: Calendar = .current
    ) {
        self.frontApplication = frontApplication
        self.displayCount = displayCount
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        weekday = calendar.component(.weekday, from: date)
        minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

public enum ProAction: Codable, Equatable {
    case preset(UUID)
    case showShelf
    case shortcut(name: String)
    case localScript(path: String, arguments: [String])
    public var label: String {
        switch self {
        case .preset: return L10n.text("套用選單列預設")
        case .showShelf: return L10n.text("開啟工作架")
        case .shortcut(let name): return L10n.text("捷徑：") + name
        case .localScript(let path, _): return L10n.text("腳本：") + URL(fileURLWithPath: path).lastPathComponent
        }
    }
}

public struct ProAutomationRule: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var enabled = false
    public var conditions: [AutomationCondition]
    public var action: ProAction
    public var cooldown: TimeInterval = 300
    public init(name: String, conditions: [AutomationCondition], action: ProAction) {
        self.name = name
        self.conditions = conditions
        self.action = action
    }
    public func matches(_ context: AutomationContext) -> Bool {
        enabled && !conditions.isEmpty && conditions.allSatisfy { $0.matches(context) }
    }
}

public struct ProActionWidget: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var symbol: String
    public var action: ProAction
    public init(name: String, symbol: String = "play.circle", action: ProAction) {
        self.name = name
        self.symbol = symbol
        self.action = action
    }
}

public struct QueuedAutomationJob: Equatable {
    public let ruleID: UUID
    public let expectedAction: ProAction
    public let expectedConditions: [AutomationCondition]
    public init(rule: ProAutomationRule) {
        ruleID = rule.id
        expectedAction = rule.action
        expectedConditions = rule.conditions
    }
    /// A slow earlier command must not let a stale trigger execute after its rule or context changes.
    public func isEligible(rules: [ProAutomationRule], context: AutomationContext) -> Bool {
        guard let rule = rules.first(where: { $0.id == ruleID }),
            rule.action == expectedAction, rule.conditions == expectedConditions
        else { return false }
        return rule.matches(context)
    }
}

public struct AutomationGate {
    private var previous: [UUID: Bool] = [:]
    private var firedAt: [UUID: Date] = [:]
    public init() {}
    public mutating func actions(rules: [ProAutomationRule], context: AutomationContext, now: Date) -> [(
        UUID, ProAction
    )] {
        var actions: [(UUID, ProAction)] = []
        let currentIDs = Set(rules.map(\.id))
        previous = previous.filter { currentIDs.contains($0.key) }
        firedAt = firedAt.filter { currentIDs.contains($0.key) }
        for rule in rules {
            let matches = rule.matches(context)
            let rising = matches && previous[rule.id] != true
            let cooldownPassed = firedAt[rule.id].map { now.timeIntervalSince($0) >= max(1, rule.cooldown) } ?? true
            previous[rule.id] = matches
            if rising && cooldownPassed {
                actions.append((rule.id, rule.action))
                firedAt[rule.id] = now
            }
        }
        return actions
    }
    public mutating func reset() {
        previous.removeAll()
        firedAt.removeAll()
    }
}
