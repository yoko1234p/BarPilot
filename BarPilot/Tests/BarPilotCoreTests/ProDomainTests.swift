import BarPilotCore
import Foundation
import XCTest

final class ProDomainTests: XCTestCase {
    func testEveryFeatureStartsDisabled() {
        let settings = ProFeatureSettings()
        XCTAssertFalse(settings.shelf); XCTAssertFalse(settings.clipboard); XCTAssertFalse(settings.calendar)
        XCTAssertFalse(settings.media); XCTAssertFalse(settings.weather); XCTAssertFalse(settings.system)
        XCTAssertFalse(settings.clocks); XCTAssertFalse(settings.agents); XCTAssertFalse(settings.automation)
        XCTAssertFalse(settings.capsule)
        XCTAssertNil(settings.weatherLocation)
    }
    func testPasswordAndTransientClipboardTypesAreExcluded() {
        for type in ClipboardHistoryPolicy.concealedTypes {
            XCTAssertFalse(ClipboardHistoryPolicy.mayCollect(types: ["public.utf8-plain-text", type]))
        }
        XCTAssertTrue(ClipboardHistoryPolicy.mayCollect(types: ["public.utf8-plain-text"]))
    }
    func testHistoryRetentionPinsDeduplicationAndCountCap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var pinned = entry("keep", date: now.addingTimeInterval(-86400 * 30)); pinned.pinned = true
        let expired = entry("expired", date: now.addingTimeInterval(-86400 * 8))
        let recent = entry("new", date: now)
        let duplicate = entry("new", date: now.addingTimeInterval(-60))
        let result = ClipboardHistoryPolicy.prune([recent, duplicate, expired, pinned], now: now, days: 7, limit: 2)
        XCTAssertEqual(result.map(\.digest), ["keep", "new"])
    }
    func testHistoryRejectsLargeEntriesAndBoundsTotalPayload() {
        let now = Date()
        var oversized = entry("too-big", date: now)
        oversized.data = Data(count: ClipboardHistoryPolicy.maxEntryBytes + 1)
        let bounded = (0..<8).map { index -> ClipboardEntry in
            var item = entry(String(index), date: now.addingTimeInterval(Double(index)))
            item.data = Data(count: ClipboardHistoryPolicy.maxEntryBytes); return item
        }
        let result = ClipboardHistoryPolicy.prune([oversized] + bounded, now: now, days: 7, limit: 100)
        XCTAssertEqual(result.count, 4)
        XCTAssertLessThanOrEqual(result.reduce(0) { $0 + $1.data.count }, ClipboardHistoryPolicy.maxTotalBytes)
    }
    func testWeatherRequiresValidFiniteCoordinatesAndHTTPS() {
        XCTAssertNil(WeatherLocation(name: "bad", latitude: .nan, longitude: 0).requestURL)
        XCTAssertNil(WeatherLocation(name: "bad", latitude: 91, longitude: 0).requestURL)
        XCTAssertNil(WeatherLocation(name: "bad", latitude: 0, longitude: 181).requestURL)
        let url = WeatherLocation(name: "香港", latitude: 22.3, longitude: 114.2).requestURL
        XCTAssertEqual(url?.scheme, "https"); XCTAssertEqual(url?.host, "api.open-meteo.com")
        XCTAssertTrue(url?.query?.contains("latitude=22.3") == true)
        XCTAssertFalse(url?.absoluteString.contains("香港") == true)
    }
    func testMeetingLinksRejectSpoofedHostsAndUnsafeSchemes() {
        XCTAssertNil(MeetingLink.first(in: ["https://meet.google.com.evil.example/a", "http://zoom.us/j/1", "file:///tmp/meet.google.com"]))
        XCTAssertEqual(MeetingLink.first(in: ["Room A", "Join https://us02web.zoom.us/j/123"] )?.host, "us02web.zoom.us")
        XCTAssertEqual(MeetingLink.first(in: ["https://meet.google.com/abc-defg-hij"])?.host, "meet.google.com")
    }
    func testAgentSnapshotRejectsBooleanAndOutOfRangeQuotaAndDoesNotExposeText() throws {
        let data = try JSONSerialization.data(withJSONObject: [[
            "provider": "codex", "status": "private conversation", "session": "secret", "updatedAt": 1000,
            "windows": [["id": "good", "percent": 33], ["id": "bad", "percent": true], ["id": "over", "percent": 101]],
        ]])
        let values = AgentSnapshotReader.read(data, now: Date(timeIntervalSince1970: 1100))
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values[0].quotas.map(\.percent), [33]); XCTAssertFalse(values[0].isStale)
        XCTAssertTrue(AgentSnapshotReader.read(data, now: Date(timeIntervalSince1970: 5000))[0].isStale)
        XCTAssertTrue(AgentSnapshotReader.read(data, now: Date(timeIntervalSince1970: 0))[0].isStale)
    }
    func testScheduleRespectsWeekdaysAndCrossingMidnight() {
        let day = AutomationCondition.schedule(startMinute: 630, endMinute: 1170, weekdays: [2,3,4,5,6])
        XCTAssertTrue(day.matches(context(weekday: 2, minute: 630)))
        XCTAssertFalse(day.matches(context(weekday: 2, minute: 1170)))
        XCTAssertFalse(day.matches(context(weekday: 7, minute: 700)))
        let overnight = AutomationCondition.schedule(startMinute: 1380, endMinute: 120, weekdays: [6])
        XCTAssertTrue(overnight.matches(context(weekday: 6, minute: 1439)))
        XCTAssertTrue(overnight.matches(context(weekday: 7, minute: 119)))
        XCTAssertFalse(overnight.matches(context(weekday: 7, minute: 120)))
        XCTAssertFalse(overnight.matches(context(weekday: 6, minute: 90)))
    }
    func testConditionsMustAllMatchAndInvalidRangesFailClosed() {
        var rule = ProAutomationRule(name: "work", conditions: [.frontApplication(bundleID: "com.apple.Safari"), .displayCount(minimum: 2, maximum: 3)], action: .showShelf)
        let matched = context(weekday: 2, minute: 700)
        XCTAssertFalse(rule.matches(matched))
        rule.enabled = true; XCTAssertTrue(rule.matches(matched))
        var oneDisplay = matched; oneDisplay.displayCount = 1; XCTAssertFalse(rule.matches(oneDisplay))
        XCTAssertFalse(AutomationCondition.displayCount(minimum: 3, maximum: 1).matches(matched))
        XCTAssertFalse(AutomationCondition.batteryBelow(percent: 20, onBatteryOnly: true).matches(matched))
        var onBattery = matched; onBattery.onBattery = true; onBattery.batteryPercent = 19
        XCTAssertTrue(AutomationCondition.batteryBelow(percent: 20, onBatteryOnly: true).matches(onBattery))
    }
    func testAutomationRunsOnRisingEdgeWithCooldownAndDisabledRulesDoNotRun() {
        var gate = AutomationGate()
        var rule = ProAutomationRule(name: "two screens", conditions: [.displayCount(minimum: 2, maximum: 2)], action: .showShelf)
        rule.enabled = true
        var current = context(weekday: 2, minute: 700)
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(gate.actions(rules: [rule], context: current, now: now).count, 1)
        XCTAssertTrue(gate.actions(rules: [rule], context: current, now: now.addingTimeInterval(400)).isEmpty)
        current.displayCount = 1
        XCTAssertTrue(gate.actions(rules: [rule], context: current, now: now.addingTimeInterval(410)).isEmpty)
        current.displayCount = 2
        XCTAssertEqual(gate.actions(rules: [rule], context: current, now: now.addingTimeInterval(420)).count, 1)
        current.displayCount = 1; _ = gate.actions(rules: [rule], context: current, now: now.addingTimeInterval(430))
        current.displayCount = 2
        XCTAssertTrue(gate.actions(rules: [rule], context: current, now: now.addingTimeInterval(440)).isEmpty)
        rule.enabled = false; gate.reset()
        XCTAssertTrue(gate.actions(rules: [rule], context: current, now: now.addingTimeInterval(800)).isEmpty)
    }
    func testAutomationRulesAndActionArgumentsRoundTripWithoutShellParsing() throws {
        var rule = ProAutomationRule(name: "literal", conditions: [.frontApplication(bundleID: "org.example.App")], action: .localScript(path: "/tmp/my script.sh", arguments: ["$(danger)", "hello world", "`literal`", "\n"]))
        rule.enabled = true
        XCTAssertEqual(try JSONDecoder().decode(ProAutomationRule.self, from: JSONEncoder().encode(rule)), rule)
    }
    func testQueuedAutomationJobRevalidatesRuleAndCurrentConditionsBeforeDispatch() {
        var rule = ProAutomationRule(name: "two screens", conditions: [.displayCount(minimum: 2, maximum: 2)],
            action: .localScript(path: "/fixture/job.py", arguments: ["literal"]))
        rule.enabled = true
        let job = QueuedAutomationJob(rule: rule)
        let matched = context(weekday: 2, minute: 700)
        XCTAssertTrue(job.isEligible(rules: [rule], context: matched))
        var changedContext = matched; changedContext.displayCount = 1
        XCTAssertFalse(job.isEligible(rules: [rule], context: changedContext))
        var disabled = rule; disabled.enabled = false
        XCTAssertFalse(job.isEligible(rules: [disabled], context: matched))
        var editedAction = rule; editedAction.action = .localScript(path: "/fixture/other.py", arguments: ["literal"])
        XCTAssertFalse(job.isEligible(rules: [editedAction], context: matched))
        var editedArguments = rule; editedArguments.action = .localScript(path: "/fixture/job.py", arguments: ["changed"])
        XCTAssertFalse(job.isEligible(rules: [editedArguments], context: matched))
        var editedConditions = rule; editedConditions.conditions = [.displayCount(minimum: 1, maximum: 3)]
        XCTAssertTrue(editedConditions.matches(matched))
        XCTAssertFalse(job.isEligible(rules: [editedConditions], context: matched))
        XCTAssertFalse(job.isEligible(rules: [], context: matched))
        var unrelated = rule; unrelated.id = UUID()
        XCTAssertFalse(job.isEligible(rules: [unrelated], context: matched))
        XCTAssertTrue(job.isEligible(rules: [rule], context: matched))
    }
    func testCapsuleGrowthKeepsPhysicalScreenTopCentreOnBothDisplays() {
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: 160, width: 1920, height: 1080)] {
            let geometry = ProCapsuleGeometry(screenFrame: screen, topInset: 34, notchWidth: 180)
            let closed = geometry.frame(expanded: false); let open = geometry.frame(expanded: true)
            XCTAssertEqual(closed.midX, screen.midX); XCTAssertEqual(open.midX, screen.midX)
            XCTAssertEqual(closed.maxY, screen.maxY); XCTAssertEqual(open.maxY, screen.maxY)
            XCTAssertLessThan(open.minY, closed.minY); XCTAssertLessThan(open.minX, closed.minX)
            XCTAssertGreaterThan(open.maxX, closed.maxX)
        }
    }
    func testCapsuleFramesFitSmallScreenWithoutTrackingCursor() {
        let geometry = ProCapsuleGeometry(screenFrame: CGRect(x: 1800, y: -100, width: 640, height: 480), topInset: 28, notchWidth: 170)
        let frame = geometry.frame(expanded: true)
        XCTAssertLessThanOrEqual(frame.width, 616); XCTAssertLessThanOrEqual(frame.height, 420)
        XCTAssertEqual(frame.midX, 2120); XCTAssertEqual(frame.maxY, 380)
    }
    func testCapsuleDoesNotAutoHideDuringClickDragPinDropOrOverlay() {
        var state = ProCapsuleInteraction(); XCTAssertTrue(state.canAutoCollapse)
        state.pointerInside = true; XCTAssertFalse(state.canAutoCollapse); state.pointerInside = false
        state.mouseDown = true; XCTAssertFalse(state.canAutoCollapse); state.mouseDown = false
        state.pinned = true; XCTAssertFalse(state.canAutoCollapse); state.pinned = false
        state.dropTargeted = true; XCTAssertFalse(state.canAutoCollapse); state.dropTargeted = false
        state.hasOverlay = true; XCTAssertFalse(state.canAutoCollapse); state.hasOverlay = false
        XCTAssertTrue(state.canAutoCollapse)
    }
    func testNativeMediaSnapshotInterpolatesClampsAndHandlesStoppedPlayer() throws {
        let payload: [String: Any] = ["type": "data", "diff": false, "payload": [
            "title": "Fixture", "artist": "Synthetic", "bundleIdentifier": "org.fixture.Player", "playing": true,
            "duration": 100, "elapsedTime": 10, "timestamp": 1000, "playbackRate": 1,
        ]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let media = try XCTUnwrap(ProMediaSnapshot.parse(data))
        XCTAssertEqual(media.position(at: Date(timeIntervalSince1970: 1005)), 15)
        XCTAssertEqual(media.position(at: Date(timeIntervalSince1970: 1200)), 100)
        XCTAssertEqual(media.bundleID, "org.fixture.Player")
        XCTAssertNil(ProMediaSnapshot.parse(Data("{\"type\":\"data\",\"payload\":{}}".utf8)))
    }
    func testNativeMediaSnapshotSupportsMicrosAndRejectsInvalidData() throws {
        let data = Data("{\"payload\":{\"title\":\"Demo\",\"isPlaying\":false,\"durationMicros\":60000000,\"elapsedTimeMicros\":2000000}}".utf8)
        let media = try XCTUnwrap(ProMediaSnapshot.parse(data))
        XCTAssertEqual(media.duration, 60); XCTAssertEqual(media.position(at: Date()), 2)
        XCTAssertNil(ProMediaSnapshot.parse(Data("bad JSON".utf8)))
        XCTAssertNil(ProMediaSnapshot.parse(Data(count: 6 * 1024 * 1024)))
    }
    private func entry(_ digest: String, date: Date) -> ClipboardEntry {
        ClipboardEntry(kind: .text, data: Data(digest.utf8), summary: digest, digest: digest, date: date)
    }
    private func context(weekday: Int, minute: Int) -> AutomationContext {
        var context = AutomationContext(frontApplication: "com.apple.Safari", displayCount: 2, batteryPercent: 19, onBattery: false, date: Date())
        context.weekday = weekday; context.minute = minute; return context
    }
}
