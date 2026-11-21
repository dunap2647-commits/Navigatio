# 🧭 Navigatio `[BETA]`

![Status](https://shields.io)
![iOS](https://shields.io)
![Jailbreak](https://shields.io)
![Arch](https://shields.io)

> ⚠️ **Warning: Early Beta Release (v0.1.0-beta).** This project is under active development and testing. Bugs in network routing or UI may occur. Having SSH access or a terminal emulator (such as NewTerm 2) installed on your device is strongly recommended in case manual route restoration is needed.

**Navigatio** is a lightweight anti-DPI proxy client and traffic router (inspired by Happ) built specifically for **jailbroken iOS 12.0 – 12.5.7** devices (`arm64`, A7–A11 chips).

Unlike standard App Store VPN clients that are strictly capped by `NetworkExtension` memory limits (15–50 MB) and frequently crash on legacy 1GB–2GB RAM iPhones, **Navigatio** runs its proxy core as a background `root` LaunchDaemon. This allows modern **sing-box** or **Xray-core** engines with full **VLESS + Reality** and **Hysteria2** support to run smoothly without out-of-memory (OOM) kills.

---

## ✨ Key Features

* **Modern Protocols:** Supports VLESS (XTLS-Reality, Vision), VMess, Trojan, Hysteria2, and Shadowsocks powered by `sing-box` or `Xray-core`.
* **No Memory Ceiling (No OOM Crashes):** Runs the core binary as a system `LaunchDaemon` under `root`, completely bypassing `PacketTunnelProvider` sandbox limits.
* **Flexible Subscription Import:**
  * Direct **JSON profile URLs** with automatic `User-Agent` spoofing for panel compatibility.
  * Legacy Base64 subscription feeds and raw URI links (`vless://`, `vmess://`, `trojan://`, `hy2://`, `ss://`).
  * Displays remaining bandwidth and expiration metadata via `Subscription-Userinfo` headers.
* **Multi-Threaded Latency Testing:** Concurrent batch server ping (raw TCP handshake and real HTTP/TLS delay probes through the tunnel) with concurrency throttling to prevent CPU spikes on older devices.
* **Automatic Network Rollback:** Cleanly restores the system routing table (`route`) and DNS settings upon disconnect, daemon crash, or `SIGTERM` so your device never loses internet access.

---

## 🏗 Architecture

The project is split into three decoupled components:

```text
navigatio/
├── common/     # Shared IPC protocol (UNIX domain socket + length-prefixed framing) in C / ObjC
├── daemon/     # Background root daemon navigatiod (core supervisor, utun, tun2socks, route/DNS)
├── app/        # Lightweight native UIKit frontend running as mobile
└── layout/     # Debian package layout (LaunchDaemon plist, postinst/postrm, core binaries)
```

1. **Frontend App (`Navigatio.app`):** Runs unprivileged as `mobile`, fetches subscriptions, parses configurations, and communicates with the daemon over `/var/run/navigatiod.sock` (authenticated via `getpeereid()`).
2. **Backend Daemon (`navigatiod`):** Runs as `root`, creates a `utun` virtual network interface, supervises the proxy core and `tun2socks`, and excludes the upstream proxy server IP from the tunnel to prevent routing loops.

---

## 📱 Requirements

* **OS:** iOS 12.0 – 12.5.7
* **Jailbreak:** Rootful (Chimera, unc0ver, checkra1n)
* **Architecture:** `arm64` (iPhone 5s, 6, 6 Plus, 6s, 6s Plus, SE 1st Gen, 7, 7 Plus, 8, 8 Plus, X, iPad Air 1/2, iPad mini 2/3/4)

---

## 🛠 Building from Source (Theos)

Building the `.deb` package requires **Theos** (on macOS, Linux, or Windows WSL2) and an iOS SDK.

### 1. Bundle Core Binaries
Place your `arm64` (iOS 12 compatible) proxy core and `tun2socks` binaries into the `layout` directory:
```text
layout/usr/local/lib/navigatio/bin/sing-box   (or xray)
layout/usr/local/lib/navigatio/bin/tun2socks
```
Ensure they are executable:
```bash
chmod +x layout/usr/local/lib/navigatio/bin/*
```

### 2. Compile the Package
```bash
git clone https://github.com
cd navigatio
make clean && make package
```
The compiled `.deb` package will be generated inside the `packages/` directory.

### 3. Install on Device
Transfer the `.deb` file to your iOS device and install it via **Filza**, **Sileo**, or **Zebra**, or install over SSH:
```bash
dpkg -i packages/com.navigatio.proxy_*.deb
```

---

## 📋 Roadmap
- [x] IPC framing protocol & root `LaunchDaemon` (`navigatiod`)
- [x] `utun` interface management, `tun2socks` integration, and route/DNS auto-rollback
- [ ] Native UIKit frontend (`Navigatio.app`)
- [ ] JSON/Base64 subscription parser and batch latency tester in UI

---

## ⚠️ Disclaimer

This project is intended for educational and research purposes to extend the usability of legacy Apple hardware and explore iOS network routing.
