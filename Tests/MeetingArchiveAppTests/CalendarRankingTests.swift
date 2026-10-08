import Foundation
import XCTest
@testable import MeetingArchiveApp

final class CalendarRankingTests: XCTestCase {
    func testClearOverlapSuggestsTitleButEqualOverlapsStayAmbiguous() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(1800)
        let a = CalendarSuggestion(id: "a", title: "Planning", start: start, end: end, attendees: [])
        let b = CalendarSuggestion(id: "b", title: "Other", start: start, end: end, attendees: [])
        XCTAssertEqual(CalendarRanking.best([a], start: start, end: end)?.id, "a")
        XCTAssertNil(CalendarRanking.best([a, b], start: start, end: end))
    }

    func testNonOverlappingCalendarEventDoesNotNameRecording() {
        let start = Date(timeIntervalSince1970: 1000)
        let event = CalendarSuggestion(id: "a", title: "Earlier", start: start.addingTimeInterval(-200), end: start, attendees: [])
        XCTAssertNil(CalendarRanking.best([event], start: start, end: start.addingTimeInterval(100)))
    }

    func testShortEventInsideALongRecordingStillNamesIt() {
        // A 30-minute calendar slot that ran over into an 82-minute call.
        let start = Date(timeIntervalSince1970: 1000)
        let event = CalendarSuggestion(id: "a", title: "Standup", start: start, end: start.addingTimeInterval(1800), attendees: [])
        XCTAssertEqual(CalendarRanking.best([event], start: start, end: start.addingTimeInterval(4961))?.id, "a")
    }

    func testAMultiDayEventCoveringTheCallDoesNotNameIt() {
        // A four-day trip in the calendar that happens to span an 86-minute call.
        let start = Date(timeIntervalSince1970: 400_000)
        let end = start.addingTimeInterval(86 * 60)
        let trip = CalendarSuggestion(
            id: "trip", title: "Weekend away", start: start.addingTimeInterval(-3 * 86_400),
            end: start.addingTimeInterval(86_400), attendees: []
        )
        XCTAssertNil(CalendarRanking.best([trip], start: start, end: end))
    }

    func testABriefCallInsideALongBlockDoesNotTakeItsName() {
        // A 20-minute call during a three-hour focus block.
        let start = Date(timeIntervalSince1970: 400_000)
        let block = CalendarSuggestion(
            id: "focus", title: "Focus time", start: start.addingTimeInterval(-3600),
            end: start.addingTimeInterval(2 * 3600), attendees: []
        )
        XCTAssertNil(CalendarRanking.best([block], start: start, end: start.addingTimeInterval(1200)))
    }

    func testTheMeetingStillWinsWhenALongEventAlsoCoversTheCall() {
        let start = Date(timeIntervalSince1970: 400_000)
        let end = start.addingTimeInterval(1800)
        let trip = CalendarSuggestion(
            id: "trip", title: "Weekend away", start: start.addingTimeInterval(-86_400),
            end: start.addingTimeInterval(86_400), attendees: []
        )
        let sync = CalendarSuggestion(id: "sync", title: "Team sync", start: start, end: end, attendees: [])
        XCTAssertEqual(CalendarRanking.best([trip, sync], start: start, end: end)?.id, "sync")
    }

    func testDefaultSelectionPicksOwnAccountCalendarsOnly() {
        let calendars = [
            CalendarCandidate(id: "work", account: .calDAV, kind: .calDAV, writable: true),
            CalendarCandidate(id: "personal", account: .calDAV, kind: .calDAV, writable: true),
            CalendarCandidate(id: "holidays", account: .calDAV, kind: .calDAV, writable: false),
            CalendarCandidate(id: "birthdays", account: .birthdays, kind: .birthday, writable: false),
            CalendarCandidate(id: "subscribed", account: .subscribed, kind: .subscription, writable: false),
            CalendarCandidate(id: "on-my-mac", account: .local, kind: .local, writable: true),
            CalendarCandidate(id: "outlook", account: .exchange, kind: .exchange, writable: true),
        ]
        XCTAssertEqual(CalendarService.defaultSelection(from: calendars), ["work", "personal", "outlook"])
    }
}
