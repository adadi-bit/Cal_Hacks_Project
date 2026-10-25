import Foundation
import Testing
@testable import EmberCore

/// Field report fixes: expired/singular device wording, timer scope, keyless fire refresh and the status line.
@Suite struct FieldReportTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func deviceWordingSingularAndExpired() {
        let dt = DeviceTimer(devices: [ClientDevice(kind: "oxygen", hours: 1)], powerOutSince: t0)
        let one = dt.leaveNow(routeTimeS: 600, now: t0 + 59 * 60)!
        #expect(DeviceTimer.leaveNowSentence(one, config: Fixtures.config) == "Leave now. Oxygen has 1 minute left.")
        let two = dt.leaveNow(routeTimeS: 600, now: t0 + 58 * 60)!
        #expect(DeviceTimer.leaveNowSentence(two, config: Fixtures.config) == "Leave now. Oxygen has 2 minutes left.")
        let out = dt.leaveNow(routeTimeS: 600, now: t0 + 5 * 3600)!
        #expect(out.hoursLeft == 0)
        #expect(DeviceTimer.leaveNowSentence(out, config: Fixtures.config) == "Oxygen battery is out. Leave now.")
        for s in ["Power is back."] { #expect(Fixtures.config.phrases.fixed.contains(s)) }
    }

    @Test func feedNeverReArmsAfterTheUserTurnedPowerOff() {
        let scope = DeviceTimer.scope(clientId: "c_harold", county: "paradise", builtAt: "2026-10-24T23:02:12Z")
        #expect(DeviceTimer.feedMayArm(timerRunning: false, userClearedScope: nil, scope: scope))
        #expect(!DeviceTimer.feedMayArm(timerRunning: true, userClearedScope: nil, scope: scope))
        #expect(!DeviceTimer.feedMayArm(timerRunning: false, userClearedScope: scope, scope: scope))
        let other = DeviceTimer.scope(clientId: "c_rosa", county: "paradise", builtAt: "2026-10-24T23:02:12Z")
        #expect(DeviceTimer.feedMayArm(timerRunning: false, userClearedScope: scope, scope: other))   // new card: fresh
    }

    @Test func timerScopeChangesWithCardAndBundle() {
        let a = DeviceTimer.scope(clientId: "harold", county: "paradise", builtAt: "2026-10-24T23:02:12Z")
        #expect(a == DeviceTimer.scope(clientId: "harold", county: "paradise", builtAt: "2026-10-24T23:02:12Z"))
        #expect(a != DeviceTimer.scope(clientId: "mabel", county: "paradise", builtAt: "2026-10-24T23:02:12Z"))
        #expect(a != DeviceTimer.scope(clientId: "harold", county: "paradise", builtAt: "2026-10-25T01:00:00Z"))
        #expect(a != DeviceTimer.scope(clientId: "harold", county: "butte", builtAt: "2026-10-24T23:02:12Z"))
    }

    @Test func perimeterParsing() {
        let none = """
        {"type":"FeatureCollection","features":[]}
        """.data(using: .utf8)!
        let p = FireFeed.parsePerimeter(none, now: t0)!
        #expect(p.polygon == nil)
        #expect(Timestamps.parse(p.timestamp) == t0)
        let fire = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"poly_IncidentName":"Camp","poly_DateCurrent":1800003600000},
           "geometry":{"type":"Polygon","coordinates":[[[-121.60,39.75],[-121.58,39.75],[-121.58,39.77],[-121.60,39.75]]]}},
          {"type":"Feature","properties":{"poly_IncidentName":"Old","poly_DateCurrent":1700000000000},
           "geometry":{"type":"MultiPolygon","coordinates":[[[[-121.7,39.7],[-121.69,39.7],[-121.69,39.71],[-121.7,39.7]]]]}}]}
        """.data(using: .utf8)!
        let q = FireFeed.parsePerimeter(fire, now: t0)!
        #expect(q.fire == "Camp")
        #expect(q.polygon?.count == 4)
        #expect(q.polygon?.first == [-121.60, 39.75])
        #expect(Timestamps.parse(q.timestamp) == t0 + 3600)
        #expect(FireFeed.parsePerimeter("not json".data(using: .utf8)!, now: t0) == nil)
    }

    @Test func windParsingMatchesEngineMethod() {
        // two hours from the east at 10 km/h, one hour from the south at 10 km/h (PT2H expands to two hourly samples)
        let grid = """
        {"properties":{"updateTime":"2026-10-24T21:01:08+00:00",
          "windDirection":{"uom":"wmoUnit:degree_(angle)","values":[
            {"validTime":"2026-10-24T15:00:00+00:00/PT2H","value":90},{"validTime":"2026-10-24T17:00:00+00:00/PT1H","value":180}]},
          "windSpeed":{"uom":"wmoUnit:km_h-1","values":[{"validTime":"2026-10-24T15:00:00+00:00/PT3H","value":10}]}}}
        """.data(using: .utf8)!
        let w = FireFeed.parseWind(grid, source: "api.weather.gov gridpoints/STO/47,122", now: t0)!
        #expect(abs((w.directionFromDeg ?? 0) - 116.6) < 0.2)   // atan2(2 sin90 + sin180, 2 cos90 + cos180) = atan2(2, -1)
        #expect(abs((w.speedMps ?? 0) - 2.8) < 0.05)
        #expect(Timestamps.parse(w.timestamp) == t0)
        #expect(FireFeed.durationHours("P1DT2H30M") == 27)
        #expect(FireFeed.durationHours("PT1H") == 1)
        #expect(FireFeed.gridpointPath("api.weather.gov gridpoints/STO/47,122") == "gridpoints/STO/47,122")
        #expect(FireFeed.gridpointPath("nothing") == nil)
        let feed = FireFeed(bbox: [-121.66, 39.73, -121.56, 39.8], windSource: "api.weather.gov gridpoints/STO/47,122")
        #expect(feed.windRequest?.url?.absoluteString == "https://api.weather.gov/gridpoints/STO/47,122")
        #expect(feed.perimeterRequest.url?.absoluteString.contains("geometry=-121.66,39.73,-121.56,39.8") == true)
    }

    @Test func statusLineSaysWhy() {
        let offline = FireFeed.statusText(dataAge: 6 * 3600, stale: true, online: false, lastCheck: nil, checkFailed: false, now: t0)
        #expect(offline == "Fire data from 6 h ago (old). No connection: using the data saved on this phone.")
        let checked = FireFeed.statusText(dataAge: 60, stale: false, online: true, lastCheck: t0 - 30, checkFailed: false, now: t0)
        #expect(checked == "Fire data from just now. Checked for updates just now.")
        let failed = FireFeed.statusText(dataAge: 7200, stale: false, online: true, lastCheck: nil, checkFailed: true, now: t0)
        #expect(failed == "Fire data from 2 h ago. Update check failed; trying again.")
        #expect(FireFeed.statusText(dataAge: nil, stale: true, online: false, lastCheck: nil, checkFailed: false, now: t0)
                .hasPrefix("Fire data: none on this phone."))
        #expect(Timestamps.dayText("2026-10-24T23:02:12Z") == "Oct 24")
    }
}
