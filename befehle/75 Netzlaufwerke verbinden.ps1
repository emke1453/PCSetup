# Beschreibung: Speichert NAS-Zugangsdaten und verbindet Netzlaufwerke aus netzlaufwerke.csv (Reiter "Netzlaufwerke")
param([switch]$Pruefen)

$datei = Join-Path $PSScriptRoot "..\netzlaufwerke.csv"
$liste = @()
if (Test-Path $datei) { $liste = @(Import-Csv $datei -Delimiter ';' -Encoding UTF8 | Where-Object { $_.Pfad }) }

function Get-Server($pfad) { ($pfad -split '\\')[2] }
function Get-GespeicherteZiele {
    @(cmdkey.exe /list 2>$null | ForEach-Object { if ($_ -match '(?i)target=(.+)$') { $Matches[1].Trim().ToLower() } })
}

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    if (-not $liste.Count) { return $false }
    $ziele = Get-GespeicherteZiele
    foreach ($e in $liste) {
        if ($e.Laufwerk) {
            $r = Get-ItemProperty ("HKCU:\Network\" + $e.Laufwerk.TrimEnd(':')) -ErrorAction SilentlyContinue
            if (-not $r -or $r.RemotePath -ne $e.Pfad) { return $false }
        }
        if ($e.Benutzer -and $ziele -notcontains (Get-Server $e.Pfad).ToLower()) { return $false }
    }
    return $true
}

# --- Befehl ---
if (-not $liste.Count) { throw "netzlaufwerke.csv fehlt oder ist leer. Zuerst im Reiter 'Netzlaufwerke' eintragen und speichern." }

$fehler = 0
foreach ($e in $liste) {
    $srv = Get-Server $e.Pfad
    try {
        # Zugangsdaten in der Windows-Anmeldeinformationsverwaltung speichern
        if ($e.Benutzer) {
            Write-Host "Zugangsdaten speichern: $srv  (Benutzer $($e.Benutzer))"
            cmdkey.exe /add:$srv /user:$($e.Benutzer) /pass:$($e.Passwort) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "cmdkey Code $LASTEXITCODE" }
        }
        # Laufwerk dauerhaft verbinden
        if ($e.Laufwerk) {
            Write-Host "Verbinde $($e.Laufwerk) -> $($e.Pfad)"
            Get-SmbMapping -LocalPath $e.Laufwerk -ErrorAction SilentlyContinue | Remove-SmbMapping -Force -UpdateProfile -ErrorAction SilentlyContinue
            $par = @{ LocalPath = $e.Laufwerk; RemotePath = $e.Pfad; Persistent = $true; ErrorAction = 'Stop' }
            if ($e.Benutzer) { $par.UserName = $e.Benutzer; $par.Password = $e.Passwort }
            New-SmbMapping @par | Out-Null
        }
        Write-Host "   OK"
    } catch {
        Write-Host "   FEHLER: $($_.Exception.Message)"
        $fehler++
    }
}

# Damit per Admin verbundene Laufwerke auch im normalen Explorer sichtbar sind
$k = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
if ((Get-ItemProperty $k -ErrorAction SilentlyContinue).EnableLinkedConnections -ne 1) {
    Write-Host "Setze EnableLinkedConnections = 1 (Laufwerke im Explorer sichtbar, wirkt nach Neustart)"
    New-ItemProperty $k -Name EnableLinkedConnections -Value 1 -PropertyType DWord -Force | Out-Null
}

Write-Host "$($liste.Count - $fehler) von $($liste.Count) Eintraegen eingerichtet. Laufwerke erscheinen spaetestens nach Neustart im Explorer."
if ($fehler) { throw "$fehler Eintrag/Eintraege fehlgeschlagen (Pfad, Benutzer/Passwort und NAS-Einstellungen 70-72 pruefen)" }
exit 0
