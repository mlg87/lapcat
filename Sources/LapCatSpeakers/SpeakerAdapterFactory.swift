import Foundation
import LapCatCore

/// Builds the accessibility adapter for a meeting app, with the user's selector overrides applied.
/// Free of settings and permission checks so tests and the CLI can call it directly (#59).
public enum SpeakerAdapterFactory {
    /// nil when no adapter handles the bundle id (`SpeakerSources.adapterType(for:)`).
    public static func adapter(forBundleID bundleID: String, zoomSelectorsJSON: String?, meetSelectorsJSON: String?)
        -> (source: any SpeakerSource, eventSource: SpeakerEventSource)?
    {
        guard let type = SpeakerSources.adapterType(for: bundleID) else { return nil }
        if type == ZoomAXAdapter.self {
            return (
                ZoomAXAdapter(selectors: SpeakerSelectors.decode(json: zoomSelectorsJSON, fallback: .zoomDefault)),
                .zoomAX
            )
        }
        return (
            MeetAXAdapter(selectors: SpeakerSelectors.decode(json: meetSelectorsJSON, fallback: .meetDefault)), .meetAX
        )
    }
}
