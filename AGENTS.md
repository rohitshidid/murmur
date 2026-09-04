# Working on this repo

Read this before changing anything. It is written for a coding agent picking the project up
cold, and it is mostly a list of things that look wrong but aren't, plus things that look
fine and will bite you.

---

## What this is

Push-to-talk dictation. Hold a key, talk, release, and cleaned-up text is typed into
whatever had focus. Two independent implementations:

| | macOS | Windows |
|---|---|---|
| Language | Swift 6 | C# / .NET 10 |
| UI | SwiftUI | Avalonia *(not written yet)* |
| Speech | Apple `SpeechAnalyzer`, or Parakeet via FluidAudio | Parakeet via sherpa-onnx |
| Location | repo root | `windows/` |

**The macOS app works and is in daily use. The Windows app is a dictionary engine plus a
detailed specification — no audio, hotkey, injection or UI yet.** Do not describe it as
working.

---

## The one rule that matters

**The two files in `shared/` are the specification, not a record of what the code does.**

| File | Specifies | Implemented in |
|---|---|---|
| `dictionary-test-vectors.json` | correction and snippet behaviour | `MurmurDictionary` |
| `formatting-test-vectors.json` | retraction, spoken commands, lists, email shape, caret continuation, and the polish guard | `MurmurFormatting` |

Both implementations run them in CI. If you change how any of it works, change the vectors
first, watch both sides go red, then make them green. Changing one implementation to "fix"
a failing vector without changing the other is how the two silently diverge — and only one
of them can be exercised by hand.

```bash
make test                                 # macOS side; copies the vectors, then runs both suites
cd windows && dotnet test Murmur.sln      # Windows side
```

The copies under `Tests/` are copies, and CI fails if either drifts from `shared/`. `make
test` copies them for you; `make vectors` does it alone.

**There is no Xcode on a machine with only Command Line Tools**, and swift-testing's
`Testing` module ships with Xcode — so `swift test` fails to compile with "no such module
'Testing'" and always has, for the dictionary suite too. That is an environment gap, not a
broken test. To exercise `MurmurFormatting` without Xcode, compile it with a throwaway
`main.swift` that decodes the vectors and calls `StructurePass` directly; the module is pure
Foundation and links in about a second.

---

## Things that look like bugs and are not

**`swift build` fails with "input file was modified during the build."** The repo lives in an
iCloud-synced folder and the sync engine touches files mid-compile. **Always build with
`make`**, which uses `--scratch-path` outside the synced tree. A bare `swift build` also
writes a `.build/` directory into iCloud, which makes every subsequent build minutes slower.
If you see this error, wait a few seconds and retry.

**Compare mode doesn't type anything.** By design — `Settings.compareMode` runs every engine
on one recording and shows them side by side. If both injected, two transcripts would fight
over one text field. This is the single most confusing behaviour in the app.

**The timing column isn't comparing like with like.** Apple and Parakeet are timed on local
compute with the clock started *after* model load. Wispr Flow's number is its own
`e2eLatency`, which includes a network round trip and its cleanup pass. Don't present them
as one ranking.

**`MainActor.assumeIsolated` will crash the process.** It does not check the claim, it
asserts it. Use `await MainActor.run` from any non-main-actor context. This took the app
down once already.

**Mutating `@State` inside a `Canvas` draw closure floods the log and corrupts state.** The
VU meter keeps its needle physics in a plain reference type the view merely holds, which is
invisible to SwiftUI's state graph. Don't "clean that up" into `@State`.

**`isPlausibleCleanup` strips list markers before it compares words.** It has to. That guard
rejects any output containing a word absent from the input, and it counts digits as words —
so "first, buy milk, second, call the bank" cleaned into `1. Buy milk` / `2. Call the bank`
reads as two invented words. Without the strip, the pass whose own prompt asks for formatted
lists rejects every list it produces, silently, and falls back to the rule-based pass.

