import Foundation
import LapCatAudio
import LapCatCore
import LapCatSpeakers

/// Everything `SessionController` reaches outside the process for. `.live` is the app's wiring;
/// tests and `lapcat-dev zoom-e2e` swap parts of it (#59).
public struct SessionDependencies: Sendable {
    public var paths: Paths
    public var makeCapture: @Sendable () -> any AudioCapturing
    public var audioProcesses: @Sendable () -> [AudioProcessInfo]
    public var calendarEvent: @Sendable (_ now: Date) -> CalendarEventInfo?
    /// nil = no adapter for this app, adapters off, or Accessibility not granted.
    public var speakerSource:
        @MainActor @Sendable (_ bundleID: String, _ settings: AppSettings) -> (
            source: any SpeakerSource, eventSource: SpeakerEventSource
        )?

    public init(
        paths: Paths,
        makeCapture: @escaping @Sendable () -> any AudioCapturing,
        audioProcesses: @escaping @Sendable () -> [AudioProcessInfo],
        calendarEvent: @escaping @Sendable (_ now: Date) -> CalendarEventInfo?,
        speakerSource:
            @escaping @MainActor @Sendable (_ bundleID: String, _ settings: AppSettings) -> (
                source: any SpeakerSource, eventSource: SpeakerEventSource
            )?
    ) {
        self.paths = paths
        self.makeCapture = makeCapture
        self.audioProcesses = audioProcesses
        self.calendarEvent = calendarEvent
        self.speakerSource = speakerSource
    }

    public static let live = SessionDependencies(
        paths: .standard,
        makeCapture: { CaptureSession() },
        audioProcesses: { AudioProcessRegistry.processes() },
        calendarEvent: { CalendarService().currentOrUpcomingEvent(now: $0) },
        speakerSource: { bundleID, settings in
            guard settings.speakersAdaptersEnabled, AXElement.isProcessTrusted else { return nil }
            return SpeakerAdapterFactory.adapter(
                forBundleID: bundleID, zoomSelectorsJSON: settings.speakersSelectorsZoom,
                meetSelectorsJSON: settings.speakersSelectorsMeet)
        })
}
