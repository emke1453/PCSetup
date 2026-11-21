# Beschreibung: Dunkles Design fuer Windows und Apps
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    $p = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction SilentlyContinue
    return ($p.AppsUseLightTheme -eq 0) -and ($p.SystemUsesLightTheme -eq 0)
}

# --- Befehl ---
$k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
Write-Host "Setze $k  AppsUseLightTheme = 0, SystemUsesLightTheme = 0"
Set-ItemProperty $k -Name AppsUseLightTheme -Value 0
Set-ItemProperty $k -Name SystemUsesLightTheme -Value 0
