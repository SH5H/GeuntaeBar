import Foundation

struct CompanyHoliday: Decodable {
    let name: String
}

struct CompensationEstimate {
    let refreshDays: Int
    let dailyMinutes: Int
    var thresholdMinutes: Int
    var countedMinutes: Int

    init(month: MonthlyReport, days: [DailyRecord], holidays: [String: CompanyHoliday]) {
        refreshDays = days.filter { day in
            day.date >= month.startDate && day.date <= month.endDate &&
                day.isScheduledDayOff &&
                holidays[day.date]?.name.hasSuffix("리프레시 데이") == true
        }.count
        dailyMinutes = month.dailyRequiredMinutes
        thresholdMinutes = month.targetMinutes + refreshDays * dailyMinutes
        // Allowance starts only after required time is filled, so count what fills required time.
        countedMinutes = month.creditedMinutes
    }

    var remainingMinutes: Int { max(0, thresholdMinutes - countedMinutes) }
    var excessMinutes: Int { max(0, countedMinutes - thresholdMinutes) }
}
