import Foundation

@main
struct CompensationTests {
    static func main() throws {
        let month = try JSONDecoder().decode(MonthlyReport.self, from: Data(#"{"wk_time_week":8244,"wk_out_min":420,"wk_time_recom":8160,"wk_vac_min":240,"wk_weekend_min":0,"cont_work_day":480,"start_date":"2026-09-01","end_date":"2026-09-30"}"#.utf8))
        let days = try JSONDecoder().decode([DailyRecord].self, from: Data(#"[{"wk_date":"2026-09-02","wk_holiday":"HOLIDAY_WORKING_OFF_NONE_NONE"},{"wk_date":"2026-09-16","wk_holiday":"HOLIDAY_WORKING_OFF_NONE_NONE"},{"wk_date":"2026-09-24","wk_holiday":"HOLIDAY_WORKING_OFF_NONE_NONE"},{"wk_date":"2026-09-25","wk_holiday":"HOLIDAY_WORKING_OFF_NONE_NONE"},{"wk_date":"2026-09-30","wk_holiday":"HOLIDAY_WORKING_OFF_NONE_NONE"}]"#.utf8))
        let holidays = try JSONDecoder().decode([String: CompanyHoliday].self, from: Data(#"{"2026-09-02":{"name":"사내 리프레시 데이","type":"VACATION"},"2026-09-16":{"name":"리프레시 데이","type":"VACATION"},"2026-09-24":{"name":"공휴일","type":"VACATION"},"2026-09-25":{"name":"공휴일","type":"VACATION"},"2026-09-30":{"name":"사내 리프레시 데이","type":"VACATION"}}"#.utf8))
        let estimate = CompensationEstimate(month: month, days: days, holidays: holidays)
        precondition(estimate.refreshDays == 3)
        precondition(estimate.thresholdMinutes == 9360)
        precondition(estimate.countedMinutes == 8664)
        precondition(estimate.remainingMinutes == 696)
        precondition(estimate.excessMinutes == 0)
        let overMonth = MonthlyReport(workedMinutes: 9560, outsideMinutes: 0,
                                      requiredMinutes: 8160, vacationMinutes: 240,
                                      weekendMinutes: 0, dailyRequiredMinutes: 480,
                                      startDate: "2026-09-01", endDate: "2026-09-30",
                                      maximumWorkMinutes: nil)
        let over = CompensationEstimate(month: overMonth, days: days, holidays: holidays)
        precondition(over.remainingMinutes == 0)
        precondition(over.excessMinutes == 200)
        print("Compensation checks passed")
    }
}
