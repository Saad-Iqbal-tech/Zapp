# 5-Player Line-of-Sight Survival Arena (ZAPP ARENA)

A 2.5D low-poly 3D mobile survival arena game built in **Godot 4.7** using GDScript. Up to five combatants battle on a shrinking floating square platform using strategic line-of-sight laser attacks that fire simultaneously at the end of each 5-second preparation countdown.

Supports both **Offline Local AI Mode** (`1 Human + 4 AI`) and **Authoritative Online Multiplayer** (`1–5 Humans + 0–4 Server AI`, Private Rooms with 5-character codes, Honest Public Matchmaking, and Persistent Server-Validated Statistics & Leaderboards).

---

## 1. Setup & Launching the Game

### Prerequisites
- **Godot Engine 4.x** (tested and verified with `Godot v4.7.2-stable_win64`).
- Renderer configured for **Forward Mobile (`mobile`)** with **Jolt Physics 3D** and touchscreen emulation enabled for desktop testing.

### Launching a Game Client
```powershell
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --path .
```

### Launching the Dedicated Headless Server (Development Computer)
You can launch the authoritative headless server in either of two ways (no window is rendered):

**Option A — Via `--server` CLI flag on the main project:**
```powershell
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -- --server --port=7777 --bind=0.0.0.0
```

**Option B — Via the dedicated runner script:**
```powershell
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://scripts/network/dedicated_server_runner.gd -- --port=7777 --bind=0.0.0.0
```

---

## 2. Local & Multi-Device Multiplayer Testing Guide

### How to Connect Two Local Game Clients to One Headless Server
1. Start the headless server in Terminal 1:
   ```powershell
   & "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -- --server --port=7777
   ```
2. Launch Client 1 in Terminal 2 and Client 2 in Terminal 3:
   ```powershell
   & "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --path .
   ```
