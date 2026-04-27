import Foundation

struct AttentionQuietHoursWindow: Equatable, Sendable {
    var enabled: Bool
    var startMinutes: Int
    var endMinutes: Int

    nonisolated init(enabled: Bool, startMinutes: Int, endMinutes: Int) {
        self.enabled = enabled
        self.startMinutes = Self.clampedMinuteOfDay(startMinutes)
        self.endMinutes = Self.clampedMinuteOfDay(endMinutes)
    }

    nonisolated func contains(minuteOfDay: Int) -> Bool {
        guard enabled else { return false }
        let minute = Self.clampedMinuteOfDay(minuteOfDay)

        if startMinutes == endMinutes {
            return true
        }

        if startMinutes < endMinutes {
            return minute >= startMinutes && minute < endMinutes
        }

        return minute >= startMinutes || minute < endMinutes
    }

    nonisolated static func clampedMinuteOfDay(_ value: Int) -> Int {
        min(max(value, 0), 23 * 60 + 59)
    }
}

struct AttentionPolicySnapshot: Equatable, Sendable {
    var smartSuppressionEnabled: Bool
    var quietHours: AttentionQuietHoursWindow
    var followFocusEnabled: Bool
    var temporaryMuteUntil: Date?

    nonisolated init(
        smartSuppressionEnabled: Bool,
        quietHours: AttentionQuietHoursWindow,
        followFocusEnabled: Bool,
        temporaryMuteUntil: Date?
    ) {
        self.smartSuppressionEnabled = smartSuppressionEnabled
        self.quietHours = quietHours
        self.followFocusEnabled = followFocusEnabled
        self.temporaryMuteUntil = temporaryMuteUntil
    }
}

enum AttentionPolicy {
    nonisolated static func minuteOfDay(for date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    nonisolated static func suppressesAutomaticPresentation(
        settings: AttentionPolicySnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        terminalVisibleOnCurrentSpace: Bool,
        sessionFocused: Bool
    ) -> Bool {
        if AppSettingsStore.isNotificationMuteActive(until: settings.temporaryMuteUntil, now: now) {
            return true
        }

        if settings.quietHours.contains(minuteOfDay: minuteOfDay(for: now, calendar: calendar)) {
            return true
        }

        if settings.followFocusEnabled && sessionFocused {
            return true
        }

        return settings.smartSuppressionEnabled && terminalVisibleOnCurrentSpace
    }

    nonisolated static func allowsNotificationSound(
        settings: AttentionPolicySnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        allTargetSessionsFocused: Bool
    ) -> Bool {
        if AppSettingsStore.isNotificationMuteActive(until: settings.temporaryMuteUntil, now: now) {
            return false
        }

        if settings.quietHours.contains(minuteOfDay: minuteOfDay(for: now, calendar: calendar)) {
            return false
        }

        if settings.followFocusEnabled && allTargetSessionsFocused {
            return false
        }

        return true
    }
}
