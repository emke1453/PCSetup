# Beschreibung: SMB-Server verlangt keine Signierung mehr
# ACHTUNG: senkt die Sicherheit - nur im eigenen Netz verwenden
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    return ((Get-SmbServerConfiguration).RequireSecuritySignature -eq $false)
}

# --- Befehl ---
Write-Host "Set-SmbServerConfiguration -RequireSecuritySignature `$false"
Set-SmbServerConfiguration -RequireSecuritySignature $false -Force
