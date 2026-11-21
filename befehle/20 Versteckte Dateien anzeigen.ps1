# Beschreibung: Zeigt versteckte Dateien und Ordner im Explorer an
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    return ((Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -ErrorAction SilentlyContinue).Hidden -eq 1)
}

# --- Befehl ---
$k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
Write-Host "Setze $k  Hidden = 1"
Set-ItemProperty $k -Name Hidden -Value 1
