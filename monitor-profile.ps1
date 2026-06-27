# monitor-profile.ps1
# Switch between saved monitor profiles using the DisplayConfig PowerShell module
# (wraps Windows CCD APIs — same engine that Settings > System > Display uses).
#
# Usage:
#   .\monitor-profile.ps1 -Profile five
#   .\monitor-profile.ps1 -Profile left
#   .\monitor-profile.ps1 -Profile middle
#   .\monitor-profile.ps1 -Profile left-middle
#   .\monitor-profile.ps1 -Profile top-left
#   .\monitor-profile.ps1 -List
#   .\monitor-profile.ps1 -Status
#   .\monitor-profile.ps1 -Identify       # flash DisplayId + connection on each physical screen
#   .\monitor-profile.ps1 -Capture five   # re-snapshot current layout (+ positions.json)
#
# Why DisplayConfig and not MultiMonitorTool: Win11 24H2 broke MMT's /disable
# and /enable commands (legacy ChangeDisplaySettingsEx API). DisplayConfig uses
# the modern CCD APIs and is actively maintained.
#
# Documented in vault: Tech/Monitors/Monitor Profile Switching.md

[CmdletBinding(DefaultParameterSetName = 'Switch')]
param(
    [Parameter(ParameterSetName = 'Switch', Position = 0)]
    [ValidateSet('five', 'left', 'middle', 'left-middle', 'top-left')]
    [string]$Profile,

    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Identify')]
    [switch]$Identify,

    [Parameter(ParameterSetName = 'Capture', Mandatory = $true)]
    [ValidateSet('five')]
    [string]$Capture
)

# Ensure DisplayConfig module is available
if (-not (Get-Module -ListAvailable DisplayConfig)) {
    Write-Host "DisplayConfig module not installed." -ForegroundColor Red
    Write-Host "Install with: Install-Module DisplayConfig -Scope CurrentUser -Force" -ForegroundColor Yellow
    exit 1
}
Import-Module DisplayConfig -ErrorAction Stop

$ToolDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProfileDir = Join-Path $ToolDir 'profiles'
if (-not (Test-Path $ProfileDir)) { New-Item -ItemType Directory -Path $ProfileDir | Out-Null }

$BaselineName = 'five'
$BaselineXml  = Join-Path $ProfileDir "$BaselineName.xml"
$GeometryJson = Join-Path $ProfileDir 'positions.json'

# ---------------------------------------------------------------------------
# Physical layout - 5x MSI MPG 341CQPX QD-OLED in a 2x3 grid, top-right slot
# empty (the normally-unconnected 6th monitor). DisplayId-to-slot mapping
# VERIFIED via -Identify on 2026-06-19.
#
#   +-------------------+-------------------+-------------------+
#   | DId 3  top-left   | DId 4  top-mid    |   (empty: 6th)    |  top row y=-1440
#   | DP/GPU    (180)   | HDMI/GPU   (180)  |                   |  inverted mount
#   +-------------------+-------------------+-------------------+
#   | DId 2 bottom-left | DId 5 bot-mid*PRI | DId 1 bottom-right|  bottom row y=0
#   | DP/GPU            | HDMI/GPU          | HDMI/mobo iGPU    |  upright
#   +-------------------+-------------------+-------------------+
#
# The top row is physically mounted INVERTED, so DId 3 + DId 4 carry a 180 deg
# software rotation (cancels the flip, so content reads right-side-up). The
# bottom row is upright. DId 5 (bottom-middle, head-on) is primary.
#
# Connections: 4 monitors on the GTX 1080 Ti (2x DP -> DId 2,3 + 2x HDMI -> DId
# 4,5 = Pascal's hard 4-display cap) + 1 on the motherboard HDMI (7800X3D iGPU
# -> DId 1) = 5 total. The 6th (top-right) runs off the Plugable UD-7400PD
# DisplayLink dock when present.
#
# Windows assigns DisplayIds by hardware enumeration, and they CHANGE when you
# add/remove a monitor (that's what happened going 4 -> 5). So the handoff
# profiles below are defined by GEOMETRY (screen position), not hard-coded
# DisplayIds - they keep working after a re-plug. Run -Status for the live map.
# ---------------------------------------------------------------------------

