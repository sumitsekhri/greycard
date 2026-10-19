# Greycard

A Mac menu bar app to quickly change your display colour, warmth and brightness configuration. Its main job is switching an Apple display into the **Photography** reference preset with True Tone locked off, so colours are accurate for photo and video editing.

Requires macOS 14 or later. It has four parts:

- **Warmth slider.** Sets colour temperature in Kelvin, like f.lux. It runs from 1900K (Candle) to 10000K, and 6500K is neutral. There are quick stops for Candle, Halogen, Fluorescent and Daylight. Moving the slider turns warmth on.
- **Presets.** These are the same presets your display offers in System Settings › Displays (Photography, Internet & Web, and so on).
- **Brightness-lock handling.** Some presets fix brightness, such as Photography; macOS then greys out the brightness slider. While such a preset is active:
  - True Tone is forced off and its toggle is disabled. If True Tone gets turned back on (from Control Centre, say), the app turns it off again within about 2 seconds.
  - When you switch to a preset that doesn't lock brightness, True Tone goes back to how you had it.
  - Optional: tick *Locked presets also block warmth & Night Shift* to pause those too. This is recommended if you use Photography for editing.
- **Profiles.** Each profile saves a preset, True Tone, Night Shift and warmth together, and applies them with one click.

## Install: option A, build on the Mac (recommended)

```zsh
xcode-select --install        # one-time and free; skip if already installed
cd ~/Downloads/Greycard
./build-app.sh --install      # builds, copies to /Applications, launches
```

This also produces `build/Greycard.dmg`, a normal drag-to-Applications installer you can keep or copy to another Mac. Apps built on your own Mac open without any Gatekeeper prompt.

## Install: option B, let GitHub build it (no developer tools on your Mac)

1. Push this folder to a GitHub repo. The workflow in `.github/workflows/build.yml` runs on GitHub's macOS machines.
2. Open the **Actions** tab, then the latest run, and download **Greycard-dmg**.
3. Open the DMG and drag the app onto Applications.
4. On first launch macOS blocks it because it isn't notarized. Click **Done**, then go to **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. This is only needed once.

## Launch at login

Tick **Launch at login** at the bottom of the menu.

## First run: diagnostics (changes nothing)

```zsh
"build/Greycard.app/Contents/MacOS/Greycard" --doctor
```

Run it **twice**: once with your normal preset active, and once with Photography selected in System Settings. Each run shows:

- every preset your display offers
- whether macOS reports brightness as adjustable
- whether the app detects a brightness lock
- the raw keys of the active preset

If auto-detection gets a preset wrong, either set the **Brightness lock** picker in the menu to *Always locked* or *Never locked* (it is remembered per preset), or send the doctor output so the detection can be tuned.

## Trigger from Shortcuts, Raycast, Stream Deck or Terminal

```zsh
open "greycard://apply?name=Photography"
open "greycard://warmth?k=3400"
open "greycard://warmth?off"
```

In Shortcuts, use the **Open URLs** action.

## Caveats

- **Private APIs.** Preset switching, the brightness-lock check, True Tone and Night Shift use undocumented macOS functions. A macOS update can break them, so re-run `--doctor` after updates. Warmth uses public APIs.
- **Warmth on a Photography preset.** Warmth on top of Photography defeats its colour accuracy. That's why the blocking option exists.
- **Warmth after sleep or wake.** macOS can reset the warmth curve on sleep or wake. The app re-applies it within about 2 seconds.
