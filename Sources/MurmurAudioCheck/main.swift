import AVFoundation
import CoreAudio
import Foundation
import MurmurAudio

// swift run MurmurAudioCheck                 device-recovery logic; no hardware, runs in CI
// swift run MurmurAudioCheck --hardware      + live capture on this Mac's real devices
// swift run MurmurAudioCheck --interactive   + asks you to disconnect Bluetooth headphones
//
// The hardware checks briefly change two system settings to provoke real device changes —
// the built-in mic's sample rate, and the default output — and put both back afterwards.

let arguments = Set(CommandLine.arguments.dropFirst())
let runHardware = arguments.contains("--hardware") || arguments.contains("--interactive")
let runInteractive = arguments.contains("--interactive")

var failures: [String] = []
var passes = 0

@MainActor func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        passes += 1
        print("  ✓ \(name)")
    } else {
        let detail = detail()
        failures.append(detail.isEmpty ? name : "\(name) — \(detail)")
        print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func section(_ title: String) { print("\n\(title)") }

// MARK: - Logic

section("Device resolution")
do {
    let builtIn = AudioInputDevice(id: 78, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    let airPods = AudioInputDevice(id: 223_836, uid: "58-36-53-96-21-86:input", name: "AirPods Pro")
    let loopback = AudioInputDevice(id: 90, uid: "Loopback", name: "Lightsaber Microphone")
    let all = [loopback, builtIn, airPods]

    check(AudioDevices.resolve(preferredUID: builtIn.uid, available: all, systemDefault: airPods) == builtIn,
          "the chosen mic wins over the default")
    check(AudioDevices.resolve(preferredUID: nil, available: all, systemDefault: airPods) == airPods,
          "no choice follows the system default")
    check(AudioDevices.resolve(preferredUID: "", available: all, systemDefault: airPods) == airPods,
          "an empty choice is the same as none")
    check(AudioDevices.resolve(preferredUID: airPods.uid, available: [loopback, builtIn], systemDefault: builtIn) == builtIn,
          "headphones gone falls back to the default")
    check(AudioDevices.resolve(preferredUID: airPods.uid, available: [loopback, builtIn], systemDefault: airPods) == nil,
          "a default that names a device already gone resolves to nothing")
    check(AudioDevices.resolve(preferredUID: nil, available: all, systemDefault: nil) == nil,
          "never falls back to the first device in the list")
    check(AudioDevices.resolve(preferredUID: nil, available: [], systemDefault: builtIn) == nil,
          "no inputs at all resolves to nothing")
}

section("Format-change filtering")
do {
    let music = StreamShape(sampleRate: 48_000, channels: 1)
    check(!StreamShape.needsRebuild(running: music, current: music), "a repeat notification for the same format is ignored")
    check(StreamShape.needsRebuild(running: music, current: StreamShape(sampleRate: 24_000, channels: 1)),
          "AirPods dropping to headset rate rebuilds")
    check(StreamShape.needsRebuild(running: music, current: StreamShape(sampleRate: 48_000, channels: 2)),
          "a channel-count change rebuilds")
    check(StreamShape.needsRebuild(running: music, current: nil), "an unreadable format rebuilds")
    check(StreamShape.needsRebuild(running: music, current: StreamShape(sampleRate: 0, channels: 0)),
          "a device mid-switch (0 Hz) rebuilds")
}

section("Recovery pacing")
do {
    var policy = RecoveryPolicy(maxAttempts: 5, window: 15, initialDelay: 0.2, maxDelay: 2)
    let delays = (0..<5).compactMap { policy.nextDelay(at: Double($0) * 0.5) }
    check(delays == [0.2, 0.4, 0.8, 1.6, 2], "backs off and caps the delay", "\(delays)")
    check(policy.nextDelay(at: 3) == nil, "gives up on a device flapping inside the window")
    check(policy.nextDelay(at: 20) == 0.2, "a long session recovers again once the window has passed")

    var meeting = RecoveryPolicy()
    let spread = [0.0, 600, 1_200, 1_800, 2_400, 3_000].map { meeting.nextDelay(at: $0) }
    check(spread.allSatisfy { $0 != nil }, "an hour-long meeting survives a reconnect every ten minutes")
}

section("Stall detection")
do {
    var detector = StallDetector(timeout: 3, now: 0)
    check(!detector.isStalled(callbacks: 0, at: 2.9), "waits out a slow first buffer (headset-mode switch)")
    check(detector.isStalled(callbacks: 0, at: 3.0), "no audio at all for the timeout is a stall")
    var flowing = StallDetector(timeout: 3, now: 0)
    _ = flowing.isStalled(callbacks: 10, at: 2)
    check(!flowing.isStalled(callbacks: 10, at: 4.9), "the clock restarts from the last buffer")
    check(flowing.isStalled(callbacks: 10, at: 5.0), "and fires once audio stops")
}

// MARK: - Hardware

/// Collects what the capture delivers, from the audio thread.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var last: TimeInterval?
    private var maxGap: TimeInterval = 0
    private var badFormat = 0
    private var peak: Float = 0

    func add(_ chunk: AudioChunk, expecting format: AVAudioFormat) {
        let now = ProcessInfo.processInfo.systemUptime
        var chunkPeak: Float = 0
        if let data = chunk.buffer.floatChannelData?[0] {
            for i in 0..<Int(chunk.buffer.frameLength) { chunkPeak = max(chunkPeak, abs(data[i])) }
        }
        lock.lock(); defer { lock.unlock() }
        samples += Int(chunk.buffer.frameLength)
        if chunk.buffer.format != format { badFormat += 1 }
        if let last { maxGap = max(maxGap, now - last) }
        last = now
        peak = max(peak, chunkPeak)
    }

    /// For system audio, which arrives as plain mono samples rather than buffers.
    func addSamples(_ chunk: [Float]) {
        let now = ProcessInfo.processInfo.systemUptime
        let chunkPeak = chunk.map(abs).max() ?? 0
        lock.lock(); defer { lock.unlock() }
        samples += chunk.count
        if let last { maxGap = max(maxGap, now - last) }
        last = now
        peak = max(peak, chunkPeak)
    }

    var snapshot: (samples: Int, maxGap: TimeInterval, badFormat: Int, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        return (samples, maxGap, badFormat, peak)
    }
}

let engineFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

/// Records for `seconds`, optionally doing something partway through.
@MainActor
func record(
    preferredUID: String?,
    seconds: Double,
    midway: (@MainActor () async -> Void)? = nil
) async -> (tally: Tally, capture: AudioCapture, failure: String?, error: Error?) {
    let capture = AudioCapture()
    let tally = Tally()
    var failure: String?
    capture.onFailure = { failure = $0 }
    do {
        try capture.start(
            outputFormat: engineFormat,
            preferredDeviceUID: preferredUID,
            onBuffer: { tally.add($0, expecting: engineFormat) },
            onLevel: { _ in }
        )
    } catch {
        return (tally, capture, nil, error)
    }
    if let midway {
        await sleep(seconds / 2)
        await midway()
        await sleep(seconds / 2)
    } else {
        await sleep(seconds)
    }
    capture.stop()
    return (tally, capture, failure, nil)
}

/// At least 80% of the audio a run of this length should have produced.
@MainActor func expectAudio(_ name: String, _ run: (tally: Tally, capture: AudioCapture, failure: String?, error: Error?), seconds: Double, maxGap: Double) {
    let s = run.tally.snapshot
    let expected = Int(seconds * engineFormat.sampleRate)
    check(run.error == nil, "\(name): starts", "\(run.error?.localizedDescription ?? "")")
    check(run.failure == nil, "\(name): never gives up", run.failure ?? "")
    check(s.samples >= expected * 8 / 10, "\(name): delivers audio", "\(s.samples) of ~\(expected) samples")
    check(s.badFormat == 0, "\(name): every buffer is 16 kHz mono", "\(s.badFormat) wrong")
    check(s.maxGap <= maxGap, "\(name): longest gap \(String(format: "%.2f", s.maxGap))s ≤ \(maxGap)s")
}

// CoreAudio helpers for provoking real changes.

func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

@discardableResult
func setProperty<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) -> OSStatus {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = value
    return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
}

