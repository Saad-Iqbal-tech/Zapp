# 5-Player Line-of-Sight Survival Arena

A 2.5D low-poly 3D mobile survival arena game built in **Godot 4.7** using GDScript. Five combatants (1 human player and 4 local AI opponents) battle on a shrinking floating square platform using strategic line-of-sight laser attacks that fire simultaneously at the end of each 5-second preparation countdown.

---

## 1. Setup & Launching the Game

### Prerequisites
- **Godot Engine 4.x** (tested and verified with `Godot v4.7.2-stable_win64`).
- Renderer configured for **Forward Mobile (`mobile`)** with **Jolt Physics 3D** and touchscreen emulation enabled for desktop testing.

### Opening in the Godot Editor
1. Launch Godot 4 (`C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe`).
2. Import or open `project.godot` in the workspace root (`c:\Users\danis\OneDrive\Documents\zapp`).
3. Press **F5** (or click the **Play** button) to run the main scene (`res://scenes/main_arena.tscn`).

### Running Directly from Command Line
```powershell
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --path .
```

---

## 2. Mobile Party Main Menu & Controls

### Main Menu Lobby & Matchmaking
- **Live 3D Hero Showcase Lobby**: Launches into a full-screen mobile party lobby featuring the 3D arena as a live background with subtle camera motion, the prominent **ZAPP ARENA** title banner, your 3D character (`YOU`, Cyan) in the center with expressive idle/wave animation and a soft ground shadow, a player profile card (`STRIKER_01`), and `WINS` / `TOKENS` counters.
- **Play / Offline AI Matchmaking**: Tapping the dominant **PLAY!** button opens an animated matchmaking screen (`LOCAL AI ARENA MATCH • NO INTERNET REQUIRED`) that fills all 5 player slots (`YOU`, `VEX`, `NOVA`, `SOL`, `NYX`) with a **CANCEL** option before smoothly transitioning into the arena.
- **Secondary Navigation**: Includes chunky rounded buttons with hover/press bounce animations for **SETTINGS**, **HOW TO PLAY**, and **EXIT**.

### In-Game Touchscreen Controls
The game is designed around dual-thumb mobile touchscreen controls:
- **Bottom-Left Virtual Joystick (`MOVE`)**: Touch and drag anywhere on the bottom-left virtual joystick to move your character (`YOU`, Electric Cyan).
- **Bottom-Right Aiming Control (`AIM`)**: Touch and drag on the bottom-right aiming pad to rotate your forward-facing torso attack line. Releasing your finger preserves your last aimed direction.
- **Spectator Mode (`< PREV` / `NEXT >` / `MAIN MENU`)**: Automatically activates if you are eliminated while AI opponents remain alive, revealing all surviving players, zooming the camera onto the selected survivor (marked with a glowing cyan target ring), and letting you cycle targets via the on-screen buttons, tapping the left/right screen halves, or pressing `A`/`D` / `Left`/`Right`.
- **Settings Panel (`SETTINGS` button / `Esc`)**: Opens a mobile party settings modal to adjust **Master Volume**, **Music Volume**, **Sound FX Volume**, **Camera Speed (Sensitivity)**, or **Mute All Audio**, plus a **Main Menu** button to return to the 3D lobby (or `lobby_scene_path` if configured).
- **Winner / Draw Screen (`PLAY AGAIN` / `MAIN MENU`)**: Celebratory round-end screen with confetti particles, victory animations, token rewards, and quick replay or return-to-menu controls.

### Desktop Testing Mode
- `input_devices/pointing/emulate_touch_from_mouse=true` is enabled in `project.godot`, allowing you to click and drag the on-screen **MOVE** and **AIM** virtual pads directly with a mouse.
- For single-cursor desktop convenience when testing simultaneous movement and aiming, `WASD` / Arrow keys can also deflect the left virtual joystick while your mouse drags the right aiming pad.

---

## 3. Gameplay Rules & Arena Mechanics

