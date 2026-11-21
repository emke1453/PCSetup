# Beschreibung: Installiert gpedit.msc auf Windows Home nach (dauert einige Minuten)
param([switch]$Pruefen)

# --- Pruefung: $true = schon erledigt -> wird uebersprungen ---
if ($Pruefen) {
    return (Test-Path "$env:SystemRoot\System32\gpedit.msc")
}

# --- Befehl ---
$ordner = "$env:SystemRoot\servicing\Packages"
$pakete = @(
    Get-ChildItem $ordner -Filter "Microsoft-Windows-GroupPolicy-ClientExtensions-Package~3*.mum"
    Get-ChildItem $ordner -Filter "Microsoft-Windows-GroupPolicy-ClientTools-Package~3*.mum"
) | Select-Object -ExpandProperty Name -Unique
Write-Host "$($pakete.Count) Pakete gefunden"
foreach ($p in $pakete) {
    Write-Host "dism /online /norestart /add-package:$p"
    dism.exe /online /norestart /add-package:"$ordner\$p"
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { throw "dism Code $LASTEXITCODE bei $p" }
}
exit 0