# Handoff profiles pick which monitors STAY active (the rest are freed for the
# laptop). Each is a scriptblock over the baseline geometry (objects with
# .DisplayId / .X / .Y) returning the DisplayIds to KEEP, PRIMARY FIRST.
#   $null = full restore of every monitor from the baseline snapshot.
#
# Column index for a monitor = round(X / 3440), since every panel is 3440 wide:
#   -1 = LEFT column,  0 = MIDDLE column,  1 = RIGHT column.
$Profiles = @{
    'five'        = $null
    'left'        = {
        param($geo)
        # LEFT column only; bottom monitor first so it becomes primary.
        @($geo | Where-Object { [math]::Round($_.X / 3440) -eq -1 } |
            Sort-Object -Property Y -Descending | ForEach-Object { $_.DisplayId })
    }
    'middle'      = {
        param($geo)
        # MIDDLE column only; bottom monitor first so it becomes primary.
        @($geo | Where-Object { [math]::Round($_.X / 3440) -eq 0 } |
            Sort-Object -Property Y -Descending | ForEach-Object { $_.DisplayId })
    }
    'left-middle' = {
        param($geo)
        # LEFT + MIDDLE columns (everything except the RIGHT column); frees the
        # right column for the laptop. Primary = bottom-middle (head-on screen).
        $keep    = @($geo | Where-Object { [math]::Round($_.X / 3440) -le 0 })
        $primary = $keep | Where-Object { [math]::Round($_.X / 3440) -eq 0 } |
                       Sort-Object -Property Y -Descending | Select-Object -First 1
        @($primary.DisplayId) +
            @($keep | Where-Object { $_.DisplayId -ne $primary.DisplayId } | ForEach-Object { $_.DisplayId })
    }
    'top-left'    = {
        param($geo)
        # Single TOP-LEFT monitor only (LEFT column, TOP row); it becomes primary,
        # the other 4 are freed for the laptop. Sort by Y ascending so the top
        # row (y=-1440) sorts before the bottom row (y=0), then take the first.
        @($geo | Where-Object { [math]::Round($_.X / 3440) -eq -1 } |
            Sort-Object -Property Y | Select-Object -First 1 | ForEach-Object { $_.DisplayId })
    }
}

function Get-BaselineGeometry {
    # Prefer the positions.json sidecar - it reflects the baseline regardless of
    # the current live state, so handoff profiles stay correct even when chained.
    # Fall back to the live layout if the sidecar is missing.
    if (Test-Path $GeometryJson) {
        return @(Get-Content $GeometryJson -Raw | ConvertFrom-Json)
    }
    @(Get-DisplayInfo | ForEach-Object {
        [pscustomobject]@{ DisplayId = $_.DisplayId; X = $_.Position.X; Y = $_.Position.Y }
    })
}

function Show-Profiles {
    Write-Host "`nAvailable profiles:" -ForegroundColor Cyan
    Write-Host ("  {0,-14} full restore of all monitors from {0}.xml" -f $BaselineName) -ForegroundColor Yellow
    $geo = Get-BaselineGeometry
    foreach ($key in ($Profiles.Keys | Where-Object { $null -ne $Profiles[$_] } | Sort-Object)) {
        $keep = @(& $Profiles[$key] $geo)
        Write-Host ("  {0,-14} keep DisplayIds {1} (primary {2}); rest -> laptop" -f $key, ($keep -join ', '), $keep[0]) -ForegroundColor Yellow
    }
    Write-Host ""
}

function Show-Status {
    Write-Host "`nCurrent display state:" -ForegroundColor Cyan
    Get-DisplayInfo | Sort-Object { $_.Position.Y }, { $_.Position.X } | ForEach-Object {
        $color   = if ($_.Active)  { 'Green' } else { 'DarkGray' }
        $state   = if ($_.Active)  { 'Active' } else { 'Off' }
        $primary = if ($_.Primary) { '(primary)' } else { '' }
        Write-Host ("  DisplayId {0}  {1,-7} {2,-13} pos=({3,6},{4,6})  {5,-9} {6,-11} {7}" -f `
            $_.DisplayId, $state, $_.DisplayName, $_.Position.X, $_.Position.Y, $_.Rotation, $_.ConnectionType, $primary) `
            -ForegroundColor $color
    }
    Write-Host ""
}

function Invoke-Identify {
    # Flash a large overlay on every physical screen showing its DisplayId and
    # connection type, so you can map which physical panel is which DisplayId.
    # Click any screen or press Esc to dismiss; auto-closes after 60 seconds.
    # All close handlers use only static .NET calls (no captured variables) so
    # they work regardless of PowerShell scriptblock scope quirks.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $infoMap = @{}
    Get-DisplayInfo | Where-Object Active | ForEach-Object { $infoMap[$_.GdiDeviceName] = $_ }

    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $info = $infoMap[$scr.DeviceName]
        $did  = if ($info) { [string]$info.DisplayId } else { '?' }
        $conn = if ($info) { [string]$info.ConnectionType } else { 'unknown' }

        $f = New-Object System.Windows.Forms.Form
        $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $f.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
        $f.Bounds          = $scr.Bounds
        $f.BackColor       = [System.Drawing.Color]::FromArgb(15, 18, 28)
        $f.TopMost         = $true
        $f.KeyPreview      = $true
        $f.Add_KeyDown({ param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
                @([System.Windows.Forms.Application]::OpenForms) | ForEach-Object { $_.Close() }
                [System.Windows.Forms.Application]::ExitThread()
            }
        })
        $f.Add_Click({
            @([System.Windows.Forms.Application]::OpenForms) | ForEach-Object { $_.Close() }
            [System.Windows.Forms.Application]::ExitThread()
        })

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Dock      = [System.Windows.Forms.DockStyle]::Fill
        $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $lbl.ForeColor = [System.Drawing.Color]::White
        $lbl.Font      = New-Object System.Drawing.Font('Segoe UI', 150, [System.Drawing.FontStyle]::Bold)
        $lbl.Text      = "$did`n$conn"
        $lbl.Add_Click({
            @([System.Windows.Forms.Application]::OpenForms) | ForEach-Object { $_.Close() }
            [System.Windows.Forms.Application]::ExitThread()
        })
        $f.Controls.Add($lbl)
        [void]$f.Show()
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 60000
    $timer.Add_Tick({
        @([System.Windows.Forms.Application]::OpenForms) | ForEach-Object { $_.Close() }
        [System.Windows.Forms.Application]::ExitThread()
    })
    $timer.Start()

    [System.Windows.Forms.Application]::Run()
}

