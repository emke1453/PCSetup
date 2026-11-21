# Beschreibung: Altes Rechtsklick-Menue unter Windows 11 (wirkt nach Explorer-Neustart/Abmelden)
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    return (Test-Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32")
}

# --- Befehl ---
$k = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
Write-Host "Lege $k an (Standardwert leer)"
New-Item $k -Force | Out-Null
Set-ItemProperty $k -Name "(default)" -Value ""
