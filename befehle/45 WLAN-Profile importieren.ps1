# Beschreibung: Importiert alle WLAN-Profile aus dem Ordner "wlan" (vorher auf dem alten PC exportieren)
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    # erledigt, wenn jedes Profil aus dem Ordner "wlan" schon auf dem PC existiert
    $dateien = @(Get-ChildItem (Join-Path $PSScriptRoot "..\wlan") -Filter *.xml -ErrorAction SilentlyContinue)
    if (-not $dateien.Count) { return $false }
    $vorhanden = @(netsh.exe wlan show profiles 2>$null | ForEach-Object { if ($_ -match ':\s+(.+)$') { $Matches[1].Trim() } })
    foreach ($f in $dateien) {
        $name = ([xml](Get-Content $f.FullName -Raw)).WLANProfile.name
        if ($vorhanden -notcontains $name) { return $false }
    }
    return $true
}

# --- Befehl ---
$ordner = Join-Path $PSScriptRoot "..\wlan"
$dateien = @(Get-ChildItem $ordner -Filter *.xml -ErrorAction SilentlyContinue)
if (-not $dateien.Count) { throw "Keine WLAN-Profile im Ordner 'wlan' gefunden. Zuerst auf dem alten PC exportieren." }

# netsh kommt mit Leerzeichen im Pfad schlecht zurecht -> kurze Kopien im TEMP-Ordner verwenden
$tmp = Join-Path $env:TEMP "pcsetup-wlan"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
Set-Location $tmp
$ok = 0; $i = 0
foreach ($f in $dateien) {
    $i++
    Copy-Item $f.FullName (Join-Path $tmp "w$i.xml") -Force
    Write-Host "Importiere $($f.BaseName -replace '^WLAN-','')"
    $out = & netsh.exe wlan add profile filename="w$i.xml" user=all 2>&1
    if ($LASTEXITCODE -eq 0) { $ok++ } else { Write-Host "   fehlgeschlagen: $out" }
}
Set-Location $env:TEMP
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "$ok von $($dateien.Count) WLAN-Profilen importiert."
if ($ok -eq 0) { throw "Kein WLAN-Profil importiert (WLAN-Adapter vorhanden?)" }
exit 0
