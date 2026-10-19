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

        // Each hour is one donut segment; newer laps fill clockwise over the completed lap.
        let empty = Array(repeating: 0.0, count: 6)
        let full = Array(repeating: 1.0, count: 6)
        let iconCases: [(String, WorkMeter?, [Double], [Double], [Double])] = [
            ("unknown", nil, [0], [0], [0]),
            ("empty", WorkMeter(actualMinutes: 0, targetMinutes: 360), empty, empty, empty),
            ("ten-minutes", WorkMeter(actualMinutes: 10, targetMinutes: 360),
             [1.0 / 6, 0, 0, 0, 0, 0], empty, empty),
            ("half-hour", WorkMeter(actualMinutes: 30, targetMinutes: 360),
             [0.5, 0, 0, 0, 0, 0], empty, empty),
            ("one-hour", WorkMeter(actualMinutes: 60, targetMinutes: 360),
             [1, 0, 0, 0, 0, 0], empty, empty),
            ("half-third", WorkMeter(actualMinutes: 150, targetMinutes: 360),
             [1, 1, 0.5, 0, 0, 0], empty, empty),
            ("green-full", WorkMeter(actualMinutes: 360, targetMinutes: 360), full, empty, empty),
            ("yellow-start", WorkMeter(actualMinutes: 361, targetMinutes: 360),
             [59.0 / 60, 1, 1, 1, 1, 1], [1.0 / 60, 0, 0, 0, 0, 0], empty),
            ("yellow-half-second", WorkMeter(actualMinutes: 450, targetMinutes: 360),
             [0, 0.5, 1, 1, 1, 1], [1, 0.5, 0, 0, 0, 0], empty),
            ("yellow-full", WorkMeter(actualMinutes: 720, targetMinutes: 360), empty, full, empty),
            ("red-start", WorkMeter(actualMinutes: 721, targetMinutes: 360),
             empty, [59.0 / 60, 1, 1, 1, 1, 1], [1.0 / 60, 0, 0, 0, 0, 0]),
            ("red-half-second", WorkMeter(actualMinutes: 810, targetMinutes: 360),
             empty, [0, 0.5, 1, 1, 1, 1], [1, 0.5, 0, 0, 0, 0]),
            ("red-full", WorkMeter(actualMinutes: 1080, targetMinutes: 360), empty, empty, full),
            ("beyond-red", WorkMeter(actualMinutes: 1200, targetMinutes: 360), empty, empty, full),
            ("partial-last-cell", WorkMeter(actualMinutes: 370, targetMinutes: 380),
             [1, 1, 1, 1, 1, 1, 0.5], [0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0]),
            ("partial-last-overlay", WorkMeter(actualMinutes: 750, targetMinutes: 380),
             [0, 0, 0, 0, 0, 0, 0.5], [1, 1, 1, 1, 1, 1, 0.5], [0, 0, 0, 0, 0, 0, 0]),
            ("zero-target", WorkMeter(actualMinutes: 30, targetMinutes: 0), [0], [0.5], [0])
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
                                                 "\(appearanceName.rawValue) \(name) ended=\(finished) hour \(hour) at \(p)")
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
                precondition(ringPixel(noTarget, hours: 3, hour: 0, at: 0.5, radius: 7.75).alphaComponent > 0.9)
                precondition(matches(ringPixel(noTarget, hours: 3, hour: 2, at: 0.3, radius: 5.5), .systemGray))
                precondition(!matches(ringPixel(noTarget, hours: 3, hour: 2, at: 0.8, radius: 5.5), .systemGray))
                for hour in 0..<3 {
                    let pixel = ringPixel(noTarget, hours: 3, hour: hour, at: 0.3, radius: 7.75)
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
            precondition(image.width == 680)
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
        func filled(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Bool {
            let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return color.greenComponent > 0.5 && color.blueComponent > 0.5 &&
                color.blueComponent < 0.85 && color.redComponent < 0.3
        }
        func monthBarY(_ bitmap: NSBitmapImageRep, after dayBar: Int = -20) -> Int {
            (0..<bitmap.pixelsHigh).first { $0 > dayBar + 20 && filled(bitmap, x: 40, y: $0) }! + 6
        }
        func marker(_ bitmap: NSBitmapImageRep, minutes: Int, range: Int, y: Int, color: NSColor) -> Bool {
            let x = Int((16 + 308 * Double(minutes) / Double(range)) * 2)
            let expected = color.usingColorSpace(.sRGB)!
            return (max(0, x - 2)...min(bitmap.pixelsWide - 1, x + 2)).contains { column in
                ((y - 14)...(y + 14)).contains { row in
                    let pixel = bitmap.colorAt(x: column, y: row)!.usingColorSpace(.sRGB)!
                    return abs(pixel.redComponent - expected.redComponent) < 0.15 &&
                        abs(pixel.greenComponent - expected.greenComponent) < 0.15 &&
                        abs(pixel.blueComponent - expected.blueComponent) < 0.15
                }
            }
        }

        // Four hours against a six-hour minimum fills 2/3, rather than the fixed eight-hour 1/2.
        let working = DailyRecord(date: date, start: start, scheduledEnd: scheduledEnd,
                                  currentMinutes: 240, holidayStatus: workday)
        let (bitmap, texts) = try await render(working, name: "working")
        precondition(texts.contains("4시간0분/최소6시간0분"))
        precondition(texts.contains("67%달성"))
        precondition(texts.filter { $0.contains("/최소6시간0분") }.count == 1)
        precondition(!texts.contains("4시간0분/8시간0분"))
        precondition(texts.firstIndex(of: "오늘")! < texts.firstIndex(of: "이번달")!)
        precondition(!texts.contains { $0.contains("회사수당기준") || $0.contains("리프레시데이") })
        precondition(texts.contains { $0.contains("출근09:00") })
        precondition(texts.contains { $0.contains("예상퇴근18:00") })
        precondition(texts.joined().contains("오늘까지기준120시간0분"))
        precondition(texts.joined().contains("필수근무시간-") && texts.joined().contains("(하루평균"))
        precondition(texts.joined().contains("수당기준-"))
        precondition(texts.contains { $0.contains("필수시간대비94%") })
        precondition(texts.contains { $0.contains("최대160시간0분") })
        let barY = (0..<bitmap.pixelsHigh).first { filled(bitmap, x: 40, y: $0) }!
        precondition(filled(bitmap, x: 400, y: barY) && !filled(bitmap, x: 500, y: barY))
        let monthlyY = monthBarY(bitmap, after: barY)
        precondition(filled(bitmap, x: 480, y: monthlyY) && !filled(bitmap, x: 510, y: monthlyY))
        precondition(marker(bitmap, minutes: 7200, range: 9600, y: monthlyY, color: .systemRed))
        precondition(marker(bitmap, minutes: 7680, range: 9600, y: monthlyY, color: .systemBlue))
        precondition(marker(bitmap, minutes: 8160, range: 9600, y: monthlyY, color: .systemPurple))
        let filledRows = (0..<bitmap.pixelsHigh).filter { filled(bitmap, x: 40, y: $0) }
        precondition(zip(filledRows, filledRows.dropFirst()).filter { $1 > $0 + 1 }.count == 1)

        let reached = DailyRecord(date: date, start: start, scheduledEnd: scheduledEnd,
                                  currentMinutes: 480, holidayStatus: workday)
        let (_, reachedTexts) = try await render(reached, name: "reached")
        precondition(reachedTexts.contains("8시간0분/최소6시간0분") && reachedTexts.contains("100%달성"))
        precondition(reachedTexts.joined().contains("오늘까지기준120시간0분"))
        let (zeroBitmap, zeroTexts) = try await render(working, required: 6600, name: "zero-target")
        precondition(zeroTexts.contains("이번달필수시간달성") && zeroTexts.contains("100%달성"))
        let zeroBarY = (0..<zeroBitmap.pixelsHigh).first { filled(zeroBitmap, x: 40, y: $0) }!
        precondition(filled(zeroBitmap, x: 620, y: zeroBarY))

        let offDay = DailyRecord(date: date, workedMinutes: 240, holidayStatus: "HOLIDAY_WORKING_OFF_NONE_NONE")
        let (offBitmap, offTexts) = try await render(offDay, days: 0, name: "no-workdays")
        precondition(offTexts.contains("4시간0분") && offTexts.contains("남은근무일없음"))
        precondition(!offTexts.contains { $0.contains("/최소") })
        let monthY = (0..<offBitmap.pixelsHigh).first { filled(offBitmap, x: 40, y: $0) }!
        precondition(monthY > offBitmap.pixelsHigh / 3)

        let before = DailyRecord(date: date, scheduledEnd: scheduledEnd, holidayStatus: workday)
        let (_, beforeTexts) = try await render(before, name: "before-clock-in")
        precondition(beforeTexts.contains("0시간0분/최소6시간0분") && beforeTexts.contains("0%달성"))
        let ended = DailyRecord(date: date, start: start, end: "2026-10-01T13:00:00+09:00",
                                scheduledEnd: scheduledEnd, workedMinutes: 240, holidayStatus: workday)
        let (_, endedTexts) = try await render(ended, days: 1, name: "after-clock-out")
        precondition(endedTexts.contains("4시간0분/최소6시간0분") && endedTexts.contains("67%달성"))
        precondition(endedTexts.contains { $0.contains("퇴근13:00") })

        let overnight = DailyRecord(date: "2026-09-30", start: "2026-09-30T15:00:00+09:00",
                                    scheduledEnd: "2026-09-30T18:00:00+09:00",
                                    currentMinutes: 540, holidayStatus: workday)
        let previousMonth = MonthlyReport(workedMinutes: 7740, outsideMinutes: 0,
                                          requiredMinutes: 7920, vacationMinutes: 0,
                                          weekendMinutes: 0, dailyRequiredMinutes: 480,
                                          startDate: "2026-09-01", endDate: "2026-09-30",
                                          maximumWorkMinutes: 9600)
        let (_, overnightTexts) = try await render(overnight, days: 0, report: previousMonth, name: "overnight")
        precondition(overnightTexts.contains("2026-09-30") && overnightTexts.contains("2026-09"))
        precondition(!overnightTexts.contains("오늘") && !overnightTexts.contains("이번달"))
        precondition(overnightTexts.contains("9시간0분/최소12시간0분"))
        precondition(overnightTexts.joined().contains("2026-09-30까지기준132시간0분"))

        let (overlapBitmap, overlapTexts) = try await render(working, refreshDay: false, name: "overlapping-markers")
        let overlapY = monthBarY(overlapBitmap, after: barY)
        precondition(overlapTexts.joined().contains("수당기준-"))
        precondition(marker(overlapBitmap, minutes: 7680, range: 9600, y: overlapY, color: .systemBlue))
        precondition(marker(overlapBitmap, minutes: 7680, range: 9600, y: overlapY, color: .systemPurple))

        let noMaximum = MonthlyReport(workedMinutes: 7200, outsideMinutes: 0,
                                      requiredMinutes: 7680, vacationMinutes: 0, weekendMinutes: 0,
                                      dailyRequiredMinutes: 480, startDate: date, endDate: "2026-10-31",
                                      maximumWorkMinutes: nil)
        let (fallbackBitmap, fallbackTexts) = try await render(working, report: noMaximum, name: "no-maximum")
        let fallbackY = monthBarY(fallbackBitmap, after: barY)
        precondition(marker(fallbackBitmap, minutes: 8160, range: 8160, y: fallbackY, color: .systemPurple))
        precondition(!fallbackTexts.contains { $0.contains("월최대") })
        let insufficientMaximum = MonthlyReport(workedMinutes: 7200, outsideMinutes: 0,
                                                requiredMinutes: 7680, vacationMinutes: 0, weekendMinutes: 0,
                                                dailyRequiredMinutes: 480, startDate: date, endDate: "2026-10-31",
                                                maximumWorkMinutes: 7200)
        let (expandedBitmap, _) = try await render(working, report: insufficientMaximum, name: "expanded-range")
        precondition(marker(expandedBitmap, minutes: 8160, range: 8160,
                            y: monthBarY(expandedBitmap, after: barY), color: .systemPurple))
        let (missingBitmap, missingTexts) = try await render(working, compensation: false, name: "no-compensation")
        let missingY = monthBarY(missingBitmap, after: barY)
        precondition(missingTexts.joined().contains("수당기준확인불가"))
        precondition(!marker(missingBitmap, minutes: 8160, range: 9600, y: missingY, color: .systemPurple))

        let zeroMonth = MonthlyReport(workedMinutes: 0, outsideMinutes: 0,
                                     requiredMinutes: 0, vacationMinutes: 0, weekendMinutes: 0,
                                     dailyRequiredMinutes: 480, startDate: date, endDate: "2026-10-31",
                                     maximumWorkMinutes: nil)
        let (allZeroBitmap, allZeroTexts) = try await render(before, report: zeroMonth, refreshDay: false, name: "all-zero")
        precondition(allZeroTexts.joined().contains("필수근무시간-0시간0분"))
        // All three markers share the start of a zero-length range.
        let markerRows = (0..<allZeroBitmap.pixelsHigh).filter {
            let pixel = allZeroBitmap.colorAt(x: 32, y: $0)!.usingColorSpace(.deviceRGB)!
            return pixel.redComponent > 0.8 && pixel.greenComponent < 0.4 && pixel.blueComponent < 0.4
        }
        let allZeroY = markerRows.first! + 14
        for color in [NSColor.systemRed, .systemBlue, .systemPurple] {
            precondition(marker(allZeroBitmap, minutes: 0, range: 1, y: allZeroY, color: color))
        }
        let overMaximum = MonthlyReport(workedMinutes: 10080, outsideMinutes: 0,
                                        requiredMinutes: 7680, vacationMinutes: 0, weekendMinutes: 0,
                                        dailyRequiredMinutes: 480, startDate: date, endDate: "2026-10-31",
                                        maximumWorkMinutes: 9600)
        let (overBitmap, overTexts) = try await render(working, report: overMaximum, name: "over-maximum")
        let overY = monthBarY(overBitmap, after: barY)
        precondition(filled(overBitmap, x: 620, y: overY))
        precondition(overTexts.contains { $0.contains("누적168시간0분") } && overTexts.contains { $0.contains("필수시간대비131%") })
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
