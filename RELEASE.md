# Releasing, and the website

**Releasing is one act: changing `CFBundleShortVersionString` in `Resources/Info.plist`.**
Everything else follows from that automatically.

```sh
./release.sh
```

That is the whole procedure. The rest of this file explains what it does, so that when
something goes wrong you are not reading a black box.

---

## How it works

Releases are driven by the **version**, not by tags you push.

Every push to `main` runs `.github/workflows/release.yml`, which asks one question: *does a
tag `v<version-in-Info.plist>` already exist?*

* **It exists** — this version is already published. The workflow stops after about fifteen
  seconds on a Linux runner. Push as often as you like; a website tweak does not cost a
  full macOS build.
* **It does not exist** — this is a new version. The workflow runs the dictionary contract,
  builds the app and the DMG on a clean macOS 26 runner, tags the commit, and publishes a
  GitHub release with the DMG attached.

So the *tag is created by CI*, never locally. That is deliberate: one mechanism, in one
place. A release cannot half-happen because a tag went up without a build, or a build ran
against a commit nobody tagged.

It also means the version bump *is* the release, wherever you make it — the script, your
editor, or GitHub's web UI. `release.sh` is a safe front door to that, not a separate
mechanism.

```
./release.sh ──> bump Info.plist ──> commit ──> push
                                                 │
                                                 ▼
                                  workflow: is v0.2.0 tagged?
                                      no ──> test, build DMG,
                                             tag v0.2.0, publish
                                     yes ──> stop, nothing to do
```

## Why the version lives in `Info.plist`

Because that is where macOS already reads it from. A second file holding a version number
is how a DMG ends up named after a version the app inside it does not report — so there
isn't one. The `Makefile` reads it (`make -s print-dmg` uses it), the workflow reads it,
and the release job **fails the build** if the app it just compiled disagrees with the tag
it is about to create.

`CFBundleVersion` is a different number: the build, not the marketing version. CI stamps it
with the workflow run number, so any DMG in the wild can be traced back to the run that
produced it. A local `make app` leaves it at `1`.

## What `./release.sh` does

1. **Refuses to start** if you are not on `main`, the working tree is dirty, or
   `origin/main` has commits you do not. A dirty tree matters more than it sounds: whatever
   is lying around would be swept into the release commit and shipped inside the download.
2. **Runs `make test`** — the shared dictionary vectors. A failure stops everything, before
   anything is changed.
3. **Asks what kind of bump** — patch, minor or major — showing the resulting version for
   each. Pass `patch`, `minor` or `major` as an argument to skip the question.
4. **Refuses** if the resulting tag already exists, because CI would silently do nothing and
   you would be watching an Actions tab where nothing happens.
5. Sets `CFBundleShortVersionString`, commits `release: vX.Y.Z`, pushes.
6. **Watches the build** and prints the download URL when it lands.

```sh
./release.sh                 # ask what to bump
./release.sh patch           # skip the question
./release.sh minor --dry-run # show what would happen, change nothing
```

## What CI does

`.github/workflows/release.yml`, on `macos-26` — that runner specifically, because
`Package.swift` declares `.macOS(.v26)` and both `SpeechAnalyzer` and `FoundationModels`
are macOS 26 SDK. It is also Apple silicon, which the DMG has to be.

1. Selects the newest Xcode on the image rather than pinning one that will age out
2. `make test` — the dictionary contract, the same vectors the Windows side runs
3. `make dmg CONFIG=release BUILD_NUMBER=<run number>`
4. **Verifies the bundle** — three things that have each been wrong before and are silent
   when they are:
   - `codesign --verify --deep --strict` (an unverifiable bundle does not launch at all)
   - the executable is `arm64` (an x86_64 build looks fine until Parakeet has no Neural
     Engine to run on)
   - the built app's version matches the tag about to be created
5. Tags the commit and publishes the release with `Murmur-arm64.dmg` attached

### The asset name never changes

`Murmur-arm64.dmg`, with no version in it, in every release. That is what makes

```
https://github.com/rohitshidid/murmur/releases/latest/download/Murmur-arm64.dmg
```

resolve — GitHub redirects `latest` server-side. The website's Download buttons point at
that URL, so **the site never needs rebuilding when you release**. The version lives in the
volume name and in the app.

## The website

`docs/` is the GitHub Pages source, served at
<https://rohitshidid.github.io/murmur/>. Set it once, in
**Settings → Pages → Source: Deploy from a branch → `main` / `docs`**.

There is no build step and no deploy workflow: pushing `docs/index.html` to `main` *is* the
deploy. `docs/.nojekyll` stops GitHub running Jekyll over it, and `docs/icon.png` is copied
from `Resources/AppIcon.iconset/icon_512x512.png` — regenerate it after `make icon` if the
mark ever changes:

```sh
make icon
cp Resources/AppIcon.iconset/icon_512x512.png docs/icon.png
```

The features section is hand-written and does not read from the app, so **a feature that
ships without a block there is a feature nobody finds.** It is the one part of the site that
goes stale silently — the version in the hero fixes itself, the download link resolves
server-side, and this doesn't.

The page's colour tokens are the app's own, lifted from
`Sources/Murmur/UI/DesignSystem.swift` and `Tools/makeicon.swift`. Change the accent in one
and change it in the other.

The version shown in the hero is fetched from the GitHub releases API at page load and is
**progressive enhancement only** — if that request is rate-limited or fails, the static text
stays and every download link still works, because they resolve server-side.

## Unsigned builds, and what that costs

CI has no Developer ID certificate, so `make app` falls back to ad-hoc signing. Two
consequences, both stated plainly on the website and in the release notes:

- macOS refuses the first launch. Right-click → **Open** → **Open**, once per install.
- An ad-hoc signature differs on every build, and TCC ties the Accessibility grant to the
  *code-signing requirement* — so **updating requires re-granting Accessibility**. The
  symptom is nasty: the toggle still reads as on while the app is reported untrusted.
  Remove the row and add it back; toggling does not fix it.

To end both: add a Developer ID certificate (`.p12` plus its password) and an App Store
Connect API key as repository secrets, import the cert into a temporary keychain in the
release job, and add a `notarytool submit --wait` plus `xcrun stapler staple` step after
`make dmg`. The `Makefile` already prefers a real identity whenever
`security find-identity` finds one, so a signed CI build needs no change to it — only the
keychain setup in the workflow.

## When a release goes wrong

Nothing needs rolling back. `Info.plist` is already at the new version and the commit is
pushed, so once the problem is fixed, push the fix — CI notices `vX.Y.Z` still has no tag
and builds it again.

```sh
gh run view <run-id> --log-failed
```

To rebuild and republish a version that *is* already tagged, run the workflow manually from
the Actions tab with **force** ticked.