3. On both clients, tap **ONLINE LOBBY** on the bottom-right of the Main Menu:
   - Leave **Server IP** as `127.0.0.1` and **Port** as `7777` (or tap **LAN IP** to toggle to your PC's detected local Wi-Fi IPv4 address for Android/LAN testing).
   - **Auto-Connect or Manual Connect**: You can tap **CONNECT** directly, or simply tap **CREATE PRIVATE ROOM**, **JOIN ROOM**, or **FIND PUBLIC MATCH** while `Disconnected`—the client will automatically connect to the configured Server IP/Port and execute your requested action as soon as the server handshake (`S2C_WELCOME`) completes.
   - **Public Matchmaking**: Tap **FIND PUBLIC MATCH** on both clients. Once 2 connected players are in the queue, the server launches the match automatically.
   - **Private Room**: On Client 1, tap **CREATE PRIVATE ROOM** and note the 5-character **Room Code** (e.g. `W3UG9`). Optionally configure the number of Human slots (`1..5`) and AI Fill (`0..4` bots). On Client 2, enter the 5-character code, tap **JOIN ROOM**, and tap **READY UP!**. On Client 1 (Host), tap **START MATCH!**.

### How to Test Across Two Different Devices (Android / LAN)
1. Connect your development computer (running the headless server) and your Android phone(s) or second computer to the same Wi-Fi / LAN network.
2. Find your development computer's local LAN IPv4 address (e.g., `ipconfig` on Windows -> `192.168.10.3`, or tap the **LAN IP** button in the Online Lobby on the host PC to view it).
3. Ensure Windows Defender Firewall allows inbound **UDP port `7777`** (see Section 3 below).
4. Export and install the Android APK (`export_presets.cfg` includes the Android preset with `INTERNET` and `ACCESS_NETWORK_STATE` permissions pre-enabled; requires Godot 4.7.2 export templates installed in the Godot Editor).
5. In the game's **ONLINE LOBBY**, enter your computer's LAN IP (`192.168.10.3`), keep Port `7777`, and tap **CONNECT** (or tap **CREATE PRIVATE ROOM** / **JOIN ROOM** / **FIND PUBLIC MATCH** to auto-connect). The configured Server IP and Port are saved automatically in `user://client_account.cfg`.

---

## 3. Network Ports, Firewall Rules & Internet Deployment

### Required Network Ports & Firewall Rules
- **Transport**: Godot `ENetMultiplayerPeer` over **UDP** (reliable channel `0` for lobby/match events, unreliable-ordered channel `1` for 20 Hz state snapshots and 25 Hz player inputs).
- **Default Port**: **`UDP 7777`** (inbound and outbound). TCP is not used by ENet.
- **Windows Firewall Rule (PowerShell as Administrator)**:
  ```powershell
  New-NetFirewallRule -DisplayName "Zapp Arena Server UDP 7777" -Direction Inbound -Protocol UDP -LocalPort 7777 -Action Allow
  ```
- **Linux (`ufw`) Firewall Rule**:
  ```bash
  sudo ufw allow 7777/udp
  ```

### Deploying the Dedicated Server to a Publicly Reachable Machine (Production)
1. **Provision a Linux VPS** (e.g., Ubuntu 22.04/24.04 on DigitalOcean, Hetzner, Linode, AWS Lightsail, or GCP e2-micro) with a static public IPv4 address.
2. **Export or Copy the Server**:
   - Either export the `Linux Dedicated Server` preset (`build/server/zapp_arena_server.x86_64` + `.pck`) or upload the project folder with the official Linux headless Godot 4.7.2 binary.
3. **Run Under `systemd`** so it restarts automatically on crash or reboot:
   ```ini
   [Unit]
   Description=Zapp Arena Authoritative Dedicated Server
   After=network.target

   [Service]
   Type=simple
   User=ubuntu
   WorkingDirectory=/opt/zapp-arena
   ExecStart=/opt/zapp-arena/Godot_v4.7.2-stable_linux.x86_64 --headless --path /opt/zapp-arena -- --server --port=7777 --bind=0.0.0.0
   Restart=on-failure
   RestartSec=3

   [Install]
   WantedBy=multi-user.target
   ```
4. **Settings to Change Between Local Testing and Production**:
   - **Client Default Server Host**: Change `NetProtocol.DEFAULT_HOST` in `scripts/network/net_protocol.gd` (or enter in the Online Lobby UI) from `"127.0.0.1"` to your server's public IPv4 address or DNS hostname.
   - **Server Bind Address**: Ensure `--bind=0.0.0.0` is used on the server (never `127.0.0.1` in production, which would only accept loopback connections).
   - **Matchmaking Minimum Humans**: `quick_match_required_players` in `DedicatedServer` defaults to `2` for easy two-player testing; for 5-player public lobbies, set `quick_match_required_players = 5` (or enable `quick_match_fill_with_ai = true`).

### Ongoing Hosting Costs & Limitations
- **Hosting Cost**: A single 1 vCPU / 1 GB RAM Linux VPS (~`$4–$6/month` on Hetzner/DigitalOcean/Lightsail) can comfortably host dozens of concurrent 5-player matches because headless Jolt 3D physics and 20 Hz compact snapshots (~400 bytes/packet) use minimal CPU and bandwidth (~8 KB/s per client).
- **Single-Node Persistence & Atomic Backup Recovery**: Player accounts, SHA-256 token hashes, statistics, match history, and leaderboards are stored in `user://server_persistence.json` on the dedicated server. Writes are performed atomically via `.tmp` staging files with a `.bak` backup copy so power loss or mid-write crashes cannot corrupt player stats; if the primary JSON is corrupted, `ServerPersistence` logs a warning (`last_load_error`) and automatically restores from `.bak`. Because persistence is stored on the single server node, horizontal multi-node scaling would require a shared database (e.g., PostgreSQL/Redis).
- **NAT / Carrier-Grade NAT**: Because clients connect outbound to the dedicated server's public UDP port (rather than peer-to-peer hosting), players behind mobile Carrier-Grade NAT (4G/5G) can play together without port forwarding on their phones.

---

## 4. Controls & Gameplay Rules

### Controls (Mobile Touchscreen First + Desktop Testing Mode)
- **Bottom-Left Virtual Joystick (`MOVE`)**: Touch and drag to move your character. Dynamic safe-area padding ensures full reachability without notch clipping.
- **Bottom-Right Aiming Control (`AIM`)**: Touch and drag to rotate your forward-facing torso attack line. Releasing preserves your last aimed direction.
- **Spectator Mode (`< PREV` / `NEXT >` / `MAIN MENU`)**: Automatically activates if you are eliminated while opponents remain alive, revealing all surviving players and following the selected survivor.
- **Settings Panel (`SETTINGS` / `Esc`)**: Adjust **Master Volume**, **Music Volume**, **Sound FX Volume**, **Camera Speed**, or **Mute All Audio**.

### Forced Mobile Landscape & Safe-Area Layout
- **Orientation**: Configured for `window/handheld/orientation=4` (`DisplayServer.SCREEN_SENSOR_LANDSCAPE`), strictly preventing portrait orientation while allowing seamless 180° device flip.
- **Multi-Aspect Ratio Support**: Canvas stretch mode is set to `canvas_items` + `expand` and the 3D camera uses `Camera3D.KEEP_HEIGHT`. Modern ultra-wide phones (18:9, 19.5:9, 20:9, 21:9) expand the horizontal field of view into the surrounding arena without distortion, letterboxing, or pillarboxing.
- **Notch & Cutout Safe Areas**: Controls dynamically inspect `DisplayServer.get_display_safe_area()`. The movement joystick, aiming pad, HUD countdown card, top-right settings button, and lobby panels automatically offset inward from physical cutouts, punch-holes, and system navigation bars.

### Google AdMob Integration & Placement Architecture
- **Plugin**: Powered by the official Poing Studios AdMob v5.1.0 Android plugin built for Godot 4.7.2.
- **Configuration Identifiers**:
  - **App ID**: `ca-app-pub-2206945025056752~4220096311` (configured in `project.godot` under `[admob]` and injected into `AndroidManifest.xml` via Gradle export).
  - **Production Interstitial Ad Unit ID**: `ca-app-pub-2206945025056752/7728096486` (configured in `[zapp_ads]`).
  - **Google Official Test Interstitial Unit ID**: `ca-app-pub-3940256099942544/1033173712` (used automatically in all development and debug builds).
- **Strict Break Gating**:
  - Interstitial ads are shown **only** at natural match breaks: after the match result overlay has been shown and the player taps **PLAY AGAIN** or returns to the **MAIN MENU**.
  - Interstitials are strictly prohibited and gated off during active gameplay, the 5-second countdown, aiming, laser shooting, matchmaking queues, lobby navigation, and room creation.
  - A frequency cap (`min_interval_sec = 75.0`) prevents ads from showing too frequently across quick matches.
  - If an ad fails to load or internet is unavailable, continuation callbacks fire immediately and the player proceeds with zero delay or freeze.
  - Headless servers and desktop builds initialize safely without native Android singletons or mock UI obstruction.

### Authoritative Gameplay & Anti-Cheat Architecture
- **5-Second Stealth Preparation Phase**: All living players are invincible during the 5-second countdown and opponents are hidden from each other.
- **Simultaneous Laser Resolution (`0.0s`)**: The server freezes movement/aiming, takes an atomic snapshot of all living players and active obstacle AABBs, and evaluates all unobstructed attack segments simultaneously. Two players hitting each other eliminate each other simultaneously.
- **Staged Shrinking Platform**: Shrinks in 4 stages (`100% -> 72% -> 45% -> 22%`) with a 4-second danger warning and falling outer tiles.
- **Server Authority & Anti-Cheat**:
  - Clients only send movement and aim vectors (`C2S_PLAYER_INPUT`), which the server sanitizes for `NaN`/`Inf`, clamps, and validates for strictly increasing sequence numbers (`seq > last_seq` and `seq >= 0`).
  - Clients cannot spoof eliminations, laser attacks, positions, timers, shrink stages, or match outcomes (`ERR_FORBIDDEN_CLIENT_AUTHORITY` / `ERR_FORBIDDEN_CLIENT_STATS`).
  - Unauthenticated room, matchmaking, or gameplay packets before `C2S_HELLO` are rejected (`ERR_UNAUTHENTICATED`).
  - Account tokens are validated (`NetProtocol.is_valid_token`), stored only as SHA-256 hashes, and enforced across room/queue actions so clients cannot impersonate another player's username after connecting.
  - Connecting a second client with the same account token evicts the stale duplicate connection (`ERR_DUPLICATE_IDENTITY`) so one player cannot occupy multiple slots.
  - Repeated invalid room code guesses trigger a brute-force lockout (`MAX_FAILED_JOIN_ATTEMPTS = 5` -> `ERR_RATE_LIMITED`), and oversized (`> 4096` bytes -> `ERR_PACKET_TOO_LARGE`), malformed (`ERR_MALFORMED_PACKET`), or flooded packets (`ERR_RATE_LIMITED`) are rejected.

---

## 5. Project Structure

```text
├── addons/
│   └── admob/                            # Poing Studios AdMob v5.1.0 plugin & Android AARs for Godot 4.7.2
├── assets/
│   └── low_poly_mesh_builder.gd          # Procedural low-poly 3D mesh builder
├── materials/                            # Arena tile, obstacle, and boundary materials
├── scenes/
│   ├── arena.tscn                        # Modular arena generator scene
│   ├── character.tscn                    # Reusable character scene
│   └── main_arena.tscn                   # Main match & lobby scene
├── scripts/
│   ├── ads/
│   │   └── admob_manager.gd              # AdMob lifecycle manager, frequency cap & break-gating coordinator
│   ├── network/
│   │   ├── dedicated_server.gd           # Authoritative ENet server (sessions, rooms, matchmaking, stats)
│   │   ├── dedicated_server_runner.gd    # Headless server SceneTree runner script
│   │   ├── multiplayer_client.gd         # Client ENet networking, input sender, and state receiver
│   │   ├── net_protocol.gd               # Shared packet types, constants, and input sanitizers
│   │   ├── online_lobby_modal.gd         # Online Hub, Private Room Lobby, and Stats/Leaderboard UI
│   │   ├── server_match_session.gd       # Authoritative server-side 5-player match simulation
│   │   └── server_persistence.gd         # Token-authenticated accounts, match history & leaderboard store
│   ├── ai_controller.gd                  # Fair line-of-sight AI controller (no wall-vision or stealth cheating)
│   ├── aim_line.gd                       # Torso laser visuals, obstacle blocking, and hit math
│   ├── arena_generator.gd                # 256-tile modular platform & 100/72/45/22% staged shrinking
│   ├── audio_manager.gd                  # Procedural synthwave BGM and laser/drop SFX
│   ├── camera_rig.gd                     # 75° arena camera, spectator zoom, and 3D lobby showcase camera
│   ├── character_controller.gd           # Movement physics, client interpolation, and character states
│   ├── character_visuals.gd              # Articulated 3D humanoid model & elimination FX
│   ├── hud_controller.gd                 # In-game HUD, settings modal, spectator bar, and winner screen
│   ├── main_menu_overlay.gd              # 3D Main Menu lobby, How to Play, and Online Lobby integration
│   ├── match_controller.gd               # Central coordinator for Local AI mode and Online Client mode
│   ├── mobile_controls.gd                # Dual-thumb virtual movement joystick and aiming pad
│   └── ui_style_helper.gd                # Reusable chunky 3D-beveled StyleBox & button bounce helper
├── tests/
│   ├── stress_client_worker.gd                       # Standalone OS-process client worker for multi-process stress tests
│   ├── test_survival_arena.gd                        # Local AI & UI test suite (61 checks)
│   ├── test_admob_and_landscape.gd                   # AdMob break gating, test ad safety & landscape suite (43 checks)
│   ├── test_phase1_multiplayer.gd                    # Phase 1 authoritative server/client test suite (27 checks)
│   ├── test_phase2_lobby_and_rooms.gd                # Phase 2 private rooms, matchmaking & AI fill suite (30 checks)
│   ├── test_phase3_persistence_and_stats.gd          # Phase 3 accounts, stats & leaderboard suite (12 checks)
│   ├── test_e2e_multiprocess_verification.gd         # Multi-process E2E verification & auto-connect suite (32 checks)
│   ├── test_comprehensive_security_and_reliability.gd # Security, authority, room/queue race & persistence suite (39 checks)
│   └── test_multiprocess_stress_and_soak.gd          # Multi-process 5/10/16-client scaling & sustained soak suite (16 checks)
└── ui/
    ├── hud.tscn
    ├── main_menu_overlay.tscn
    └── party_theme.tres
```

---

## 6. Running All Automated Test Suites

Run all eight automated test suites (`260 total assertions`) from PowerShell:

```powershell
# 1. Local Single-Player AI & UI Suite (61 assertions)
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://tests/test_survival_arena.gd

# 2. AdMob Break-Gating, Test Ad Safety & Mobile Landscape Suite (43 assertions)
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://tests/test_admob_and_landscape.gd

# 3. Phase 1: Authoritative Dedicated Server & Multi-Client Sync (27 assertions)
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://tests/test_phase1_multiplayer.gd

# 4. Phase 2: Private Rooms, Public Matchmaking, Host Controls & AI Fill (30 assertions)
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://tests/test_phase2_lobby_and_rooms.gd

# 5. Phase 3: Persistent Accounts, Server-Validated Stats & Leaderboards (12 assertions)
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://tests/test_phase3_persistence_and_stats.gd

# 6. End-to-End Multi-Process Verification & Auto-Connect Stabilization Suite (32 assertions)
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://tests/test_e2e_multiprocess_verification.gd

# 7. Comprehensive Multiplayer Reliability, Authority & Security Suite (39 assertions)
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://tests/test_comprehensive_security_and_reliability.gd

# 8. Automated Multi-Process Stress & Sustained Soak Suite (16 assertions, ~135s soak)
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://tests/test_multiprocess_stress_and_soak.gd
```

---

## 7. Android Build & Export Instructions
To generate a release or debug `.apk` with the AdMob plugin enabled:
1. In the Godot Editor, install the Android build template via **Project -> Install Android Build Template**.
2. Download and install Godot 4.7.2 export templates (`android_source.zip`) into `%APPDATA%\Godot\export_templates\4.7.2.stable\`.
3. Set your Android SDK path and JDK 17 (Java SDK) path in Godot's **Editor Settings -> Export -> Android**.
4. Run the export command:
   ```powershell
   & "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . --export-debug "Android" build/android/zapp_arena_debug.apk
   ```
