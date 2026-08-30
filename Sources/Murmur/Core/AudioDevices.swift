import AVFoundation
import CoreAudio
import Foundation

/// One microphone the Mac can hear.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    /// Stable across reboots and reconnects, unlike `id`. This is what gets persisted.
    let uid: String
    let name: String
}

/// Enumerates input devices and resolves the one to record from.
///
/// The chosen device is applied to **this app only**, by setting it on the input node's
/// audio unit rather than changing `kAudioHardwarePropertyDefaultInputDevice`. A dictation
/// app that silently repointed the system microphone would also repoint every call and
/// recording on the machine, which is not a decision it gets to make.
enum AudioDevices {
    /// Every device with at least one input channel, in the order CoreAudio reports them.
    static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id), let uid = uid(of: id), let name = name(of: id) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// The device the system would use — what "System default" resolves to right now.
    static func systemDefaultInput() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != AudioObjectID(kAudioObjectUnknown) else { return nil }

        guard let uid = uid(of: id), let name = name(of: id) else { return nil }
        return AudioInputDevice(id: id, uid: uid, name: name)
    }

    /// Resolves a persisted UID back to a live device.
    ///
    /// - Returns: nil when the setting is nil *or* names a device that isn't plugged in —
    ///   both mean "fall back to the system default", which is why unplugging a headset
    ///   doesn't leave the app with no microphone at all.
    static func device(uid: String?) -> AudioInputDevice? {
        guard let uid, !uid.isEmpty else { return nil }
        return inputs().first { $0.uid == uid }
    }

    /// The device recording will actually use, resolved for display.
    static func active(uid: String?) -> AudioInputDevice? {
        device(uid: uid) ?? systemDefaultInput()
    }

    // MARK: - Properties

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        // AudioBufferList is variable-length, so it can't be a plain stack value — the
        // channel counts live past the end of the struct.
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    private static func name(of id: AudioDeviceID) -> String? {
        string(id, kAudioObjectPropertyName) ?? string(id, kAudioDevicePropertyDeviceNameCFString)
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        let result = value as String
        return result.isEmpty ? nil : result
    }
}