### 5-Second Stealth Preparation & Simultaneous Resolution
1. **Spawn**: All 5 players (`YOU`, `VEX`, `NOVA`, `SOL`, `NYX`) spawn at separate balanced positions around the arena.
2. **Preparation Phase (5.0s — Stealth & Invincible)**:
   - All living players are **invincible** to laser attacks during these 5 seconds (indicated by the pulsing shield aura at your character's base).
   - **Players are invisible from each other during the 5-second preparation phase**: only your own character and aiming line (or the currently spectated player's character and aiming line) are visible on screen while opponents and their aiming lines remain hidden.
   - Aiming lines are blocked in real time by solid obstacles.
3. **Simultaneous Resolution (Countdown = 0.0s — Laser Reveal & Fire)**:
   - Movement and aiming freeze briefly (`0.85s`).
   - **Everyone is revealed simultaneously** along with their high-intensity laser beams and a sci-fi laser discharge sound effect.
   - A simultaneous snapshot of all living players and their unobstructed aiming segments is evaluated.
   - Any living player whose circular hit area is intersected by another living player's unobstructed line is eliminated.
   - Because all attacks are resolved from the same snapshot, two players aiming at each other without cover will **eliminate each other simultaneously**.
   - If the final surviving players eliminate each other on the same cycle, the match ends in a **Draw**.

### Audio & Soundtrack (`AudioManager`)
- **Background Music**: Procedural 120 BPM synthwave/electronic arena loop that plays continuously during rounds.
- **Laser Shooting SFX**: High-energy sci-fi laser beam discharge sound effect when the 5-second countdown fires.
- **Platform / Background Dropping SFX**: Heavy descending sub-bass drop and cascading tile detachment sound when outer platform sections collapse into the abyss or when a player falls off.
- **Tactical Cues**: Countdown ticks during the final 3 seconds (`3... 2... 1...`), shrink warning alarm pulses, and elimination shatter effects.

### Staged Shrinking Platform
The arena is generated from a `16x16` grid (`256` modular beveled floor tiles) with stage-grouped tactical cover obstacles. The safe playable width shrinks in 4 stages:
- **Stage 1**: `100%` of original width (`24.0m x 24.0m`)
- **Stage 2**: `72%` of original width (`17.28m x 17.28m`)
- **Stage 3**: `45%` of original width (`10.80m x 10.80m`)
- **Stage 4**: `22%` of original width (`5.28m x 5.28m`)

Before each shrink (`4.0s` warning countdown), the danger boundary is highlighted and the outer tile ring pulses red and shakes before collapsing into the abyss and disabling its collision. Falling below the platform eliminates the character immediately. Arena shrinking stops automatically when the match ends.

---

## 4. Project Structure & Architecture

```text
├── assets/
│   └── low_poly_mesh_builder.gd   # Procedural faceted low-poly ArrayMesh builder (humanoids, tiles, obstacles)
├── materials/
│   ├── danger_boundary_material.tres
│   ├── floor_tile_even.tres
│   ├── floor_tile_odd.tres
│   ├── floor_tile_warning.tres
│   └── obstacle_material.tres
├── scenes/
│   ├── arena.tscn                 # Modular arena generator scene
│   ├── character.tscn             # Reusable character scene
│   └── main_arena.tscn            # Main match scene
├── scripts/
│   ├── ai_controller.gd           # AI target selection, aiming, line-of-sight dodging, and shrink evacuation
│   ├── aim_line.gd                # Torso laser line visuals, obstacle raycast/AABB blocking, and hit math
│   ├── arena_generator.gd         # 256-tile modular platform, 100/72/45/22% stage shrinking, falling tiles
│   ├── audio_manager.gd           # Procedural 16-bit PCM synthwave BGM, laser shoot SFX, and platform drop SFX
│   ├── camera_rig.gd              # Fixed ~75° high-angle camera rig with smooth follow & spectator tracking
│   ├── character_controller.gd    # Movement physics, ALIVE/ELIMINATED/SPECTATING/WINNER states, fall detection
│   ├── character_visuals.gd       # Articulated 3D low-poly humanoid model (5 color variants) & elimination FX
│   ├── hud_controller.gd          # Mobile HUD, countdowns, settings modal, spectator bar, and winner/draw modal
│   ├── main_menu_overlay.gd       # Full-screen 3D Main Menu lobby, How to Play modal, and AI Matchmaking screen
│   ├── match_controller.gd        # Central round timer, simultaneous attack snapshot resolver, match lifecycle
│   ├── mobile_controls.gd         # Touchscreen virtual movement joystick (left) and aiming pad (right)
│   └── ui_style_helper.gd         # Reusable chunky 3D-beveled StyleBox builder & button hover/press bounce animations
├── tests/
│   └── test_survival_arena.gd     # Automated verification test suite (61 checks)
└── ui/
    ├── hud.tscn                   # HUD CanvasLayer scene
    ├── main_menu_overlay.tscn     # Reusable Main Menu & Matchmaking UI scene
    └── party_theme.tres           # Reusable mobile party Theme resource
```

---

## 5. Automated Testing

Run the automated test suite from the terminal to verify all core systems (character spawning, 75° camera angle, multi-touch virtual joystick & aim pad, obstacle line-of-sight blocking, mutual simultaneous elimination, spectator mode & target cycling, 100% -> 72% -> 45% -> 22% arena shrinking, fall detection, winner/draw screens, and replay reset):

```powershell
& "C:\Users\danis\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://tests/test_survival_arena.gd
```
