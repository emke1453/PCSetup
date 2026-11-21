# Beschreibung: Erlaubt unsichere Gast-Anmeldung fuer Netzlaufwerke (SMB)
# ACHTUNG: senkt die Sicherheit - nur im eigenen Netz verwenden
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    return ((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -ErrorAction SilentlyContinue).AllowInsecureGuestAuth -eq 1)
}

# --- Befehl ---
$k = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters"
if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
Write-Host "Setze $k  AllowInsecureGuestAuth = 1 (DWORD)"
New-ItemProperty $k -Name "AllowInsecureGuestAuth" -Value 1 -PropertyType DWord -Force | Out-Null
