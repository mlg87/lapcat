import LapCatCore

func segment(
    _ id: Int64, _ channel: Channel, _ start: Int, _ end: Int, _ text: String = "x", pass: SegmentPass = .final
) -> Segment {
    Segment(id: id, meetingID: "m", channel: channel, tStartMs: start, tEndMs: end, text: text, pass: pass)
}

func event(_ name: String, _ start: Int, _ end: Int?) -> SpeakerEvent {
    SpeakerEvent(meetingID: "m", tStartMs: start, tEndMs: end, displayName: name, source: .zoomAX)
}