if ($List)     { Show-Profiles;   exit 0 }
if ($Status)   { Show-Status;     exit 0 }
if ($Identify) { Invoke-Identify; exit 0 }

if ($Capture) {
    Write-Host "`nCapturing current layout to $BaselineXml" -ForegroundColor Cyan
    Get-DisplayConfig | Export-Clixml $BaselineXml
    # Sidecar geometry map so the position-based handoff profiles are robust.
    @(Get-DisplayInfo | ForEach-Object {
        [pscustomobject]@{ DisplayId = $_.DisplayId; X = $_.Position.X; Y = $_.Position.Y }
    }) | ConvertTo-Json | Set-Content $GeometryJson -Encoding UTF8
    Write-Host "Saved $BaselineName.xml + positions.json." -ForegroundColor Green
    Show-Status
    exit 0
}

if (-not $Profile) {
    Write-Host "No profile specified." -ForegroundColor Red
    Show-Profiles
    Write-Host "Usage: .\monitor-profile.ps1 -Profile <name>"
    exit 1
}

if (-not (Test-Path $BaselineXml)) {
    Write-Host "Baseline $BaselineName.xml not found at $BaselineXml" -ForegroundColor Red
    Write-Host "Capture it first with: .\monitor-profile.ps1 -Capture $BaselineName" -ForegroundColor Yellow
    exit 1
}

Write-Host "`nApplying profile: $Profile" -ForegroundColor Cyan

try {
    if ($null -eq $Profiles[$Profile]) {
        # Full restore from XML snapshot - positions, rotations, refresh rates, primary.
        Write-Host "  Restoring full layout from $BaselineName.xml" -ForegroundColor DarkCyan
        Import-Clixml $BaselineXml | Use-DisplayConfig -UpdateAdapterIds -ErrorAction Stop
    }
    else {
        # Position-based handoff: start from the full baseline, then disable the
        # monitors not in the kept set - one atomic CCD change, no flicker.
        $geo       = Get-BaselineGeometry
        $allIds    = @($geo | ForEach-Object { $_.DisplayId })
        $wanted    = @(& $Profiles[$Profile] $geo)
        $toDisable = @($allIds | Where-Object { $_ -notin $wanted })

        Write-Host ("  Keep active: DisplayIds {0}" -f ($wanted -join ', ')) -ForegroundColor Green
        if ($toDisable.Count -gt 0) {
            Write-Host ("  Disable:     DisplayIds {0}  (-> laptop)" -f ($toDisable -join ', ')) -ForegroundColor DarkYellow
        }

        $config = Import-Clixml $BaselineXml

        # A KEPT display must be primary BEFORE disabling (CCD rejects disabling the
        # primary). Promote the profile's designated primary (first in the kept
        # list) on the baseline config itself.
        $newPrimary = $wanted[0]
        Write-Host ("  [primary] ensuring DisplayId {0} is primary" -f $newPrimary) -ForegroundColor DarkCyan
        $config = $config | Set-DisplayPrimary -DisplayId $newPrimary -ErrorAction Stop

        if ($toDisable.Count -gt 0) {
            $config = $config | Disable-Display -DisplayId $toDisable -ErrorAction Stop
        }
        $config | Use-DisplayConfig -UpdateAdapterIds -ErrorAction Stop
    }
    Write-Host "`nDone." -ForegroundColor Green
}
catch {
    Write-Host "`nERROR applying profile: $_" -ForegroundColor Red
    Write-Host "If displays look stuck, open Settings > System > Display, nudge a monitor, hit Apply, then retry." -ForegroundColor Yellow
    Show-Status
    exit 1
}

Show-Status
