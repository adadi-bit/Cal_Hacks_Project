import Foundation

/// Device-runtime deadline: "Power is out" starts a timer per battery device from the profile;
/// when remaining hours drop below route time + 1 h, the app says "Leave now" on every screen.
public struct DeviceTimer: Sendable, Equatable {
    public struct Remaining: Sendable, Equatable {
        public var kind: String
        /// Spoken label used by the staff pre-generation ("Oxygen", "Ventilator").
        public var label: String
        public var hoursLeft: Double
    }

    public static let marginHours = 1.0
    /// CONTRACTS.md `leave_now_dev` device words (CPAP has no battery deadline).
    public static let labels = ["oxygen": "Oxygen", "ventilator": "Ventilator", "power_chair": "Power chair"]

    public var devices: [ClientDevice]
    public var powerOutSince: Date?

    public init(devices: [ClientDevice], powerOutSince: Date? = nil) {
        self.devices = devices
        self.powerOutSince = powerOutSince
    }

    public var isRunning: Bool { powerOutSince != nil }

    /// Battery devices with a known runtime in hours (oxygen, ventilator; a power chair only if hours were given),
    /// most urgent first.
    public func remaining(now: Date = Date()) -> [Remaining] {
        guard let since = powerOutSince else { return [] }
        let elapsedH = max(0, now.timeIntervalSince(since)) / 3600.0
        return devices.compactMap { d in
            guard let label = DeviceTimer.labels[d.kind], let h = d.hours else { return nil }
            return Remaining(kind: d.kind, label: label, hoursLeft: max(0, h - elapsedH))
        }.sorted { $0.hoursLeft < $1.hoursLeft }
    }

    /// The device that triggers "Leave now", if any.
    public func leaveNow(routeTimeS: Double, now: Date = Date()) -> Remaining? {
        let need = routeTimeS / 3600.0 + DeviceTimer.marginHours
        return remaining(now: now).first { $0.hoursLeft < need }
    }

    /// phrases.json "leave_now_dev" ("… has {n} minutes left", n on the staff pre-gen grid), "leave_now_dev_one"
    /// ("… has 1 minute left") and "device_out" ("{device} battery is out. Leave now.") once the runtime is gone:
    /// an expired timer must never keep saying "1 minutes left".
    public static func leaveNowSentence(_ r: Remaining, config: SharedConfig) -> String {
        let m = Int(floor(r.hoursLeft * 60 + 1e-6))   // 2 min left is 2, not 1.9999 -> 1
        // Bundles synced before these templates existed fall back to the same wording.
        let out = config.phrases.templates["device_out"] ?? "{device} battery is out. Leave now."
        let one = config.phrases.templates["leave_now_dev_one"] ?? "Leave now. {device} has 1 minute left."
        if m <= 0 { return SharedConfig.format(out, ["device": r.label]) }
        if m == 1 { return SharedConfig.format(one, ["device": r.label]) }
        let n: Int = m <= 120 ? m : min(500, m / 10 * 10)
        return config.phrase("leave_now_dev", ["device": r.label, "n": String(n)])
    }

    /// The timer belongs to one person on one bundle build. A different card, county or re-synced bundle gives a
    /// different scope and the phone clears the timer instead of carrying it over for ever.
    /// A county-feed outage report may start the timer only while it is not running and only if the user has not
    /// turned "Power is out" off for this same card and bundle (the user's word beats the feed).
    public static func feedMayArm(timerRunning: Bool, userClearedScope: String?, scope: String) -> Bool {
        !timerRunning && userClearedScope != scope
    }

    public static func scope(clientId: String?, county: String?, builtAt: String?) -> String {
        [clientId ?? "", county ?? "", builtAt ?? ""].joined(separator: "|")
    }
}
