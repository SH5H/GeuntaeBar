import AppKit
import SwiftUI
import Vision

@MainActor
@main
struct MenuTests {
    static func main() async throws {
        let suite = "geuntae-menu-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "showCompensationEstimate")
        defaults.set(false, forKey: "clockInRemindersEnabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = ISO8601DateFormatter().date(from: "2026-10-01T13:00:00+09:00")!
        let date = "2026-10-01"
        let start = "2026-10-01T09:00:00+09:00"
        let scheduledEnd = "2026-10-01T18:00:00+09:00"
        let workday = "WEEKDAY_WORKING_ON_NONE_NONE"
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("geuntae-bar-menu-tests")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // One-point solid reference lines turn dashed as each threshold is reached.
        for scheme in [ColorScheme.light, .dark] {
            let colors: [Color] = [.red, .blue, .purple]
            let markers = colors.enumerated().map { (position: Optional(Double($0.offset + 1) / 4),
                                                      color: $0.element, description: "") }
            for fill in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let renderer = ImageRenderer(content: WorkProgressBar(fill: fill, markers: markers, value: "", label: "")
                    .frame(width: 200).environment(\.colorScheme, scheme))
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
                for index in colors.indices {
                    let center = (index + 1) * 100
                    let color = bitmap.colorAt(x: center - 1, y: 0)!
                    precondition(color.alphaComponent == 1)
                    for row in 0..<bitmap.pixelsHigh {
                        let columns = ((center - 3)...(center + 3)).filter {
                            bitmap.colorAt(x: $0, y: row)! == color
                        }
                        let solid = fill < markers[index].position!
                        precondition(columns.count == (solid || row % 8 < 4 ? 2 : 0))
                    }
                }
            }
        }

        // The live segment joins the confirmed segment without a rounded gap.
        let segmentCases: [(String, Double, Double, [Int], [Int], [Int])] = [
            ("mixed", 0.75, 0.5, [40, 199], [200, 250], [350]),
            ("ongoing-only", 0.75, 0, [], [40, 250], [350]),
            ("confirmed-only", 0.75, 0.75, [40, 250], [], [350]),
            ("clamped", 1, 1.25, [40, 350], [], []),
            ("empty", 0, 0, [], [], [40, 250, 350])
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, fill, confirmed, teal, orange, background) in segmentCases {
                let renderer = ImageRenderer(content: WorkProgressBar(fill: fill, markers: [], value: "", label: "",
                    confirmedFill: confirmed).frame(width: 200).environment(\.colorScheme, scheme))
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: renderer.cgImage!)
                func color(_ x: Int) -> NSColor { bitmap.colorAt(x: x, y: 14)!.usingColorSpace(.deviceRGB)! }
                for x in teal {
                    let c = color(x)
                    precondition(c.redComponent < 0.4 && c.greenComponent > 0.5 && c.blueComponent > 0.5 && c.alphaComponent > 0.9)
                }
                for x in orange {
                    let c = color(x)
                    precondition(c.redComponent > 0.9 && c.greenComponent > 0.3 && c.blueComponent < 0.25 && c.alphaComponent > 0.9)
                }
                for x in background { precondition(color(x).alphaComponent < 0.3) }
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: output.appendingPathComponent("segments-\(scheme)-\(name).png"))
            }
        }

        func iconSnapshot(_ meter: WorkMeter?, finished: Bool = false, waiting: Bool = false) -> AttendanceSnapshot? {
            guard let meter else { return nil }
            let record = DailyRecord(date: date, start: waiting ? nil : start,
                                     end: finished ? scheduledEnd : nil, scheduledEnd: scheduledEnd,
                                     workedMinutes: finished ? meter.actualMinutes : nil,
                                     currentMinutes: finished || waiting ? nil : meter.actualMinutes,
                                     holidayStatus: workday)
            let month = MonthlyReport(workedMinutes: record.totalMinutes ?? 0, outsideMinutes: 0,
                                      requiredMinutes: meter.targetMinutes, vacationMinutes: 0,
                                      weekendMinutes: 0, dailyRequiredMinutes: 480,
                                      startDate: date, endDate: "2026-10-31", maximumWorkMinutes: nil)
            return AttendanceSnapshot(record: record, month: month,
                                      remainingWorkDays: finished ? 0 : 1, updatedAt: now)
        }
        func renderIcon(_ snapshot: AttendanceSnapshot?, name: String,
                        appearance: NSAppearance) throws -> NSBitmapImageRep {
            let icon = LaunchLabel.progressImage(snapshot: snapshot)
            precondition(!icon.isTemplate && icon.size.height == 18)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(icon.size.width) * 2,
                pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = icon.size
            appearance.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                icon.draw(in: NSRect(origin: .zero, size: icon.size))
                NSGraphicsContext.restoreGraphicsState()
            }
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent("status-\(appearance.name.rawValue)-\(name).png"))
            return bitmap
        }
        func ringPixel(_ bitmap: NSBitmapImageRep, hours: Int, hour: Int, at fraction: Double,
                       radius: Double) -> NSColor {
            let segment = 360.0 / Double(hours)
            let gap = hours > 1 ? 10.0 : 0
            let angle = (90 - Double(hour) * segment - gap / 2 - (segment - gap) * fraction) * .pi / 180
            return bitmap.colorAt(x: Int(2 * (9 + radius * cos(angle))),
                                  y: Int(36 - 2 * (9 + radius * sin(angle))))!.usingColorSpace(.deviceRGB)!
        }
        func matches(_ pixel: NSColor, _ color: NSColor) -> Bool {
            let expected = color.usingColorSpace(.deviceRGB)!
            return pixel.alphaComponent > 0.9 &&
                abs(pixel.redComponent - expected.redComponent) < 0.08 &&
                abs(pixel.greenComponent - expected.greenComponent) < 0.08 &&
                abs(pixel.blueComponent - expected.blueComponent) < 0.08
        }

        // The ring always has eight slots, including short targets and unknown attendance.
        let empty = Array(repeating: 0.0, count: 8)
        let full = Array(repeating: 1.0, count: 8)
        let iconCases: [(String, WorkMeter?, [Double], [Double], [Double])] = [
            ("no-attendance", nil, empty, empty, empty),
            ("ten-minutes", WorkMeter(actualMinutes: 10, targetMinutes: 480), [1.0 / 6, 0, 0, 0, 0, 0, 0, 0], empty, empty),
            ("half-target", WorkMeter(actualMinutes: 240, targetMinutes: 480), [1, 1, 1, 1, 0, 0, 0, 0], empty, empty),
            ("short-half-target", WorkMeter(actualMinutes: 90, targetMinutes: 180), [1, 1, 1, 1, 0, 0, 0, 0], empty, empty),
            ("short-target", WorkMeter(actualMinutes: 360, targetMinutes: 360), full, empty, empty),
            ("full-target", WorkMeter(actualMinutes: 480, targetMinutes: 480), full, empty, empty),
            ("one-hour-over", WorkMeter(actualMinutes: 540, targetMinutes: 480), [0, 1, 1, 1, 1, 1, 1, 1], [1, 0, 0, 0, 0, 0, 0, 0], empty),
            ("second-lap-complete", WorkMeter(actualMinutes: 960, targetMinutes: 480), empty, full, empty),
            ("red-lap", WorkMeter(actualMinutes: 990, targetMinutes: 480), empty, [0.5, 1, 1, 1, 1, 1, 1, 1], [0.5, 0, 0, 0, 0, 0, 0, 0]),
            ("red-lap-complete", WorkMeter(actualMinutes: 1440, targetMinutes: 480), empty, empty, full),
            ("beyond-three-laps", WorkMeter(actualMinutes: 1500, targetMinutes: 480), empty, empty, full),
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: appearanceName)!
            for (name, meter, green, yellow, red) in iconCases {
                for finished in [false, true] {
                    let bitmap = try renderIcon(iconSnapshot(meter, finished: finished),
                        name: "\(finished ? "ended" : "working")-\(name)", appearance: appearance)
                    precondition(bitmap.pixelsWide == 36)
                    appearance.performAsCurrentDrawingAppearance {
                        for hour in green.indices {
                            let bounds = [red[hour], red[hour] + yellow[hour], red[hour] + yellow[hour] + green[hour]]
                            for p in stride(from: 0.1, through: 0.9, by: 0.2)
                            where bounds.allSatisfy({ abs($0 - p) > 0.06 }) {
                                let expected: NSColor? = p < bounds[0] ? .systemRed
                                    : p < bounds[1] ? .systemYellow : p < bounds[2] ? .systemGreen : nil
                                let pixel = ringPixel(bitmap, hours: green.count, hour: hour, at: p,
                                                      radius: finished ? 7.75 : 6.5)
                                for color in [NSColor.systemGreen, .systemYellow, .systemRed] {
                                    precondition(matches(pixel, color) == (color == expected),
                                                 "Unexpected ring color: \(appearanceName.rawValue) \(name)")
                                }
                                if expected == nil {
                                    precondition(matches(pixel, .white),
                                                 "Unfilled donut must be opaque white: \(appearanceName.rawValue) \(name)")
                                }
                                if finished {
                                    let inner = ringPixel(bitmap, hours: green.count, hour: hour, at: p, radius: 5.5)
                                    precondition(matches(inner, .systemGray) == (p < bounds[2]))
                                }
                            }
                        }
                    }
                }
            }
            let waiting = iconSnapshot(WorkMeter(actualMinutes: 0, targetMinutes: 360), waiting: true)!
            let before = try renderIcon(waiting, name: "before", appearance: appearance)
            let started = try renderIcon(iconSnapshot(WorkMeter(actualMinutes: 0, targetMinutes: 360)),
                                         name: "started-zero", appearance: appearance)
            precondition(before.colorAt(x: 18, y: 18)!.alphaComponent > 0.1)
            precondition(started.colorAt(x: 18, y: 18)!.alphaComponent == 0)
            for hour in 0..<8 {
                precondition(matches(ringPixel(before, hours: 8, hour: hour, at: 0.5, radius: 6.5), .white))
            }
            var unknown = waiting
            unknown.attendanceKnown = false
            let missing = try renderIcon(unknown, name: "unknown-attendance", appearance: appearance)
            precondition(missing.pixelsWide == 36 && missing.colorAt(x: 18, y: 18)!.alphaComponent == 0)
            var offDay = iconSnapshot(WorkMeter(actualMinutes: 150, targetMinutes: 360), finished: true)!
            offDay = AttendanceSnapshot(record: DailyRecord(date: date, start: start, end: scheduledEnd,
                workedMinutes: 150, holidayStatus: "HOLIDAY_WORKING_OFF_NONE_NONE"),
                month: offDay.month, remainingWorkDays: 0, updatedAt: now)
            precondition(offDay.minimumTodayMeter == nil)
            let noTarget = try renderIcon(offDay, name: "ended-no-target", appearance: appearance)
            precondition(noTarget.pixelsWide == 36)
            appearance.performAsCurrentDrawingAppearance {
                precondition(ringPixel(noTarget, hours: 8, hour: 0, at: 0.5, radius: 7.75).alphaComponent > 0.9)
                precondition(matches(ringPixel(noTarget, hours: 8, hour: 2, at: 0.3, radius: 5.5), .systemGray))
                precondition(matches(ringPixel(noTarget, hours: 8, hour: 2, at: 0.8, radius: 5.5), .systemGray))
                for hour in 0..<8 {
                    let pixel = ringPixel(noTarget, hours: 8, hour: hour, at: 0.3, radius: 7.75)
                    precondition(!matches(pixel, .systemYellow) && !matches(pixel, .systemRed))
                }
            }
        }

        func render(_ record: DailyRecord, days: Int = 2, required: Int = 7680, report: MonthlyReport? = nil,
                    compensation: Bool = true, refreshDay: Bool = true,
                    name: String) async throws -> (NSBitmapImageRep, [String]) {
            let month = report ?? MonthlyReport(workedMinutes: 6960 + (record.totalMinutes ?? 0), outsideMinutes: 0,
                                      requiredMinutes: required, vacationMinutes: 0,
                                      weekendMinutes: 0, dailyRequiredMinutes: 480,
                                      startDate: "2026-10-01", endDate: "2026-10-31",
                                      maximumWorkMinutes: 9600)
            var snapshot = AttendanceSnapshot(record: record, month: month,
                                              remainingWorkDays: days, updatedAt: now)
            snapshot.dailyRestMinutes = 60
            if compensation {
                let days = refreshDay ? [DailyRecord(date: month.startDate, holidayStatus: "HOLIDAY_WORKING_OFF_NONE_NONE")] : []
                snapshot.compensationEstimate = CompensationEstimate(month: month, days: days,
                    holidays: [month.startDate: CompanyHoliday(name: "리프레시 데이")])
            }
            let model = WorkBarModel(wantedSpace: WantedSpaceBackend(vault: KeychainSession(service: "workbar-menu-tests-\(UUID().uuidString)"),
                                     snapshotLoader: { _ in snapshot }, sessionSaver: { _ in }), defaults: defaults)
            let refreshed = await model.refresh()
            precondition(refreshed)
            let renderer = ImageRenderer(content: WorkMenu(model: model)
                .environment(\.colorScheme, .light).background(Color.white))
            renderer.scale = 2
            let image = renderer.cgImage!
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent("\(name).png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["ko-KR", "en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let texts = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .map { $0.topCandidates(1).first!.string.filter { !$0.isWhitespace } }
            return (bitmap, texts)
        }

        // Four hours against a six-hour minimum fills 2/3, rather than the fixed eight-hour 1/2.
        let working = DailyRecord(date: date, start: start, scheduledEnd: scheduledEnd,
                                  currentMinutes: 240, holidayStatus: workday)
        let (_, decimalTexts) = try await render(working, required: 7610, name: "daily-required")
        precondition(decimalTexts.joined().contains("6.8시간"), decimalTexts.joined())
        let (_, texts) = try await render(working, name: "working")
        precondition(texts.joined().contains("67%달성"))
        precondition(texts.joined().contains("최소6시간0분"))
        precondition(texts.joined().contains("예상퇴근18:00"))
        precondition(texts.joined().contains("필수시간대비94%"))
        precondition(texts.joined().contains("최대160시간0분"))

        let reached = DailyRecord(date: date, start: start, scheduledEnd: scheduledEnd,
                                  currentMinutes: 480, holidayStatus: workday)
        let (_, reachedTexts) = try await render(reached, name: "reached")
        precondition(reachedTexts.joined().contains("100%달성"))
        let (_, zeroTexts) = try await render(working, required: 6600, name: "zero-target")
        precondition(zeroTexts.joined().contains("이번달필수시간달성"))

        let offDay = DailyRecord(date: date, workedMinutes: 240, holidayStatus: "HOLIDAY_WORKING_OFF_NONE_NONE")
        let (_, offTexts) = try await render(offDay, days: 0, name: "no-workdays")
        precondition(offTexts.joined().contains("남은근무일없음"))

        let before = DailyRecord(date: date, scheduledEnd: scheduledEnd, holidayStatus: workday)
        let (_, beforeTexts) = try await render(before, name: "before-clock-in")
        precondition(beforeTexts.joined().contains("0%달성"))
        let ended = DailyRecord(date: date, start: start, end: "2026-10-01T13:00:00+09:00",
                                scheduledEnd: scheduledEnd, workedMinutes: 240, holidayStatus: workday)
        let (_, endedTexts) = try await render(ended, days: 1, name: "after-clock-out")
        precondition(endedTexts.joined().contains("67%달성") && endedTexts.joined().contains("퇴근13:00"))

        let overnight = DailyRecord(date: "2026-09-30", start: "2026-09-30T15:00:00+09:00",
                                    scheduledEnd: "2026-09-30T18:00:00+09:00",
                                    currentMinutes: 540, holidayStatus: workday)
        let previousMonth = MonthlyReport(workedMinutes: 7740, outsideMinutes: 0,
                                          requiredMinutes: 7920, vacationMinutes: 0,
                                          weekendMinutes: 0, dailyRequiredMinutes: 480,
                                          startDate: "2026-09-01", endDate: "2026-09-30",
                                          maximumWorkMinutes: 9600)
        let (_, overnightTexts) = try await render(overnight, days: 0, report: previousMonth, name: "overnight")
        precondition(overnightTexts.joined().contains("2026-09-30까지기준132시간0분"))
        precondition(overnightTexts.joined().contains("최소12시간0분"))

        // Calendar boundaries must remain correct across leap years, six-row months and time zones.
        func calendarSnapshot(_ first: String, _ last: String, _ instant: String) -> AttendanceSnapshot {
            var value = AttendanceSnapshot(record: nil,
                month: MonthlyReport(workedMinutes: 0, outsideMinutes: 0, requiredMinutes: 9600,
                    vacationMinutes: 0, weekendMinutes: 0, dailyRequiredMinutes: 480,
                    startDate: first, endDate: last, maximumWorkMinutes: nil),
                remainingWorkDays: 10, updatedAt: ISO8601DateFormatter().date(from: instant)!)
            value.timeZone = TimeZone(identifier: "Asia/Seoul")!
            return value
        }
        let leap = AttendanceCalendarMonth(snapshot: calendarSnapshot("2024-02-01", "2024-02-29", "2024-02-15T00:00:00Z"))
        precondition(leap.days.prefix(4).allSatisfy { $0 == nil })
        precondition(leap.days.compactMap { $0 }.map(leap.key).last == "2024-02-29")
        precondition(leap.adjacentMonth(-1) == nil && leap.adjacentMonth(1) == nil)
        let sixRows = AttendanceCalendarMonth(snapshot: calendarSnapshot("2026-08-01", "2026-08-31", "2026-08-01T00:00:00Z"))
        precondition(sixRows.days.count == 42 && sixRows.days[6].map(sixRows.key) == "2026-08-01")
        let crossYear = AttendanceCalendarMonth(snapshot: calendarSnapshot("2026-12-15", "2027-01-14", "2026-12-31T16:00:00Z"))
        precondition(crossYear.key(crossYear.start) == "2027-01-01")
        precondition(crossYear.adjacentMonth(-1).map(crossYear.key) == "2026-12-01")
        precondition(crossYear.adjacentMonth(1) == nil)

        var calendarSnapshot = calendarSnapshot("2026-10-01", "2026-10-31", "2026-10-01T04:00:00Z")
        calendarSnapshot.record = working
        calendarSnapshot.calendarRecords = [
            DailyRecord(date: date, start: start, currentMinutes: 120, holidayStatus: workday),
            DailyRecord(date: "2026-10-02", holidayStatus: "HOLIDAY_WORKING_OFF_NONE_NONE"),
            DailyRecord(date: "2026-10-03", start: "2026-10-03T09:00:00+09:00",
                        end: "2026-10-03T17:00:00+09:00", workedMinutes: 420),
            DailyRecord(date: "2026-10-05", workedMinutes: 0, holidayStatus: workday),
            DailyRecord(date: "2026-10-06", start: "2026-10-06T09:00:00+09:00",
                        end: "2026-10-06T09:00:00+09:00", workedMinutes: 0),
        ]
        calendarSnapshot.calendarHolidays = ["2026-10-02": CompanyHoliday(name: "창립기념일")]
        precondition(CalendarDayDetail(snapshot: calendarSnapshot, key: date).minutes == 240,
                     "The selected current day must use live minutes, not the older monthly row")
        let holiday = CalendarDayDetail(snapshot: calendarSnapshot, key: "2026-10-02")
        precondition(holiday.holiday == "창립기념일" && holiday.minutes == nil)
        let completed = CalendarDayDetail(snapshot: calendarSnapshot, key: "2026-10-03")
        precondition(completed.minutes == 420 && completed.record?.end == "2026-10-03T17:00:00+09:00")
        precondition(CalendarDayDetail(snapshot: calendarSnapshot, key: "2026-10-04").minutes == nil,
                     "Missing records must not become zero-hour attendance")
        precondition(CalendarDayDetail(snapshot: calendarSnapshot, key: "2026-10-05").minutes == nil,
                     "A zero-minute schedule without attendance must not appear as completed work")
        precondition(CalendarDayDetail(snapshot: calendarSnapshot, key: "2026-10-06").minutes == 0,
                     "An actual zero-minute attendance record must remain visible")
        calendarSnapshot.attendanceKnown = false
        precondition(CalendarDayDetail(snapshot: calendarSnapshot, key: date).minutes == nil)

        let guideDefaults = UserDefaults(suiteName: "geuntae-bar-guide-\(UUID().uuidString)")!
        guideDefaults.set(false, forKey: "clockInRemindersEnabled")
        let guideState = OnboardingState(defaults: guideDefaults)
        guideState.show()
        let guideModel = WorkBarModel(wantedSpace: WantedSpaceBackend(vault: KeychainSession(service: "geuntae-bar-guide-\(UUID().uuidString)")),
                                      defaults: guideDefaults)
        let guideRenderer = ImageRenderer(content: OnboardingWindow(model: guideModel, onboarding: guideState)
            .frame(width: 920, height: 760).environment(\.colorScheme, .light).background(Color.white))
        guideRenderer.scale = 2
        let guideImage = guideRenderer.cgImage!
        let guideBitmap = NSBitmapImageRep(cgImage: guideImage)
        try guideBitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("guide-brand.png"))
        let guideRequest = VNRecognizeTextRequest()
        guideRequest.recognitionLanguages = ["en-US", "ko-KR"]
        guideRequest.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: guideImage).perform([guideRequest])
        let guideText = (guideRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        precondition(guideText.contains("Geuntae bar"))
        precondition(!guideText.contains("Wanted Work Bar"))
        print("Menu and brand rendering checks passed")
    }
}
