# Beschreibung: Zeitzone auf Berlin (W. Europe Standard Time)
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    return ((Get-TimeZone).Id -eq "W. Europe Standard Time")
}

# --- Befehl ---
Write-Host "Set-TimeZone -Id 'W. Europe Standard Time'"
Set-TimeZone -Id "W. Europe Standard Time"
