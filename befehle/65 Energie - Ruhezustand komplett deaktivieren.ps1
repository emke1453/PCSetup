# Beschreibung: Schaltet den Ruhezustand (Hibernate) ab - spart Speicherplatz (hiberfil.sys), deaktiviert auch den Schnellstart
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    return ((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -ErrorAction SilentlyContinue).HibernateEnabled -eq 0)
}

# --- Befehl ---
Write-Host "powercfg /hibernate off"
powercfg /hibernate off
if ($LASTEXITCODE -ne 0) { throw "powercfg Code $LASTEXITCODE" }
