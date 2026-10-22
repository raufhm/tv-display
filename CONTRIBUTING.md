# Contributing to TV Display

Thanks for helping. Bug reports, test results from other TVs and pull requests are all welcome.

## The easiest way to help: test your TV

Every TV has a different video chip, and that's where most problems come from. If you try TV Display on a TV we haven't seen, please [open a TV report](https://github.com/raufhm/tv-display/issues/new?template=tv_report.yml), whether it worked or not. Include the stats line from the Mac log:

```bash
tail -5 ~/Library/Logs/tvdisplay.log
```

It looks like `55 fps · 2.1 Mbps · 66 ms  (TV shown 55/s, paced 8)`.

## Project layout

| Folder | What it is |
|---|---|
| `mac/` | Menu-bar app (Swift). `Stream.swift` has the virtual display, capture, encoder and network link; `AudioTap.swift` sends sound to the TV; `main.swift` is the menu UI. |
| `tv/` | Android TV receiver (Java, a single `MainActivity`). |
| `art/` | `make-icons.swift` draws every icon from one design. |
| `site/` | The landing page, deployed on Vercel from `main`. |

The wire format between the two apps is described in the [README](README.md#how-it-works). If you change it, change both sides in the same pull request.

## Building

**Mac:** needs the Xcode Command Line Tools.

```bash
cd mac && ./build.sh run
```

**TV:** needs the Android SDK (build-tools 35.0.0, platform android-34) and a JDK.

```bash
cd tv && TV=<tv-ip> ./build.sh install
```

The TV must have network debugging on and must have authorised your computer for adb once. The first build creates `tv/signing.keystore`. It's ignored by git; never commit it.

## Ground rules

These keep the project small and easy for anyone to build:

- **No libraries in the TV app.** Plain Android SDK only. It runs on weak TV hardware and is under 100 KB.
- **No Xcode or Gradle projects.** Both apps build with their `build.sh` and standard command-line tools.
- **Measure latency changes.** If a change could affect speed, include the stats line before and after, and say which Mac and TV you tested on.
- **Keep the Mac app's permissions minimal.** Don't add new permissions or network destinations without discussing them in an issue first.

## Pull requests

1. For anything bigger than a small fix, open an issue first so we can agree on the approach.
2. Keep each pull request to one change.
3. Make sure both apps still build. GitHub Actions checks this automatically on every pull request.
4. Fill in the pull request template, including what you tested on.

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind.
