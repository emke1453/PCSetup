# Beschreibung: Energiesparplan "Hoechstleistung" aktivieren
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    return [bool](@(powercfg /getactivescheme) -match "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")
}

# --- Befehl ---
Write-Host "powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
if ($LASTEXITCODE -ne 0) { throw "Plan nicht vorhanden (powercfg Code $LASTEXITCODE)" }