**The polish pass has its own guard and must keep it.** `PolishGuard`, not
`isPlausibleCleanup`. Repair is allowed to change words — "me and him goes" becomes "he and I
went" — so the cleanup guard rejects every successful repair. `PolishGuard` inverts the
question: it checks what must *survive* (every digit in order, every name, every URL, path
and identifier verbatim, and a length band).

**`ListMarkerStyle` is not called `ListStyle`.** SwiftUI has a protocol of that name, and any
view file that imports `MurmurFormatting` fails with "ambiguous for type lookup". Renaming it
back costs an hour.

**`FieldHarvester` refuses to read its own process, like `ScreenHarvester`.** Same trap, same
crash: Accessibility against this process builds the tree synchronously on the calling
thread, evaluating SwiftUI bodies off the main actor. Reachable from the Record button.

---

## Design system

`Sources/Murmur/UI/DesignSystem.swift` defines every colour, size, radius, duration
and material token. **Views must not contain literal values.** If a component needs a number
that isn't a token, add the token rather than inlining it.

The direction is quiet, modern macOS: flat surfaces, one hairline border, generous radii, a
single indigo accent, and type doing most of the work. Four rules:

- **One accent.** Indigo. Selection, focus and the level meter all borrow it.
- **Red means recording.** Nothing else in the app is red.
- **Amber is instrumentation only** — the top of a level meter, never UI chrome.
- **Two surfaces per screen at most.** A card inside a card inside a well is how a clean
  layout turns to mud.

Depth comes from a soft shadow and a change of surface — a card is lighter than its backdrop,
a well is darker. Explicitly ruled out: bevels, gloss, inner glows, brushed-metal grain,
neon, and decorative gradients. The only gradient in the app is the HUD waveform.

> This replaced an earlier skeuomorphic system modelled on 1980s field recorders. The
> component names in `Equipment.swift` — `BrushedPanel`, `Silkscreen`, `TransportKey`,
> `VUMeter`, `Well`, `DeckWindow` — are inherited from it and kept deliberately: every call
> site in the app spells them, and renaming twenty views changes nothing a user can see.
> Read them as "card", "small label", "button", "level meter", "recessed region", "row".

---

## macOS specifics

**Code signing is load-bearing, not cosmetic.** TCC stores a code-signing *requirement* per
entry, not just a path. An ad-hoc signature changes every build, so the rebuilt binary stops
satisfying the stored requirement — and the symptom lies: the Accessibility toggle still
shows as **on** while the app is untrusted. The `Makefile` auto-detects a Developer ID via
`security find-identity`. Don't replace that with `--sign -`.