func outputDevices() -> [(id: AudioDeviceID, name: String)] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr, let name else { return nil }
        return (id, name.takeRetainedValue() as String)
    }
}

let system = AudioObjectID(kAudioObjectSystemObject)

if runHardware {
    await MainActor.run {}
    let inputs = AudioDevices.inputs()
    let builtIn = inputs.first { $0.uid == "BuiltInMicrophoneDevice" }
    let bluetooth = inputs.first { $0.name.localizedCaseInsensitiveContains("airpods") || $0.uid.contains(":input") }
    let defaultOutput = property(system, kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))
    let outputs = outputDevices()
    let defaultOutputName = outputs.first { $0.id == defaultOutput }?.name ?? "?"

    section("Hardware — inputs: \(inputs.map(\.name).joined(separator: ", ")); output: \(defaultOutputName)")

    // 1. The reported crash: built-in mic chosen, Bluetooth headphones as the output, the
    //    same capture opened and closed repeatedly. AVAudioEngine aborted on the second open.
    if let builtIn {
        let capture = AudioCapture()
        var ok = 0
        for _ in 1...8 {
            let tally = Tally()
            do {
                try capture.start(outputFormat: engineFormat, preferredDeviceUID: builtIn.uid,
                                  onBuffer: { tally.add($0, expecting: engineFormat) }, onLevel: { _ in })
            } catch {
                print("    start failed: \(error.localizedDescription)")
                continue
            }
            await sleep(0.6)
            capture.stop()
            if tally.snapshot.samples > 4_000, tally.snapshot.badFormat == 0 { ok += 1 }
        }
        check(ok == 8, "built-in mic, 8 rapid open/close cycles on one capture (the reported crash)", "\(ok)/8 delivered audio")
    }

    // 2. Each input on its own, for a few seconds.
    for device in [builtIn, bluetooth].compactMap({ $0 }) {
        let run = await record(preferredUID: device.uid, seconds: 4)
        // Bluetooth may legitimately rebuild once when it drops into headset mode.
        expectAudio(device.name, run, seconds: 4, maxGap: device == bluetooth ? 1.5 : 0.3)
        print("    recoveries: \(run.capture.recoveries)")
    }

    // 3. A real format change mid-recording: the built-in mic's sample rate is switched
    //    underneath the capture, which is what a Bluetooth mode switch looks like to it.
    if let builtIn, let original = property(builtIn.id, kAudioDevicePropertyNominalSampleRate, Float64(0)) {
        let other: Float64 = original == 48_000 ? 44_100 : 48_000
        let run = await record(preferredUID: builtIn.uid, seconds: 6) {
            let status = setProperty(builtIn.id, kAudioDevicePropertyNominalSampleRate, other)
            print("    switched built-in mic \(Int(original)) → \(Int(other)) Hz (status \(status))")
        }
        setProperty(builtIn.id, kAudioDevicePropertyNominalSampleRate, original)
        expectAudio("sample-rate change mid-recording", run, seconds: 6, maxGap: 1.5)
        check(run.capture.recoveries >= 1, "sample-rate change was repaired, not ignored", "\(run.capture.recoveries) recoveries")
        await sleep(0.5)
        let restored = property(builtIn.id, kAudioDevicePropertyNominalSampleRate, Float64(0))
        check(restored == original, "built-in mic rate restored to \(Int(original)) Hz", "\(restored ?? -1)")
    }

    // 4a. System audio on its own, with something actually playing.
    do {
        let system = SystemAudioCapture()
        let tally = Tally()
        do {
            try system.start(outputFormat: engineFormat) { samples in
                tally.addSamples(samples)
            }
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-v", "0.05", "/System/Library/Sounds/Submarine.aiff"]
            try? player.run()
            await sleep(3)
            system.stop()
            let s = tally.snapshot
            check(s.samples > 16_000, "system audio records what is playing", "\(s.samples) samples, peak \(s.peak)")
            check(s.peak > 0.001, "and it isn't silence", "peak \(s.peak)")
        } catch {
            check(false, "system audio starts", error.localizedDescription)
        }
    }

    // 4. Default output flipping between headphones and speakers while recording, mic and
    //    system audio both running — a meeting while AirPods connect.
    if let defaultOutput, let speakers = outputs.first(where: { $0.name.localizedCaseInsensitiveContains("speakers") }),
       speakers.id != defaultOutput || outputs.count > 1 {
        let alternate = speakers.id != defaultOutput ? speakers.id : outputs.first { $0.id != defaultOutput }!.id
        let system = SystemAudioCapture()
        let systemSamples = Tally()
        var systemFailure: String?
        system.onFailure = { systemFailure = $0 }
        var systemStarted = true
        do {
            try system.start(outputFormat: engineFormat) { samples in
                systemSamples.addSamples(samples)
            }
        } catch {
            systemStarted = false
            print("    system audio unavailable here: \(error.localizedDescription)")
        }

        let run = await record(preferredUID: builtIn?.uid, seconds: 8) {
            setProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, alternate)
            await sleep(1.5)
            setProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, defaultOutput)
            // A tap only delivers while something plays, so play something on the rebuilt
            // capture — that is what proves the rebuild works, not merely that it ran.
            await sleep(1.5)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-v", "0.05", "/System/Library/Sounds/Submarine.aiff"]
            try? player.run()
        }
        let rebuilds = system.rebuilds
        system.stop()
        setProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, defaultOutput)

        expectAudio("mic while the default output flips twice", run, seconds: 8, maxGap: 0.3)
        check(run.capture.recoveries == 0, "an output change doesn't touch the mic at all", "\(run.capture.recoveries) recoveries")
        if systemStarted {
            check(systemFailure == nil, "system audio survives the output flipping", systemFailure ?? "")
            check(rebuilds >= 1, "system audio rebuilt on the new output", "\(rebuilds) rebuilds")
            check(systemSamples.snapshot.samples > 16_000 / 2 && systemSamples.snapshot.peak > 0.001, "the rebuilt system capture records what plays next", "\(systemSamples.snapshot.samples) samples")
        }
        let now = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))
        check(now == defaultOutput, "default output restored to \(defaultOutputName)")
    }

    // 5. Starting a dictation *while* headphones are mid-switch: open, then immediately
    //    change the output, on a fresh capture each time.
    if let defaultOutput, let alternate = outputs.first(where: { $0.id != defaultOutput })?.id {
        var ok = 0
        for i in 0..<4 {
            let run = await record(preferredUID: nil, seconds: 2) {
                setProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, i.isMultiple(of: 2) ? alternate : defaultOutput)
            }
            if run.error == nil, run.failure == nil, run.tally.snapshot.samples > 16_000 { ok += 1 }
        }
        setProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, defaultOutput)
        check(ok == 4, "dictation on the default mic while the output switches under it", "\(ok)/4")
    }
}

if runInteractive, let bluetooth = AudioDevices.inputs().first(where: { $0.uid.contains(":input") || $0.name.localizedCaseInsensitiveContains("airpods") }) {
    section("Interactive — \(bluetooth.name) disconnecting mid-recording")
    print("  Recording from \(bluetooth.name) for 25 seconds.")
    print("  Within the first 10 seconds, put them in their case and close the lid (or turn Bluetooth off).")
    let run = await record(preferredUID: bluetooth.uid, seconds: 25)
    let s = run.tally.snapshot
    print("    recoveries: \(run.capture.recoveries), longest gap: \(String(format: "%.2f", s.maxGap))s, failure: \(run.failure ?? "none")")
    check(run.error == nil, "starts on \(bluetooth.name)")
    check(run.failure == nil, "recording continues after the headphones disconnect", run.failure ?? "")
    check(run.capture.recoveries >= 1, "fell back to another microphone", "\(run.capture.recoveries) recoveries")
    check(s.samples >= 16_000 * 20, "most of the 25 seconds was captured", "\(s.samples / 16_000)s")
}

print("\n\(passes) passed, \(failures.count) failed")
if !failures.isEmpty {
    for failure in failures { print("  ✗ \(failure)") }
    exit(1)
}
