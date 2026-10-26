import AppKit
import SwiftUI

@main
@MainActor
struct CalendarTests {
    static func main() async throws {
        let suite = "calendar-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "clockInRemindersEnabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = ISO8601DateFormatter().date(from: "2026-10-26T13:00:00+09:00")!
        let month = MonthlyReport(workedMinutes: 7200, outsideMinutes: 0, requiredMinutes: 9600,
            vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
            startDate: "2026-10-01", endDate: "2026-10-31", maximumWorkMinutes: 12000)
        let current = DailyRecord(date: "2026-10-26", start: "2026-10-26T09:00:00+09:00",
            scheduledEnd: "2026-10-26T18:00:00+09:00", currentMinutes: 240,
            holidayStatus: "WEEKDAY_WORKING_ON_NONE_NONE")
        var raw = AttendanceSnapshot(record: current, month: month, remainingWorkDays: 5, updatedAt: now)
        raw.accountIdentifier = "account-A"
        raw.timeZone = TimeZone(identifier: "Asia/Seoul")!
        raw.calendarRecords = [current] + ["2026-10-14", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"].map {
            DailyRecord(date: $0, scheduledEnd: $0 + "T18:00:00+09:00", holidayStatus: "WEEKDAY_WORKING_ON_NONE_NONE")
        }
        raw.calendarRequiredMinutes = Dictionary(uniqueKeysWithValues: raw.calendarRecords.map { ($0.date, 480) })
        raw.compensationEstimate = CompensationEstimate(month: month, days: raw.calendarRecords, holidays: [:])
        var loaded = raw
        let backend = WantedSpaceBackend(vault: KeychainSession(service: suite),
            snapshotLoader: { _ in loaded }, sessionSaver: { _ in })
        let model = WorkBarModel(wantedSpace: backend, defaults: defaults)
        let refreshed = await model.refresh()
        precondition(refreshed)
        model.setLeave(.paid, on: "2026-10-28")
        precondition(model.snapshot?.month.targetMinutes == 9120)
        precondition(model.snapshot?.compensationEstimate?.thresholdMinutes == 9120)
        precondition(model.snapshot?.remainingWorkDaysAfterToday == 3)
        model.setLeave(.unpaid, on: "2026-10-28")
        precondition(model.snapshot?.month.targetMinutes == 9120)
        precondition(model.snapshot?.compensationEstimate?.thresholdMinutes == 9600)
        precondition(model.snapshot?.month.maximumWorkMinutes == 11520)
        _ = await model.refresh()
        precondition(model.snapshot?.month.targetMinutes == 9120, "Reload must not deduct the same leave twice")

        let reopened = WorkBarModel(wantedSpace: backend, defaults: defaults)
        _ = await reopened.refresh()
        precondition(reopened.snapshot?.leaveByDate["2026-10-28"] == .unpaid)
        precondition(reopened.snapshot?.month.targetMinutes == 9120)
        loaded.accountIdentifier = "account-B"
        _ = await reopened.refresh()
        precondition(reopened.snapshot?.month.targetMinutes == 9600 && reopened.snapshot?.leaveByDate.isEmpty == true)
        loaded = raw
        _ = await reopened.refresh()
        precondition(reopened.snapshot?.leaveByDate["2026-10-28"] == .unpaid)
        reopened.setLeave(nil, on: "2026-10-28")
        precondition(reopened.snapshot?.month.targetMinutes == 9600 && reopened.snapshot?.remainingWorkDaysAfterToday == 4)
        precondition(reopened.snapshot?.compensationEstimate?.thresholdMinutes == 9600)
        reopened.setLeave(.paid, on: "2026-11-01")
        precondition(reopened.snapshot?.month.targetMinutes == 9600)

        let preferences = Preferences(defaults: defaults)
        preferences.setLeaveByDate(["2026-10-28": .paid], for: raw)
        var flex = raw
        flex.service = .flex
        precondition(preferences.leaveByDate(for: flex).isEmpty, "A different attendance service must not inherit leave")
        defaults.set(Data(#"{"weekday":4,"ordinals":[2,4],"affectsCompensation":false}"#.utf8), forKey: "customHolidayRule")
        let migrated = preferences.leaveByDate(for: flex)
        let migratedSnapshot = flex.applyingLeave(migrated)
        precondition(migratedSnapshot.month.targetMinutes == 8640)
        precondition(migratedSnapshot.compensationEstimate?.thresholdMinutes == 9600)
        preferences.setLeaveByDate([:], for: flex)
        precondition(preferences.leaveByDate(for: flex).isEmpty, "Legacy recurring leave must not reappear after removal")

        // Long holiday names, empty records and leave controls must not resize the popover.
        func size() -> CGSize {
            NSHostingView(rootView: WorkMenu(model: reopened)).fittingSize
        }
        _ = await reopened.refresh()
        let originalSize = size()
        reopened.setLeave(.paid, on: current.date)
        precondition(reopened.snapshot?.minimumTodayMeter == nil, "A leave day must not retain a minimum work target")
        precondition(size() == originalSize)
        loaded.calendarHolidays[current.date] = CompanyHoliday(name: String(repeating: "긴 휴일 이름 ", count: 20))
        _ = await reopened.refresh()
        precondition(size() == originalSize)
        loaded.record = nil
        _ = await reopened.refresh()
        precondition(size() == originalSize)
        print("Calendar leave persistence, account isolation, undo and stable layout checks passed")
    }
}
