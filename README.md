# FakeIt

**FakeIt** is a native **macOS** app for **developers and QA**: pick a point on a map (or search for a place) and **simulate GPS location** on a **USB‑connected iPhone** using Apple’s developer tooling and [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3).

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014+-000000?logo=apple&logoColor=white" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Swift-5.0-F05138?logo=swift&logoColor=white" alt="Swift 5" />
  <img src="https://img.shields.io/badge/Xcode-15%2B-007ACC?logo=xcode&logoColor=white" alt="Xcode 15+" />
</p>

---

## Features

- **Map-first workflow** — MapKit map, drop a pin, search (MKLocalSearch–style completions), optional coordinate entry.
- **Device picker** — Lists physical iPhones from `xcrun xctrace list devices` (Xcode Command Line Tools).
- **iOS version–aware paths** — Uses the appropriate developer location simulation path for **iOS 17+** vs older releases.
- **Tunnel helper** — Can manage **`pymobiledevice3 remote tunneld`** for iOS 17+ USB tunneling when needed (with clear in-app notices if something fails).
- **Location hold** — Long‑running Python bridge process keeps simulation active until you clear or change target.
- **Recent locations** — Lightweight on-disk history for quick re-use.

---

## Requirements

| Requirement | Notes |
|-------------|--------|
| **macOS 14+** | Matches project deployment target. |
| **Xcode** (15+) | For building; **Xcode Command Line Tools** for `xcrun` / device discovery. |
| **iPhone** | USB; **trusted** on the Mac; **Developer Mode** enabled where applicable. |
| **Python 3** + **`pymobiledevice3` ≥ 9** | The app looks for a working `python3` with `pymobiledevice3` installed (see [Setup](#setup)). |

Apple developer pairing, Developer Disk Image, and device trust behave the same as any other DVT / Core Device workflow—resolve those in Xcode’s **Devices** window if simulation fails.

---

## Setup

### 1. Clone

```bash
git clone https://github.com/mzian455/FakeIt.git
cd FakeIt
```

### 2. Python dependency

Install on the Mac that will run FakeIt (system or venv):

```bash
pip3 install -r requirements.txt
```

The app may also use a support-directory venv it creates under your user library; having `pymobiledevice3` available globally or via Homebrew Python avoids surprises.

### 3. Build & run (Xcode)

Open `FakeIt.xcodeproj`, select the **FakeIt** scheme, **Run** (⌘R).

Or from the terminal:

```bash
xcodebuild -scheme FakeIt -configuration Debug -derivedDataPath ./build/DerivedData build
open ./build/DerivedData/Build/Products/Debug/FakeIt.app
```

### iOS 17+ and `tunneld`

Location simulation on **iOS 17+** typically depends on **remote tunneling**. FakeIt tries to start `tunneld` when appropriate. If you hit permission or port issues, run the app once with elevated privileges **or** start tunneld manually, for example:

```bash
sudo python3 -m pymobiledevice3 remote tunneld
```

See in-app banners and logs under FakeIt’s app support folder (`tunneld.log`) for details.

---

## Repository layout

```
FakeIt/
├── FakeIt.xcodeproj/          # Xcode project & shared scheme
├── FakeIt/
│   ├── *.swift                # SwiftUI + MapKit UI, device service, bridge orchestration
│   ├── fakeit_location_bridge.py   # Bundled bridge (async pymobiledevice3 / DVT location)
│   ├── backend/               # Alternate / modular Python reference (not wired in Xcode target)
│   ├── Assets.xcassets/       # App icon, colors
│   └── Fonts/                 # Orbitron variable font (UI branding)
├── requirements.txt           # Python deps for the bridge
└── README.md
```

---

## Disclaimer

FakeIt is intended **only for legitimate development and testing** on **devices you own or are authorized to test**. Misusing simulated location may violate app terms, local laws, or platform policies. **You are responsible** for how you use this tool.

---

## Third-party assets

- **[Orbitron](https://fonts.google.com/specimen/Orbitron)** (UI title) — licensed under the [SIL Open Font License 1.1](https://openfontlicense.org/open-font-license-official-text/).
- **pymobiledevice3** — see its repository for license terms.

---

## License

This project’s **source code** (Swift, project files, and bundled scripts authored for FakeIt) is released under the **MIT License** — see [`LICENSE`](LICENSE).

The **app icon** and any **third-party fonts** in `Assets.xcassets` / `Fonts/` remain subject to their respective licenses and are not necessarily MIT unless you hold those rights.

---

## Contributing

Issues and pull requests are welcome. Please keep changes focused, match existing Swift style, and test against a real device on at least one iOS major version you care about (e.g. 17+).

---

<p align="center">
  <sub>Repository: <a href="https://github.com/mzian455/FakeIt">github.com/mzian455/FakeIt</a></sub>
</p>
