# monitor-connect-switcher

[![Lint](https://github.com/ow-n/monitor-connect-switcher/actions/workflows/lint.yml/badge.svg)](https://github.com/ow-n/monitor-connect-switcher/actions/workflows/lint.yml)

A single PowerShell script that flips between saved multi-monitor configurations on Windows — instantly enable/disable groups of displays and hand them off to another machine — **without** clicking through Settings > Display.

Built around a 5-monitor 2×3 wall (so a laptop can borrow a column, two columns, or all-but-one on demand), but the design is general: profiles are defined by **screen position**, not hard-coded display IDs, so they survive Windows renumbering your displays after a re-plug.

> **Why this exists:** Windows 11 24H2 broke the usual tool ([NirSoft MultiMonitorTool](https://www.nirsoft.net/utils/multi_monitor_tool.html)) — its `/disable` and `/enable` commands use the legacy `ChangeDisplaySettingsEx` API and now silently no-op. This script uses the modern **CCD (Connecting and Configuring Displays) API** via the [DisplayConfig](https://github.com/MartinGC94/DisplayConfig) PowerShell module — the same engine Settings itself uses — so enable/disable actually works again.

---

## What it does

- **Snapshot** your full display layout once (positions, rotations, refresh rates, primary marker) into a baseline file.
- **Switch profiles** that keep a subset of monitors active and disable the rest — in **one atomic CCD call** (no flicker, no half-applied state).
- **Hand displays to a second machine**: disabling them here frees the physical inputs so a laptop on the same monitors' other inputs takes over.
- **Survive re-plugs**: Windows reassigns display IDs whenever a monitor is added/removed; profiles are computed from geometry, so they keep working.
- **`-Identify`** flashes a big number + cable type on each physical screen so you can map which panel is which ID.

---

## Requirements

- Windows 10 or 11 (built for 24H2; works earlier).
- PowerShell 5.1+ (ships with Windows).
- The [DisplayConfig](https://www.powershellgallery.com/packages/DisplayConfig) module (MIT, actively maintained):

```powershell
Install-Module DisplayConfig -Scope CurrentUser -Force
```

---

## Install

```powershell
git clone https://github.com/ow-n/monitor-connect-switcher.git
cd monitor-connect-switcher
Install-Module DisplayConfig -Scope CurrentUser -Force   # if you don't have it

# 1) Arrange your monitors how you want them in Settings > Display, then snapshot:
.\monitor-profile.ps1 -Capture five
```

`-Capture` writes two **gitignored, machine-specific** files into `profiles/`:

| File | What it is |
|------|------------|
| `five.xml` | Full serialized CCD layout (`Export-Clixml`) — round-trips losslessly. |
| `positions.json` | Tiny `DisplayId → (X, Y)` geometry map the handoff profiles reason over. |

They are **not** in the repo because they're unique to each machine. Every machine generates its own.

---

## Usage

```powershell
.\monitor-profile.ps1 -Profile five          # restore ALL monitors (full layout)
.\monitor-profile.ps1 -Profile left          # keep LEFT column, free the rest
.\monitor-profile.ps1 -Profile middle        # keep MIDDLE column
.\monitor-profile.ps1 -Profile left-middle   # keep LEFT + MIDDLE (free RIGHT)
.\monitor-profile.ps1 -Profile top-left      # keep ONE screen (top-left)

.\monitor-profile.ps1 -List                  # show every profile + the IDs it keeps
.\monitor-profile.ps1 -Status                # current live display state
.\monitor-profile.ps1 -Identify              # flash DisplayId + cable on each screen
.\monitor-profile.ps1 -Capture five          # re-snapshot the baseline
```

Double-clickable `.bat` wrappers (`FIVE.bat`, `LEFT.bat`, `MIDDLE.bat`, `LEFT + MIDDLE.bat`, `TOP-LEFT.bat`) call the matching profile so you can pin them to the taskbar.

### Bundled profiles

The bundled set assumes a 2-row × 3-column grid (the right-top slot may be empty). "Free for laptop" = those inputs are released so a second machine driving the monitors' other inputs takes over.

| Profile | Keeps active | Frees |
|---------|--------------|-------|
| `five` | All monitors (full restore from `five.xml`) | — |
| `left` | LEFT column | Middle + right |
| `middle` | MIDDLE column | Left + right |
| `left-middle` | LEFT + MIDDLE columns | Right column |
| `top-left` | Single top-left screen | Everything else |

---

## How it works

1. **Baseline snapshot** — `Get-DisplayConfig | Export-Clixml profiles\five.xml` captures the entire CCD path/mode arrays: positions, rotations, refresh rates, and the primary marker. `-Capture` also writes `positions.json`, the geometry sidecar.
2. **Full restore (`five`)** — `Import-Clixml | Use-DisplayConfig -UpdateAdapterIds` atomically reapplies the whole layout (rotations and primary included).
3. **Handoff profiles** — read geometry from `positions.json`, compute which displays to **keep**, then on the baseline config object: **promote a kept display to primary first** (CCD refuses to disable the current primary), pipe the rest through `Disable-Display`, and commit with a single `Use-DisplayConfig` call.
4. **`-UpdateAdapterIds`** re-binds the snapshot's saved adapter GUIDs to current hardware, so a GPU driver update between snapshot and restore doesn't break the apply.

### Six design decisions that make it robust

These are the non-obvious bits — if you're comparing this to your own version, check each:

| # | Decision | Why it matters |
|---|----------|----------------|
| 1 | **DisplayConfig (CCD API)**, not MultiMonitorTool | MMT's `/disable` + `/enable` are dead on Win11 24H2. |
| 2 | **Position-based profiles**, not hard-coded IDs | Windows renumbers DisplayIds on add/remove; geometry survives. |
| 3 | **`positions.json` sidecar** | Handoff math reads the *baseline* geometry, not live state, so chaining profiles doesn't drift. |
| 4 | **Promote-primary-before-disable** | CCD rejects disabling the primary display; set a kept screen primary first. |
| 5 | **Single atomic `Use-DisplayConfig`** | All changes commit in one CCD call — no flicker, no half-applied state. |
| 6 | **`-UpdateAdapterIds`** | Survives GPU driver/adapter-GUID changes between capture and restore. |

---

## The `positions.json` format

Because it's gitignored, here's the shape `-Capture` produces (one entry per active display):

```json
[
  { "DisplayId": 1, "X": 3440,  "Y": 0 },
  { "DisplayId": 2, "X": -3440, "Y": 0 },
  { "DisplayId": 3, "X": -3440, "Y": -1440 },
  { "DisplayId": 4, "X": 0,     "Y": -1440 },
  { "DisplayId": 5, "X": 0,     "Y": 0 }
]
```

`X`/`Y` are the top-left pixel coordinates of each display in the virtual desktop. The profiles bucket displays into columns with `round(X / <panel-width>)`.

---

## Adapting it to your setup

The bundled profiles are tuned to a specific rig — **edit two things** to match yours:

1. **Panel width** — the column math is `[math]::Round($_.X / 3440)` (3440 = an ultrawide's pixel width). Change `3440` to your panel's horizontal resolution. With mixed sizes, switch to explicit X-range buckets instead of a single divisor.
2. **The `$Profiles` table** — each profile is a scriptblock over the geometry (`$geo`: objects with `.DisplayId / .X / .Y`) returning the DisplayIds to **keep, primary first**. Add/remove profiles for your columns, then add the name to the `[ValidateSet(...)]` on the `$Profile` param (and the `-Capture` set if you rename the baseline).

Example — keep only the RIGHT column (column index `1`):

```powershell
'right' = {
    param($geo)
    @($geo | Where-Object { [math]::Round($_.X / 3440) -eq 1 } |
        Sort-Object -Property Y -Descending | ForEach-Object { $_.DisplayId })
}
```

---

## Re-capturing the baseline

Any time you physically change the layout (rearrange cables, drag/rotate monitors in Settings, change refresh rates), the snapshot is stale. Refresh it:

```powershell
.\monitor-profile.ps1 -Identify     # confirm which physical screen is which DisplayId
.\monitor-profile.ps1 -Capture five # overwrite five.xml + positions.json
```

If your monitors' on-screen arrangement is wrong (all identical panels confuse Windows), use `-Identify`, fix the arrangement with `Set-DisplayRotation` / `Set-DisplayPosition` / `Set-DisplayPrimary` piped into `Use-DisplayConfig -UpdateAdapterIds`, then re-capture.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `DisplayConfig module not installed` | `Install-Module DisplayConfig -Scope CurrentUser -Force` |
| Displays look stuck / half-applied after a switch | Open **Settings > System > Display**, nudge any monitor, hit **Apply**, then re-run the profile. The CCD apply is atomic, but a wedged driver state occasionally needs one manual nudge. |
| A profile keeps the **wrong** monitors | Your DisplayIds renumbered (happens on any add / remove / re-plug). Run `-Identify` to see the live mapping, then `-Capture five` to refresh the baseline. |
| A disabled monitor won't come back | `.\monitor-profile.ps1 -Profile five` re-enables everything from the baseline snapshot. |
| `Baseline five.xml not found` | Capture it first: `.\monitor-profile.ps1 -Capture five`. |
| Columns look wrong / handoff frees the wrong side | The column math divides each display's X by the panel width (`3440`). If your panels aren't 3440 px wide, edit that divisor (see [Adapting it to your setup](#adapting-it-to-your-setup)) and re-capture. |
| `-Identify` overlay won't dismiss | Click any screen or press **Esc**; it also auto-closes after 60 seconds. |
| `.ps1 cannot be loaded because running scripts is disabled` | Use the `.bat` wrappers (they pass `-ExecutionPolicy Bypass`), or run `powershell -ExecutionPolicy Bypass -File .\monitor-profile.ps1 -Profile five`. |

> If an apply errors out, the script prints the current display state so you can see what actually happened, and it promotes a kept display to primary **before** disabling any others — so it never strands you with the primary display turned off.

---

## Why DisplayConfig and not MultiMonitorTool

Per the [official MMT readme](https://www.nirsoft.net/utils/multi_monitor_tool.html), the Win11 24H2 workaround was applied only to `/SetMonitors`, `/SetPrimary`, and `/LoadConfig` — **explicitly not** to `/disable` and `/enable`, which this tool depends on. [DisplayConfig](https://github.com/MartinGC94/DisplayConfig) wraps the modern CCD APIs (the engine Settings uses), is MIT-licensed, and is actively maintained.

---

## Credits

- [DisplayConfig](https://github.com/MartinGC94/DisplayConfig) by MartinGC94 — the CCD-API PowerShell module doing the heavy lifting.

## License

[MIT](LICENSE)
