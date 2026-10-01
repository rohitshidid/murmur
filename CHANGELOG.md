# Changelog

What changed in each release, in plain words. When you release, copy the new entry into
the GitHub release notes, and point the pill in `docs/index.html`'s hero at the new tag.

## 0.3.1 — Bluetooth headphones fix

**Murmur no longer crashes or drops your dictation when wireless headphones are connected.**

- **Fixed: crash with AirPods and other Bluetooth headphones.** Recording used to be tied
  to the headphones' *output* even when a different microphone was selected. Headphones
  switch modes whenever a microphone opens, and that switch could crash the app outright
  ("format mismatch") or crash the audio thread. Recording now opens the microphone only
  and never touches the output device.
- **Fixed: "Audio device changed. Give it a moment and try again."** Headphones settling,
  connecting or disconnecting mid-sentence now cost a fraction of a second of audio
  instead of the whole utterance. Murmur reopens the right microphone and keeps going —
  if your headphones disconnect, it carries on with the built-in mic.
- **Fixed: meeting recordings ending early** when headphones connect or disconnect. Both
  your microphone and the system-audio track now repair themselves.
- **Fixed: a crash in meeting recording** introduced and caught during this work, and a
  leak when system-audio capture failed partway through starting.
- New audio test suite (`swift run MurmurAudioCheck`), including live checks against real
  devices with `--hardware`.

Updating from an earlier version: remove Murmur from System Settings → Privacy & Security
→ Accessibility and add it back (builds are ad-hoc signed, so the old entry no longer
applies).

## 0.3.0 — Command mode

- **Command mode:** select text, hold the second key, and say what to do with it — "make
  this more formal", "bullet these". The selection is replaced when you let go.
- Fixed spoken lists said in one breath, and spacing around spoken punctuation.

## 0.2.1

- A banner when Accessibility is missing, more reliable push-to-talk key detection, and
  steadier capture while audio devices change.

## 0.2.0 — Structure and retraction

- Spoken retraction ("scratch that", "no wait") and structured formatting: lists, email
  shape, punctuation.

## 0.1.0

- First release: push-to-talk dictation on macOS with Apple Speech or Parakeet.
