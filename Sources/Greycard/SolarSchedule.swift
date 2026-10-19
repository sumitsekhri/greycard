import Foundation

/// Sunrise/sunset maths (US Naval Observatory "Almanac for Computers" algorithm,
/// official zenith 90.833°). Accurate to a few minutes, which is plenty for a warmth ramp.
enum Solar {
    struct Day {
        let sunrise: Date?
        let sunset: Date?
    }

    static func times(on date: Date, latitude: Double, longitude: Double,
                      timeZone: TimeZone = .current) -> Day {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let comps = local.dateComponents([.year, .month, .day], from: date)
        guard let dayOfYear = local.ordinality(of: .day, in: .year, for: date) else {
            return Day(sunrise: nil, sunset: nil)
        }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let utcMidnight = utc.date(from: comps),
              let localNoon = local.date(bySettingHour: 12, minute: 0, second: 0, of: date) else {
            return Day(sunrise: nil, sunset: nil)
        }

        func event(rising: Bool) -> Date? {
            guard let hours = utHours(dayOfYear: dayOfYear, lat: latitude, lon: longitude, rising: rising) else {
                return nil
            }
            var d = utcMidnight.addingTimeInterval(hours * 3600)
            // Keep the event inside the local calendar day (noon ± 12 h).
            while d < localNoon.addingTimeInterval(-12 * 3600) { d = d.addingTimeInterval(86_400) }
            while d > localNoon.addingTimeInterval(12 * 3600) { d = d.addingTimeInterval(-86_400) }
            return d
        }
        return Day(sunrise: event(rising: true), sunset: event(rising: false))
    }

    private static func utHours(dayOfYear n: Int, lat: Double, lon: Double, rising: Bool) -> Double? {
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        func deg(_ r: Double) -> Double { r * 180 / .pi }
        func norm(_ x: Double, _ m: Double) -> Double { let r = x.truncatingRemainder(dividingBy: m); return r < 0 ? r + m : r }

        let lngHour = lon / 15
        let t = Double(n) + ((rising ? 6 : 18) - lngHour) / 24
        let m = 0.9856 * t - 3.289
        let l = norm(m + 1.916 * sin(rad(m)) + 0.020 * sin(rad(2 * m)) + 282.634, 360)
        var ra = norm(deg(atan(0.91764 * tan(rad(l)))), 360)
        ra += floor(l / 90) * 90 - floor(ra / 90) * 90
        ra /= 15
        let sinDec = 0.39782 * sin(rad(l))
        let cosDec = cos(asin(sinDec))
        let cosH = (cos(rad(90.833)) - sinDec * sin(rad(lat))) / (cosDec * cos(rad(lat)))
        guard cosH >= -1, cosH <= 1 else { return nil }   // polar day / night
        let h = (rising ? 360 - deg(acos(cosH)) : deg(acos(cosH))) / 15
        let localT = h + ra - 0.06571 * t - 6.622
        return norm(localT - lngHour, 24)
    }
}

/// User settings for the automatic warmth schedule.
struct ScheduleSettings: Codable, Equatable {
    var enabled = false
    var nightKelvin = 3400
    var dayKelvin = 6500                 // 6500 = neutral (no tint during the day)
    var minutesBeforeSunset = 30         // evening ramp starts this long before sunset
    var minutesAfterSunrise = 0          // morning ramp starts this long after sunrise
    var transitionMinutes = 60           // length of each ramp
    var latitude = 49.2827               // Vancouver
    var longitude = -123.1207
    var locationName = "Vancouver"

    private static let key = "scheduleSettings"

    static func load() -> ScheduleSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(ScheduleSettings.self, from: data) else { return ScheduleSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Turns settings + the current time into a target colour temperature.
struct WarmthSchedule {
    enum Phase: Equatable { case day, warming, night, cooling }

    struct State {
        var kelvin: Int
        var phase: Phase
        var nextChange: Date?        // start of the next ramp, or end of the current one
        var nextRampStart: Date?     // start of the next ramp that hasn't begun yet
        var sunrise: Date?           // today's
        var sunset: Date?            // today's
    }

    let settings: ScheduleSettings

    func state(at now: Date = Date()) -> State {
        let cal = Calendar.current
        let today = Solar.times(on: now, latitude: settings.latitude, longitude: settings.longitude)
        let duration = max(Double(settings.transitionMinutes) * 60, 1)

        // Evening ramp of day d → morning ramp of day d+1, for yesterday/today.
        var best: (f: Double, phase: Phase, end: Date?) = (0, Phase.day, nil)
        var starts: [Date] = []
        for offset in -1...1 {
            guard let d = cal.date(byAdding: .day, value: offset, to: now),
                  let next = cal.date(byAdding: .day, value: offset + 1, to: now) else { continue }
            let evening = Solar.times(on: d, latitude: settings.latitude, longitude: settings.longitude)
            let morning = Solar.times(on: next, latitude: settings.latitude, longitude: settings.longitude)
            guard let sunset = evening.sunset, let sunrise = morning.sunrise else { continue }

            let eStart = sunset.addingTimeInterval(-Double(settings.minutesBeforeSunset) * 60)
            let eEnd = eStart.addingTimeInterval(duration)
            let mStart = sunrise.addingTimeInterval(Double(settings.minutesAfterSunrise) * 60)
            let mEnd = mStart.addingTimeInterval(duration)
            starts += [eStart, mStart]

            guard now >= eStart, now < mEnd else { continue }
            let f: Double
            let phase: Phase
            let end: Date?
            if now < eEnd {
                f = now.timeIntervalSince(eStart) / duration; phase = .warming; end = eEnd
            } else if now < mStart {
                f = 1; phase = .night; end = mStart
            } else {
                f = 1 - now.timeIntervalSince(mStart) / duration; phase = .cooling; end = mEnd
            }
            if f > best.f || best.phase == .day { best = (min(max(f, 0), 1), phase, end) }
        }

        // Interpolate in mireds (1e6 / K): perceptually even steps, like f.lux.
        let mDay = 1e6 / Double(settings.dayKelvin)
        let mNight = 1e6 / Double(settings.nightKelvin)
        let kelvin = Int((1e6 / (mDay + best.f * (mNight - mDay))).rounded())

        let next = best.phase == .day ? starts.filter { $0 > now }.min() : best.end
        return State(kelvin: kelvin, phase: best.phase, nextChange: next,
                     nextRampStart: starts.filter { $0 > now }.min(),
                     sunrise: today.sunrise, sunset: today.sunset)
    }
}
