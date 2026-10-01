import AVFoundation

/// One buffer of captured audio, in transit from the audio thread to the speech engine.
///
/// `AVAudioPCMBuffer` isn't `Sendable`. The unchecked conformance is only sound because
/// `AudioCapture` allocates a **fresh** buffer for every chunk and never touches it again
/// after handing it over — don't construct one of these around a borrowed buffer.
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
