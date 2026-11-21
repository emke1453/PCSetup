# Beschreibung: Bildschirm im Netzbetrieb nie automatisch ausschalten
# Gilt fuer den aktiven Energiesparplan im Netzbetrieb (Steckdose).
# Fuer Akkubetrieb (Laptop) zusaetzlich die "-dc"-Zeile aktivieren.
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    # die letzten beiden Hex-Werte der Abfrage = aktueller Wert Netz (AC) und Akku (DC); 0 = nie
    $werte = @([regex]::Matches((powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Out-String), '0x[0-9a-fA-F]{8}') | ForEach-Object Value)
    if ($werte.Count -lt 2) { return $false }
    return ([Convert]::ToInt32($werte[-2], 16) -eq 0)
}

# --- Befehl ---
Write-Host "powercfg /change monitor-timeout-ac 0"
powercfg /change monitor-timeout-ac 0
# powercfg /change monitor-timeout-dc 0
if ($LASTEXITCODE -ne 0) { throw "powercfg Code $LASTEXITCODE" }
