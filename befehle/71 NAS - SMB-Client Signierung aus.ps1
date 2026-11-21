# Beschreibung: SMB-Client verlangt keine Signierung mehr
# ACHTUNG: senkt die Sicherheit - nur im eigenen Netz verwenden
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    return ((Get-SmbClientConfiguration).RequireSecuritySignature -eq $false)
}

# --- Befehl ---
Write-Host "Set-SmbClientConfiguration -RequireSecuritySignature `$false"
Set-SmbClientConfiguration -RequireSecuritySignature $false -Force
