# Auto-detect the right backend URL and run the Flutter app on the connected
# Android device. Replaces the manual:
#   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:5000
#
# What it does:
#   1. Picks the best host IP for the device:
#        - If an Android *emulator* is connected  -> http://10.0.2.2:5000
#        - If an Android *physical device* is connected on USB / Wi-Fi
#          -> the first reachable non-loopback IPv4 on this host
#             (usually the Wi-Fi LAN IP, e.g. http://192.168.0.105:5000)
#   2. Confirms the Flask backend is up at that URL (HEAD /).
#   3. Runs `flutter run -d <device-id> --dart-define=API_BASE_URL=...`.
#
# Usage (from e:\Flutter_app\my_app):
#   powershell -ExecutionPolicy Bypass -File scripts\run_android.ps1
# Optional env vars:
#   $env:HOST_PORT   = "5000"          # backend port
#   $env:FLUTTER_BIN = "C:\Users\User\flutter\bin\flutter.bat"

$ErrorActionPreference = 'Stop'

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Push-Location $ProjectRoot

try {
    # ---- Resolve Flutter binary ------------------------------------------------
    $flutter = if ($env:FLUTTER_BIN) { $env:FLUTTER_BIN } else {
        $cmd = Get-Command flutter -ErrorAction SilentlyContinue
        if ($cmd) { $cmd.Source } else { 'C:\Users\User\flutter\bin\flutter.bat' }
    }
    Write-Host "Using Flutter: $flutter"

    & $flutter --suppress-analytics pub get | Out-Null

    # ---- List devices (parse the machine JSON; the human-readable table
    # is rendered with non-ASCII bullets that can come back as mojibake
    # depending on the host's console codepage).
    $devJson = & $flutter --suppress-analytics devices --machine 2>&1 | Out-String
    $devices = $null
    try { $devices = $devJson | ConvertFrom-Json } catch {
        Write-Warning 'Could not parse `flutter devices --machine` output.'
        exit 1
    }
    if (-not $devices) {
        Write-Warning 'No devices detected by Flutter.'
        exit 1
    }
    $picked = $devices |
        Where-Object { $_.targetPlatform -like 'android-*' -and $_.isSupported } |
        Sort-Object -Property @{Expression={ if ($_.emulator) { 0 } else { 1 } }} |
        Select-Object -First 1
    if (-not $picked) {
        Write-Warning 'No supported Android device found.'
        exit 1
    }
    $deviceId   = $picked.id
    $isEmulator = [bool]$picked.emulator
    Write-Host ("Picked device: {0} ({1}, {2})" -f $deviceId, $picked.name, ($(if ($isEmulator) {'emulator'} else {'physical device'})))

    # ---- Pick the right base URL ----------------------------------------------
    $port = if ($env:HOST_PORT) { $env:HOST_PORT } else { '5000' }
    if ($isEmulator) {
        $baseUrl = "http://10.0.2.2:$port"
    } else {
        # Prefer the Wi-Fi / Ethernet IPv4 — that's the IP the phone can reach.
        $candidates = Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object {
                $_.IPAddress -notmatch '^127\.' -and
                $_.IPAddress -notmatch '^169\.254\.'
            } | Sort-Object {
                # Prefer 192.168.* / 10.* (typical LAN ranges) over link-local
                switch -regex ($_.IPAddress) {
                    '^192\.168\.'   { 0; break }
                    '^10\.'         { 1; break }
                    '^172\.(1[6-9]|2[0-9]|3[01])\.' { 2; break }
                    default         { 3 }
                }
            }
        $host = $candidates | Select-Object -First 1 -ExpandProperty IPAddress
        if (-not $host) {
            Write-Warning 'No LAN IPv4 found. Falling back to 10.0.2.2 (works only on emulator).'
            $host = '10.0.2.2'
        }
        $baseUrl = "http://${host}:${port}"
    }
    Write-Host "Backend URL: $baseUrl"

    # ---- Health check ---------------------------------------------------------
    try {
        $null = Invoke-WebRequest -Uri "$baseUrl/" -Method GET -TimeoutSec 3 -ErrorAction Stop
        Write-Host 'Backend reachable.' -ForegroundColor Green
    } catch {
        Write-Warning "Backend NOT reachable at $baseUrl. Start it first: cd E:\Flutter_app\backend && python run.py"
    }

    # ---- Run ------------------------------------------------------------------
    & $flutter --suppress-analytics run -d $deviceId "--dart-define=API_BASE_URL=$baseUrl"
} finally {
    Pop-Location
}
