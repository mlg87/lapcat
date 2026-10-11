import Testing

@testable import LapCatSpeakers

@Suite struct SpeakerAdapterFactoryTests {
    @Test func zoomGetsTheZoomAdapterAndZoomEvents() throws {
        let made = try #require(
            SpeakerAdapterFactory.adapter(forBundleID: "us.zoom.xos", zoomSelectorsJSON: nil, meetSelectorsJSON: nil))
        #expect(made.source is ZoomAXAdapter)
        #expect(made.eventSource == .zoomAX)
    }

    @Test func chromeGetsTheMeetAdapterAndMeetEvents() throws {
        let made = try #require(
            SpeakerAdapterFactory.adapter(
                forBundleID: "com.google.Chrome", zoomSelectorsJSON: nil, meetSelectorsJSON: nil))
        #expect(made.source is MeetAXAdapter)
        #expect(made.eventSource == .meetAX)
    }

    @Test func appsWithoutAnAdapterGetNone() {
        #expect(
            SpeakerAdapterFactory.adapter(forBundleID: "com.apple.Mail", zoomSelectorsJSON: nil, meetSelectorsJSON: nil)
                == nil)
    }
}
