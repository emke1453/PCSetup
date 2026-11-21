# Beschreibung: Sucht alle verfuegbaren Windows-Updates (inkl. Treiber) und installiert sie
# Nutzt die in Windows eingebaute Update-Schnittstelle - kein Zusatzmodul noetig.
# Kann je nach Anzahl lange dauern. Nach einem Neustart ggf. erneut ausfuehren (manche Updates kommen erst danach).
# Absichtlich OHNE Pruefteil: die Suche dauert zu lange fuer "Status pruefen". Sind keine Updates da, ist er schnell fertig.

$session  = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
Write-Host "Suche nach Updates (kann einige Minuten dauern) ..."
$suche = $searcher.Search("IsInstalled=0 and IsHidden=0")

$liste = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($u in $suche.Updates) {
    if (-not $u.EulaAccepted) { $u.AcceptEula() }
    Write-Host "  gefunden: $($u.Title)"
    [void]$liste.Add($u)
}
if ($liste.Count -eq 0) { Write-Host "Keine Updates verfuegbar - Windows ist aktuell."; exit 0 }

Write-Host "Lade $($liste.Count) Update(s) herunter ..."
$dl = $session.CreateUpdateDownloader()
$dl.Updates = $liste
[void]$dl.Download()

Write-Host "Installiere ..."
$inst = $session.CreateUpdateInstaller()
$inst.Updates = $liste
$erg = $inst.Install()

$fehler = 0
for ($i = 0; $i -lt $liste.Count; $i++) {
    $code = $erg.GetUpdateResult($i).ResultCode   # 2 = OK, 3 = OK mit Fehlern, 4 = fehlgeschlagen, 5 = abgebrochen
    $text = switch ($code) { 2 {"OK"} 3 {"OK (mit Warnungen)"} 4 {"FEHLGESCHLAGEN"} 5 {"abgebrochen"} default {"Code $code"} }
    if ($code -ge 4) { $fehler++ }
    Write-Host "  $text : $($liste.Item($i).Title)"
}
if ($erg.RebootRequired) { Write-Host "Ein Neustart ist erforderlich, um die Updates abzuschliessen." }
Write-Host "$($liste.Count - $fehler) von $($liste.Count) Updates installiert."
if ($fehler -eq $liste.Count) { throw "Kein Update konnte installiert werden." }
exit 0
