# PingDot

[Русская версия](README.ru.md)

A tiny macOS menu bar app that shows the state of your internet connection as a colored dot. Every 2 seconds it pings 8.8.8.8 and 1.1.1.1 — plain ICMP, no `sudo` needed.

| Dot | Meaning |
|:--:|---|
| 🟢 | All good |
| 🟡 | Unstable: over the last ~30 s packet loss ≥ 10%, median ping ≥ 150 ms or jitter ≥ 50 ms — or the latest ping got no reply |
| 🔴 | No host replied 3 times in a row, or the Mac isn't connected to any network |
| ⚪ | No data yet: the first seconds after launch, a network change or waking from sleep |

Packet loss is counted across all responding hosts (that's the loss on your own link), while ping and jitter come from the best host. A host that doesn't answer at all (e.g. blocked on your network) is simply ignored.

When the connection drops, the dot turns yellow within 1.5–3.5 s and red within 5.5–7.5 s. After recovery it stays yellow for ~25 s, until the losses leave the statistics window.

Click the dot for details: overall status and, per host, the latest ping, median, jitter and loss. There are also toggles to show the ping next to the dot (fixed width, so neighbouring menu bar icons don't jump) and to launch at login.

Requires macOS 13 Ventura or later. Universal binary (Apple Silicon + Intel). The interface is in Russian.

## Install

1. Download `PingDot.zip` from [Releases](../../releases/latest), unzip it and move `PingDot.app` to Applications.
2. The app is ad-hoc signed, not notarized by Apple, so macOS blocks the first launch. Allow it once:
   - **macOS 15 Sequoia and later:** try to open the app and dismiss the warning, then go to System Settings → Privacy & Security and click **Open Anyway**.
   - **macOS 13–14:** right-click the app → Open → Open.
   - **Any version, from Terminal:** `xattr -dr com.apple.quarantine /Applications/PingDot.app`

## Build from source

Only the Command Line Tools are needed, not full Xcode:

```sh
xcode-select --install      # if not installed yet
./build.sh                  # → build/PingDot.app
./build.sh install          # build, copy to /Applications and launch
ARCHS=arm64 ./build.sh      # Apple Silicon only (default is universal)
```

Test pinging from Terminal — three pings per host:

```sh
build/PingDot.app/Contents/MacOS/PingDot --check
```

## Configuration

Everything lives in [`Sources/Config.swift`](Sources/Config.swift): hosts, polling interval, timeout, statistics window and the yellow/red thresholds. Change it and run `./build.sh install`.

## How it works

- [`Pinger.swift`](Sources/Pinger.swift) — ICMP Echo over an unprivileged `SOCK_DGRAM` + `IPPROTO_ICMP` socket (macOS allows it without root): builds the packet and checksum, filters its own replies, measures round-trip time.
- [`Monitor.swift`](Sources/Monitor.swift) — polls every 2 s, keeps per-host statistics, decides the color; resets on network changes (`NWPathMonitor`) and after sleep.
- [`StatusBarController.swift`](Sources/StatusBarController.swift) — the dot, the menu, launch at login (`SMAppService`).
- [`App.swift`](Sources/App.swift) — entry point and the `--check` mode.

## Releases

GitHub Actions builds the app on every push. To publish a release, push a version tag:

```sh
git tag v1.1
git push origin v1.1
```

The workflow sets the app version from the tag and attaches `PingDot.zip` to a new release.

## Troubleshooting

- **The dot isn't visible** — on MacBooks with a notch, icons that don't fit hide behind it. Hold ⌘ and drag PingDot to the right, closer to the clock.
- **Launch at login stopped working after a rebuild** — turn the toggle off and on again.
- **Red while the internet works** — your network blocks ICMP (some office and guest networks do). PingDot would need a TCP-based check there.

## License

[MIT](LICENSE)