If a grant does get wedged, reset that one row — never toggle, and never omit the bundle ID:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur
```

A bare `tccutil reset Accessibility` wipes every app on the machine. Then quit System
Settings entirely (⌘Q) before reopening; the Privacy pane caches its list.

**`log` may be shadowed in the user's shell.** Use `/usr/bin/log` explicitly.

**Don't run the `.app` from the repo folder.** It's iCloud-synced and the sync engine can
corrupt the signature. `make install` puts the running copy in `/Applications`.

---

## Windows specifics

Everything here was researched and verified but **never run on Windows.** Treat the specifics
as load-bearing; they were expensive to establish. Full detail in `windows/README.md` and
`docs/PARAKEET-WINDOWS.md`.

**Three pinned versions that break silently at "latest":**

| Package | Pin | Why |
|---|---|---|
| `NAudio` | 2.3.0 | 3.x targets .NET 9+ and will not restore |
| `Avalonia.Headless.XUnit` | 11.3.20 | 12.x requires xUnit **v3**, a different package line |
| `org.k2fsa.sherpa.onnx` | 1.13.5 | Bundles ONNX Runtime — never also reference `Microsoft.ML.OnnxRuntime` |

**Right Alt is AltGr** on German, Polish, UK, Nordic and most Latin-American layouts. Binding
push-to-talk there — and especially suppressing it — breaks typing `@`, `€`, `\`, `|` for
those users. Default is **Right Ctrl**, and the hook **observes without swallowing**: if the
key-down is swallowed and the key-up escapes, the target app believes Ctrl is held forever.

**UI Automation cannot inject text.** `TextPattern` is documented read-only and
`ValuePattern` replaces a whole field rather than inserting at the caret. `SendInput` is the
primary path, not a fallback.

**Keep `Murmur.Platform.Windows` logic-free.** Anything living there is code CI cannot
exercise. Retries, debouncing and device-change handling belong in the platform-neutral
projects behind an interface — those target plain `net10.0`, so `CA1416` turns any accidental
Win32 call into a build error.

**CI is the only place the Windows code is compiled.** Warnings are errors and the analyzers
are strict on purpose. `--no-incremental` is mandatory: Roslyn does not re-emit analyzer
warnings on a cached build, so without it the gate proves nothing.

---

## The structure pass

`MurmurFormatting` runs in two halves, on either side of cleanup, and the split is
load-bearing:

- **`preClean`** — retraction and spoken commands, on the raw transcript. These need the
  words exactly as spoken; a cleanup model asked to tidy "scratch that" tidies it into prose.
- **`structure`** — lists, email shape, terminal punctuation and the join onto text already
  in the field, on the cleaned transcript. These need the punctuation and capitalization that
  cleanup produces.

Move a rule across that line and it stops working, quietly.

Three deliberate absences, each of which looks like an oversight:

- **Retraction alignment is capped at four words, and the cap is the whole rule.** A repair
  swaps a phrase ("at 4, no wait at 3"); a restatement replaces a clause ("we should ship the
  beta, no wait, the beta is not ready"). Both repeat a word, and only the length separates
  them — align on the second one and you get "ship the beta is not ready". Raise the cap and
  that is the failure you get back.
- **Retraction still has no bare "I meant".** Alignment makes it usable rather than
  destructive, but "I meant" is ordinary English in a way "scratch that" is not, and the
  cleanup model already applies spoken self-corrections when it runs.
- **Alignment never crosses a sentence boundary, in either direction.** That one constraint
  is what keeps it from colliding with the filler back-off: a retraction that is a sentence
  of its own ("Actually no, scratch that.") has nothing in its own sentence to align against,
  so it falls through to scope — which is the right answer for it. Widen the search and the
  two mechanisms start fighting over the same utterance.
- **No bare "comma", "period" or "dash" commands.** They are ordinary English. A dictation
  tool that cannot type the word "dash" is worse than one that needs "em dash".
- **List inference requires a cue at a clause boundary, a sequence starting at one, and two
  items.** All three exist to stop "the first thing I noticed" becoming a list. Relax any of
  them and ordinary sentences start turning into lists.

Everything here is deterministic and runs whether or not the on-device model is available.
That is the point: `smartCleanup` is off by default and needs hardware not every Mac has, so
a feature built only on top of it doesn't exist for most users.

## Regex, if you touch the dictionary or the structure pass

The two engines are not identical. Measured across 30 cases, **9 diverged**. Two affect this
code and are handled — don't remove either:

- `RegexOptions.CultureInvariant` on the C# side, or Turkish `İ` matches `i`.
- **NFC normalization on both sides.** macOS returns decomposed strings, so without it an
  accented trigger silently never fires.

Two more are unfixable and simply avoided: ICU folds `ß` to `ss` and .NET doesn't; .NET's `.`
splits surrogate pairs. Stay inside the safe subset — `\b`, `\d`, `\w`, `\s`, character
classes, greedy/lazy quantifiers, alternation, `(?<name>…)`, fixed-length lookbehind,
lookahead, `\p{L}`, and `$1`–`$9` in replacements. Nothing else.

---

## What isn't built

1. **The whole Windows platform layer** — audio, hotkey, injection, UI.
2. **Command Mode** — select text, hold a second key, "make this more formal."
3. **Onboarding** — a first-run window walking through both macOS permissions.
4. **Notarization** — signing works; notarization would end the Gatekeeper warning.

And one thing CI structurally cannot verify on either platform: **text injection into a
foreground application.** GitHub runners have an interactive desktop but cannot take the
foreground. That needs a real machine and a human.
