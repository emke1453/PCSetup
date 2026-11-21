# Beschreibung: Zeigt Dateiendungen (.txt, .exe ...) im Explorer an
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    return ((Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -ErrorAction SilentlyContinue).HideFileExt -eq 0)
}

# --- Befehl ---
$k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
Write-Host "Setze $k  HideFileExt = 0"
Set-ItemProperty $k -Name HideFileExt -Value 0
