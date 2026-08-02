import Foundation

enum SettingsKeys {
    static let notifyWaiting = "notify.waiting"
    static let notifyTurnFinished = "notify.turnFinished"
    static let notifySubagentFinished = "notify.subagentFinished"
    static let listenerPort = "listener.port"
    static let accountUsage = "accountUsage.snapshot"
}

/// Account-level rate-limit state, as reported by the statusline JSON.
/// There is no supported API for these numbers, so they only exist while at
/// least one session is feeding the forwarder — hence the staleness tracking
/// and the persisted snapshot, which survives restarts and idle periods.
struct AccountUsage: Codable, Equatable {
    var fiveHourPercent: Double?
    var fiveHourResetsAt: Date?
    var sevenDayPercent: Double?
    var sevenDayResetsAt: Date?
    var measuredAt: Date

    static let unavailableTooltip = "No usage data yet — available on Pro/Max accounts once the statusline integration is installed."

    /// Values older than this are shown dimmed: the account may well have
    /// burned through more quota in another window since.
    private static let stalenessThreshold: TimeInterval = 30 * 60

    var isStale: Bool {
        Date().timeIntervalSince(measuredAt) > Self.stalenessThreshold
    }

    var fiveHourFraction: Double? { fiveHourPercent.map { $0 / 100 } }
    var sevenDayFraction: Double? { sevenDayPercent.map { $0 / 100 } }

    var fiveHourTooltip: String {
        tooltip(percent: fiveHourPercent, resetsAt: fiveHourResetsAt, window: "5-hour limit")
    }

    var sevenDayTooltip: String {
        tooltip(percent: sevenDayPercent, resetsAt: sevenDayResetsAt, window: "weekly limit")
    }

    private func tooltip(percent: Double?, resetsAt: Date?, window: String) -> String {
        guard let percent else { return Self.unavailableTooltip }
        var text = "\(Int(percent.rounded()))% of your \(window) used"
        if let resetsAt {
            let formatter = DateFormatter()
            // Within a day, the clock time is what matters; beyond that, the day.
            formatter.dateFormat = resetsAt.timeIntervalSinceNow < 24 * 3600 ? "HH:mm" : "EEEE HH:mm"
            text += " · resets \(formatter.string(from: resetsAt))"
        }
        if isStale {
            let minutes = Int(Date().timeIntervalSince(measuredAt) / 60)
            text += minutes < 120
                ? "\n(last seen \(minutes)m ago)"
                : "\n(last seen \(minutes / 60)h ago)"
        }
        return text
    }

    /// Merges a fresh statusline report in. Absent windows keep their previous
    /// value rather than blanking the gauge — API-key users never get either.
    func merging(fiveHour: (percent: Double?, resetsAt: Date?), sevenDay: (percent: Double?, resetsAt: Date?)) -> AccountUsage {
        AccountUsage(
            fiveHourPercent: fiveHour.percent ?? fiveHourPercent,
            fiveHourResetsAt: fiveHour.resetsAt ?? fiveHourResetsAt,
            sevenDayPercent: sevenDay.percent ?? sevenDayPercent,
            sevenDayResetsAt: sevenDay.resetsAt ?? sevenDayResetsAt,
            measuredAt: Date()
        )
    }

    static func load(from defaults: UserDefaults = .standard) -> AccountUsage? {
        guard let data = defaults.data(forKey: SettingsKeys.accountUsage) else { return nil }
        return try? JSONDecoder().decode(AccountUsage.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SettingsKeys.accountUsage)
    }
}
