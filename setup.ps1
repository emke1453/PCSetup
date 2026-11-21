# PC-Setup
#   Setup.bat                 -> Fenster
#   Setup_auto.bat [Profil]   -> installiert ein Profil vollautomatisch (setup.ps1 -Auto -Profil Name)
param([switch]$Auto, [string]$Profil, [switch]$Probelauf)

$Root       = $PSScriptRoot
$ProfilDir  = Join-Path $Root "profile"
$AktivDatei = Join-Path $ProfilDir "_aktiv.txt"
$BefehlDir  = Join-Path $Root "befehle"
$WlanDir    = Join-Path $Root "wlan"
$NetzDatei  = Join-Path $Root "netzlaufwerke.csv"
$EinstDatei = Join-Path $Root "einstellungen.txt"   # programmweite Einstellungen (Name=Wert)
$InstDir    = Join-Path $Root "installers"
$LogDir     = Join-Path $Root "logs"
foreach ($d in $ProfilDir,$BefehlDir,$LogDir) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
$LogDatei = Join-Path $LogDir ("setup-{0:yyyy-MM-dd_HH-mm-ss}.txt" -f (Get-Date))
$Ell = [string][char]0x2026   # "..." Zeichen, mit dem winget lange Texte abschneidet

if (-not $Auto) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName Microsoft.VisualBasic
    [System.Windows.Forms.Application]::EnableVisualStyles()
}

# ==================================================================
# Hilfsfunktionen
# ==================================================================
function Write-Log($text, $farbe = 'Gray') {
    $zeile = "{0:HH:mm:ss}  {1}" -f (Get-Date), $text
    Add-Content -Path $LogDatei -Value $zeile -Encoding UTF8
    if ($Auto) {
        Write-Host $zeile -ForegroundColor $farbe
    } else {
        $script:logBox.AppendText("$text`r`n")
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Show-Fehler($text) {
    if ($Auto) { Write-Host $text -ForegroundColor Red }
    else { [System.Windows.Forms.MessageBox]::Show($text, "Fehler") | Out-Null }
}

# Startet ein Programm und liefert den Exit-Code.
# Automatik: Ausgabe direkt in der Konsole. Fenster: unsichtbar im Hintergrund.
function Invoke-Prozess($datei, $arg) {
    if ($Auto) {
        Write-Log "   > $datei $arg" 'DarkGray'
        $p = Start-Process $datei -ArgumentList $arg -NoNewWindow -PassThru
        $null = $p.Handle
        $p.WaitForExit()
    } else {
        $p = Start-Process $datei -ArgumentList $arg -PassThru -WindowStyle Hidden
        $null = $p.Handle
        while (-not $p.HasExited) {
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200
        }
    }
    return $p.ExitCode
}

# Gewaehlte Sprache -> Englisch -> ohne Sprachangabe
# -1978335216 = winget: kein passender Installer (z.B. Sprache nicht verfuegbar)
function Invoke-WingetMitFallback($aktion, $id, $loc, $extra, $flags) {
    $versuche = if ($loc) { @($loc) + $(if ($loc -ne 'en-US') { @('en-US') } else { @() }) + @('') } else { @('') }
    $code = 0
    foreach ($v in $versuche) {
        $la = if ($v) { "--locale $v" } else { "" }
        $code = Invoke-Prozess "winget" "$aktion --id $id --exact $la $extra $flags"
        if ($code -ne -1978335216) {
            if ($v -ne $loc) { Write-Log "   Sprache '$loc' nicht verfuegbar - verwendet: $(if($v){$v}else{'Standard'})" 'Yellow' }
            return $code
        }
        Write-Log "   Sprache '$(if($v){$v}else{'Standard'})' nicht verfuegbar, naechster Versuch ..." 'Yellow'
    }
    return $code
}

# winget-Tabelle (search / list) in Objekte zerlegen
function Get-WingetTabelle([string[]]$argumente) {
    $alt = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $out = & winget @argumente 2>$null
    } finally { [Console]::OutputEncoding = $alt }
    $zeilen = @($out | ForEach-Object { ("$_" -split "`r")[-1] })
    $di = -1
    for ($i=0; $i -lt $zeilen.Count; $i++) { if ($zeilen[$i] -match '^-{10,}\s*$') { $di = $i; break } }
    if ($di -lt 1 -or $di -ge $zeilen.Count - 1) { return @() }
    $starts = @([regex]::Matches($zeilen[$di-1], '\S+') | ForEach-Object Index)
    if ($starts.Count -lt 3) { return @() }
    $erg = @()
    foreach ($l in $zeilen[($di+1)..($zeilen.Count-1)]) {
        if ($l.Length -le $starts[1]) { continue }
        $tok = @($l.Substring($starts[1]).Trim() -split '\s+')
        if (-not $tok[0]) { continue }
        $erg += [pscustomobject]@{
            Name     = $l.Substring(0, $starts[1]).Trim()
            WingetID = $tok[0]
            Version  = $(if ($tok.Count -gt 1) { $tok[1] } else { '' })
        }
    }
    return $erg
}

# Installierte winget-Pakete (zuverlaessig ueber "winget export", IDs nie abgeschnitten)
# Rueckgabe: Hashtable  id-kleingeschrieben -> Original-ID
function Get-InstallierteIDs {
    $tmp = Join-Path $env:TEMP "pcsetup-export.json"
    Remove-Item $tmp -ErrorAction SilentlyContinue
    & winget export -o $tmp --source winget --accept-source-agreements *> $null
    $set = @{}
    if (Test-Path $tmp) {
        try {
            $j = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($s in $j.Sources) { foreach ($p in $s.Packages) { $set[$p.PackageIdentifier.ToLower()] = $p.PackageIdentifier } }
        } catch {}
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    return $set
}

function New-Wiederherstellungspunkt {
    Write-Log ""
    Write-Log "===== WIEDERHERSTELLUNGSPUNKT =====" 'Cyan'
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $alt = $null
    try {
        Write-Log "Enable-ComputerRestore -Drive $env:SystemDrive\" 'DarkGray'
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        # Windows erlaubt sonst nur einen Punkt pro 24 Stunden -> Sperre kurz aufheben
        $alt = (Get-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
        Write-Log "Checkpoint-Computer -Description 'PC-Setup ...' (kann 1-2 Minuten dauern)" 'DarkGray'
        Checkpoint-Computer -Description ("PC-Setup {0:yyyy-MM-dd HH:mm}" -f (Get-Date)) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log "   OK - Wiederherstellungspunkt erstellt" 'Green'
        return $true
    } catch {
        Write-Log "   Nicht moeglich: $($_.Exception.Message) - Setup laeuft trotzdem weiter" 'Yellow'
        return $false
    } finally {
        if ($null -eq $alt) { Remove-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value $alt -Type DWord -ErrorAction SilentlyContinue }
    }
}

# ==================================================================
# Vorpruefung
# ==================================================================
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Show-Fehler "winget wurde nicht gefunden.`nBitte 'App Installer' im Microsoft Store installieren/aktualisieren."
    exit 1
}
winget settings --enable LocalManifestFiles 2>$null | Out-Null

$Sprachen = @(
    @{ Name = "Deutsch";                            Code = "de-DE" }
    @{ Name = "English";                            Code = "en-US" }
    @{ Name = "T$([char]0x00FC)rk$([char]0x00E7)e"; Code = "tr-TR" }
    @{ Name = "Standard (Programm entscheidet)";    Code = "" }
)

# ==================================================================
# Befehle (Ordner "befehle", eine Datei pro Befehl: .ps1 / .cmd / .bat)
#   Anzeigename = Dateiname ohne Endung und ohne fuehrende Nummer.
# ==================================================================
function Get-Befehle {
    Get-ChildItem $BefehlDir -File | Where-Object { $_.Extension -in '.ps1','.cmd','.bat' } |
        Sort-Object Name | ForEach-Object {
            [pscustomobject]@{
                Name  = ($_.BaseName -replace '^\d+[\s_-]+', '')
                Datei = $_.Name
                Pfad  = $_.FullName
                Typ   = $_.Extension.TrimStart('.').ToLower()
            }
        }
}
$Tweaks = @(Get-Befehle)

# Fuehrt einen Befehl in einem eigenen Prozess aus, jede Ausgabezeile kommt ins Log.
function Invoke-Befehl($b) {
    Write-Log "   > befehle\$($b.Datei)" 'DarkGray'
    if ($b.Typ -eq 'ps1') {
        $pf = $b.Pfad -replace "'", "''"
        $cmd = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; `$ErrorActionPreference='Stop'; & '$pf'; exit `$LASTEXITCODE"
        $alt = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.Encoding]::UTF8
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { Write-Log "     $_" }
        } finally { [Console]::OutputEncoding = $alt }
    } else {
        & cmd.exe /c call "$($b.Pfad)" 2>&1 | ForEach-Object { Write-Log "     $_" }
    }
    $code = $LASTEXITCODE
    if ($code -eq 0 -or $code -eq 3010 -or $null -eq $code) { return $true }
    Write-Log "   Exit-Code $code" 'Red'
    return $false
}

# Prueft, ob ein Befehl schon erledigt ist (optionaler Pruefteil in der Befehlsdatei).
#   PowerShell: param([switch]$Pruefen) ... if ($Pruefen) { return <$true wenn erledigt> }
#   CMD:        if /i "%~1"=="pruefen" ( exit /b 0 = erledigt / exit /b 1 = nicht erledigt )
# Rueckgabe: $true = erledigt, $false = nicht erledigt, $null = kein Pruefteil / Pruefung fehlgeschlagen
function Test-HatPruefung($b) {
    $inhalt = Get-Content $b.Pfad -Raw -ErrorAction SilentlyContinue
    if ($b.Typ -eq 'ps1') { return $inhalt -match '\$Pruefen\b' }
    return $inhalt -match '(?i)"%~?1"\s*==\s*"pruefen"'
}
function Invoke-BefehlPruefung($b) {
    if (-not (Test-HatPruefung $b)) { return $null }
    if ($b.Typ -eq 'ps1') {
        $pf = $b.Pfad -replace "'", "''"
        $cmd = "try { `$r = & '$pf' -Pruefen } catch { exit 2 }; if ((@(`$r) | Select-Object -Last 1) -eq `$true) { exit 0 } else { exit 1 }"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd *> $null
    } else {
        & cmd.exe /c call "$($b.Pfad)" pruefen *> $null
    }
    switch ($LASTEXITCODE) { 0 { return $true } 1 { return $false } default { return $null } }
}
$BefehlStatus = @{}

# ==================================================================
# Profile (Ordner "profile", eine CSV pro Profil)
#   normale Zeilen          -> Programme (Aktiv 1/0)
#   Kategorie _Einstellung  -> Befehl (letzte Spalte = Dateiname in "befehle")
#   Kategorie _Sprache      -> Sprache (de-DE, en-US, tr-TR, standard)
#   Kategorie _Option       -> restorepoint / restart
# ==================================================================
# Uebernahme der alten apps.csv aus frueheren Versionen
$altCsv = Join-Path $Root "apps.csv"
if ((Test-Path $altCsv) -and -not (Get-ChildItem $ProfilDir -Filter *.csv)) {
    Move-Item $altCsv (Join-Path $ProfilDir "Standard.csv")
}

function Get-ProfilNamen { @(Get-ChildItem $ProfilDir -Filter *.csv | Sort-Object Name | ForEach-Object BaseName) }

function Import-Profil($name) {
    $script:ProfilName = $name
    $script:CsvPfad    = Join-Path $ProfilDir "$name.csv"
    $script:Apps       = New-Object System.Collections.ArrayList
    $script:TweakAktiv = @{}
    $script:Optionen   = @{ restorepoint = $true; restart = $false }
    $sc = 'de-DE'
    foreach ($r in (Import-Csv -Path $CsvPfad -Delimiter ';' -Encoding UTF8)) {
        if (-not $r.Kategorie -or "$($r.Aktiv)".StartsWith('#')) { continue }
        switch ($r.Kategorie) {
            '_Einstellung' { $script:TweakAktiv[$r.WingetID] = ($r.Aktiv -eq '1') }
            '_Sprache'     { $sc = if ($r.WingetID -eq 'standard') { '' } else { $r.WingetID } }
            '_Option'      { $script:Optionen[$r.WingetID] = ($r.Aktiv -eq '1') }
            default {
                if ($r.WingetID) {
                    [void]$script:Apps.Add([pscustomobject]@{ Aktiv=$r.Aktiv; Kategorie=$r.Kategorie; Name=$r.Name; WingetID=$r.WingetID })
                }
            }
        }
    }
    $script:SprachIndex = 0
    for ($i=0; $i -lt $Sprachen.Count; $i++) { if ($Sprachen[$i].Code -eq $sc) { $script:SprachIndex = $i } }
    Set-Content -Path $AktivDatei -Value $name -Encoding UTF8
}

function Test-AppGewaehlt($a)   { $a.Aktiv -eq '1' }
function Test-TweakGewaehlt($t) { [bool]$TweakAktiv[$t.Datei] }

$namen = @(Get-ProfilNamen)
if (-not $namen.Count) { Show-Fehler "Kein Profil gefunden im Ordner:`n$ProfilDir"; exit 1 }
if (-not $Profil -and (Test-Path $AktivDatei)) { $Profil = (Get-Content $AktivDatei -Raw).Trim() }
if (-not $Profil -or $namen -notcontains $Profil) {
    if ($Auto -and $Profil) { Show-Fehler "Profil '$Profil' nicht gefunden. Vorhanden: $($namen -join ', ')"; exit 1 }
    $Profil = if ($namen -contains 'Standard') { 'Standard' } else { $namen[0] }
}
Import-Profil $Profil

# ==================================================================
# Kern: Installation (Fenster UND Automatik)
# ==================================================================
# Fortschrittsanzeige (nur im Fenster)
function Set-Fortschritt($wert, $max) {
    if ($Auto -or -not $script:pbar) { return }
    $script:pbar.Maximum = [Math]::Max(1, $max)
    $script:pbar.Value   = [Math]::Min($wert, $script:pbar.Maximum)
    $script:lblFortschritt.Text = $(if ($max) { "$wert / $max" } else { "" })
    [System.Windows.Forms.Application]::DoEvents()
}

# $probe = $true -> Probelauf: nichts aendern, nur anzeigen, was passieren wuerde
function Start-Installation($appListe, $tweakListe, $loc, $mitRestore, $probe) {
    $sub   = if ($loc) { $loc } else { "standard" }
    $flags = "--silent --accept-package-agreements --accept-source-agreements"
    $ergebnis = @()
    $gesamt = [Diagnostics.Stopwatch]::StartNew()
    $schritte = $appListe.Count + $tweakListe.Count + $(if ($mitRestore) { 1 } else { 0 })
    $schritt = 0
    Set-Fortschritt 0 $schritte

    if ($probe) {
        Write-Log ""
        Write-Log "##### PROBELAUF - es wird NICHTS veraendert #####" 'Magenta'
        Write-Log "Pruefe installierte Programme ..." 'DarkGray'
        $inst = Get-InstallierteIDs
    }

    if ($mitRestore) {
        if ($probe) {
            Write-Log ""
            Write-Log "Wiederherstellungspunkt: wuerde erstellt" 'Cyan'
            $ergebnis += [pscustomobject]@{ Typ="System"; Name="Wiederherstellungspunkt"; Status="wuerde erstellt" }
        } else {
            $ok = New-Wiederherstellungspunkt
            $ergebnis += [pscustomobject]@{ Typ="System"; Name="Wiederherstellungspunkt"; Status=$(if ($ok) { "OK" } else { "Uebersprungen" }) }
        }
        $schritt++; Set-Fortschritt $schritt $schritte
    }

    Write-Log ""
    Write-Log "===== PROGRAMME ($($appListe.Count)) =====" 'Cyan'
    $i = 0
    foreach ($a in $appListe) {
        $i++
        $lokal = Join-Path (Join-Path $InstDir $sub) $a.WingetID
        $quelle = if (Test-Path (Join-Path $lokal "*.yaml")) { "lokaler Installer" } else { "Internet, Sprache: $sub" }
        Write-Log "[$i/$($appListe.Count)] $($a.Name)  ($($a.WingetID), $quelle)" 'White'
        if ($probe) {
            if ($inst.ContainsKey($a.WingetID.ToLower())) { Write-Log "   bereits installiert - wuerde uebersprungen" 'Green'; $status = "bereits installiert" }
            else                                          { Write-Log "   wuerde installiert" 'Yellow'; $status = "wuerde installiert" }
        } else {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            if ($quelle -eq "lokaler Installer") { $code = Invoke-Prozess "winget" "install --manifest `"$lokal`" $flags" }
            else                                 { $code = Invoke-WingetMitFallback "install" $a.WingetID $loc "" $flags }
            $dauer = "{0:n0}s" -f $sw.Elapsed.TotalSeconds
            if ($code -eq 0)                { Write-Log "   OK - installiert ($dauer)" 'Green'; $status = "OK" }
            elseif ($code -eq -1978335189)  { Write-Log "   OK - war bereits installiert/aktuell ($dauer)" 'Green'; $status = "Bereits da" }
            else                            { Write-Log "   FEHLER - Code $code ($dauer)" 'Red'; $status = "FEHLER ($code)" }
        }
        $ergebnis += [pscustomobject]@{ Typ="Programm"; Name=$a.Name; Status=$status }
        $schritt++; Set-Fortschritt $schritt $schritte
    }

    Write-Log ""
    Write-Log "===== EINSTELLUNGEN / BEFEHLE ($($tweakListe.Count)) =====" 'Cyan'
    $i = 0
    foreach ($t in $tweakListe) {
        $i++
        Write-Log "[$i/$($tweakListe.Count)] $($t.Name)" 'White'
        $vorher = Invoke-BefehlPruefung $t
        if ($vorher -eq $true) {
            Write-Log "   $(if ($probe) { 'bereits erledigt - wuerde uebersprungen' } else { 'uebersprungen - bereits erledigt (Pruefung)' })" 'Green'
            $script:BefehlStatus[$t.Datei] = $true
            $ergebnis += [pscustomobject]@{ Typ="Befehl"; Name=$t.Name; Status="Bereits erledigt" }
        } elseif ($probe) {
            $grund = if ($null -eq $vorher) { "kein Pruefteil" } else { "Pruefung: noch nicht erledigt" }
            Write-Log "   wuerde ausgefuehrt ($grund)  -> befehle\$($t.Datei)" 'Yellow'
            $ergebnis += [pscustomobject]@{ Typ="Befehl"; Name=$t.Name; Status="wuerde ausgefuehrt" }
        } else {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try   { $okB = Invoke-Befehl $t } catch { Write-Log "   $_" 'Red'; $okB = $false }
            $dauer = "{0:n0}s" -f $sw.Elapsed.TotalSeconds
            if ($okB) { Write-Log "   OK ($dauer)" 'Green'; $status = "OK" }
            else      { Write-Log "   FEHLER ($dauer)" 'Red'; $status = "FEHLER" }
            if ($okB -and $null -ne $vorher) {
                $nachher = Invoke-BefehlPruefung $t
                $script:BefehlStatus[$t.Datei] = $nachher
                if ($nachher -eq $false) { Write-Log "   Hinweis: Pruefung meldet noch 'nicht erledigt' (evtl. erst nach Neustart wirksam)" 'Yellow' }
            }
            $ergebnis += [pscustomobject]@{ Typ="Befehl"; Name=$t.Name; Status=$status }
        }
        $schritt++; Set-Fortschritt $schritt $schritte
    }

    $fehler = @($ergebnis | Where-Object { $_.Status -like 'FEHLER*' })
    Write-Log ""
    Write-Log "===== ZUSAMMENFASSUNG$(if ($probe) { ' (PROBELAUF)' }) =====" 'Cyan'
    foreach ($e in $ergebnis) {
        $f = if ($e.Status -like 'FEHLER*') { 'Red' } elseif ($e.Status -like 'wuerde*') { 'Yellow' } else { 'Green' }
        Write-Log ("{0,-12} {1,-55} {2}" -f $e.Typ, $e.Name, $e.Status) $f
    }
    Write-Log ("Dauer gesamt: {0:hh\:mm\:ss}" -f $gesamt.Elapsed)
    if ($probe) {
        $n = @($ergebnis | Where-Object { $_.Status -like 'wuerde*' }).Count
        Write-Log "Probelauf beendet: $n Schritt(e) wuerden ausgefuehrt. Es wurde nichts veraendert." 'Magenta'
    } elseif ($fehler.Count) { Write-Log "$($fehler.Count) Fehler - Details siehe oben." 'Red' }
    else { Write-Log "Alles erfolgreich." 'Green' }
    Write-Log "Log-Datei: $LogDatei"
    return $fehler.Count
}

# ==================================================================
# AUTOMATIK-MODUS
# ==================================================================
if ($Auto) {
    $Host.UI.RawUI.WindowTitle = "PC-Setup Automatik - Profil $ProfilName"
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log "===== PC-SETUP AUTOMATIK$(if ($Probelauf) { ' - PROBELAUF' }) =====" 'Cyan'
    Write-Log "System:   $($os.Caption) $($os.Version)"
    Write-Log "Rechner:  $env:COMPUTERNAME   Benutzer: $env:USERNAME"
    Write-Log "Profil:   $ProfilName  (profile\$ProfilName.csv)"
    $loc = $Sprachen[$SprachIndex].Code
    Write-Log "Sprache:  $($Sprachen[$SprachIndex].Name)"
    Write-Log "Optionen: Wiederherstellungspunkt = $($Optionen.restorepoint), Neustart am Ende = $($Optionen.restart)"

    $appListe   = @($Apps   | Where-Object { Test-AppGewaehlt $_ })
    $tweakListe = @($Tweaks | Where-Object { Test-TweakGewaehlt $_ })

    Write-Log ""
    Write-Log "Geplant:" 'Cyan'
    foreach ($a in $appListe)   { Write-Log "   [Programm] $($a.Name)" }
    foreach ($t in $tweakListe) { Write-Log "   [Befehl]   $($t.Name)  (befehle\$($t.Datei))" }
    if (-not $appListe.Count -and -not $tweakListe.Count) {
        Write-Log "Nichts ausgewaehlt. Erst mit Setup.bat eine Auswahl speichern." 'Yellow'
        exit 0
    }
    $anz = Start-Installation $appListe $tweakListe $loc $Optionen.restorepoint $Probelauf

    if ($Optionen.restart -and $Probelauf) { Write-Log "Neustart am Ende: wuerde ausgefuehrt (Probelauf)" 'Magenta' }
    elseif ($Optionen.restart) {
        Write-Log ""
        Write-Log "Neustart in 30 Sekunden - beliebige Taste druecken zum Abbrechen." 'Yellow'
        $abbruch = $false
        for ($s = 30; $s -gt 0; $s--) {
            Write-Host ("`r   Neustart in {0,2} s ... " -f $s) -NoNewline -ForegroundColor Yellow
            if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); $abbruch = $true; break }
            Start-Sleep -Seconds 1
        }
        Write-Host ""
        if ($abbruch) { Write-Log "Neustart abgebrochen." 'Yellow' }
        else { Write-Log "Starte neu ..." 'Yellow'; Restart-Computer -Force }
    }
    exit ([int]($anz -gt 0))
}

# ==================================================================
# FENSTER-MODUS
# ==================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "PC-Setup"
$form.Size = New-Object System.Drawing.Size(780,810)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI",9.5)
$fett = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$script:laden = $true

function New-Ctrl($typ, $text, $x, $y, $w, $h) {
    $c = New-Object "System.Windows.Forms.$typ"
    if ($text) { $c.Text = $text }
    $c.Location = "$x,$y"
    if ($w) { $c.Size = "$w,$h" } else { $c.AutoSize = $true }
    return $c
}
function Ask-JaNein($text, $titel) {
    ([System.Windows.Forms.MessageBox]::Show($text, $titel, 'YesNo', 'Question')) -eq 'Yes'
}

$tabs = New-Ctrl TabControl "" 8 8 748 455
$tabAusw  = New-Object System.Windows.Forms.TabPage; $tabAusw.Text  = "Auswahl"
$tabSuche = New-Object System.Windows.Forms.TabPage; $tabSuche.Text = "Programme suchen / hinzufuegen"
$tabAlt   = New-Object System.Windows.Forms.TabPage; $tabAlt.Text   = "Vom alten PC uebernehmen"
$tabNetz  = New-Object System.Windows.Forms.TabPage; $tabNetz.Text  = "Netzlaufwerke"
$tabs.TabPages.AddRange(@($tabAusw,$tabSuche,$tabAlt,$tabNetz))

# ---------------- Reiter 1: Auswahl ----------------
$lblApps = New-Ctrl Label "Programme" 8 6; $lblApps.Font = $fett
$chkStartPruef = New-Ctrl CheckBox "Status beim Start automatisch pruefen" 150 5
$tabAusw.Controls.Add($chkStartPruef)
$treeApps = New-Ctrl TreeView "" 8 30 390 345
$treeApps.CheckBoxes = $true; $treeApps.HideSelection = $false
$btnEntf   = New-Ctrl Button "Entfernen"          8   382 125 30
$btnStatus = New-Ctrl Button "Status pruefen"     138 382 125 30
$btnUpdate = New-Ctrl Button "Alle aktualisieren" 268 382 130 30

$lblTw = New-Ctrl Label "Einstellungen / Befehle" 408 6; $lblTw.Font = $fett
$listTw = New-Ctrl ListView "" 408 30 322 310
$listTw.View = 'Details'; $listTw.CheckBoxes = $true; $listTw.FullRowSelect = $true
$listTw.HeaderStyle = 'None'; $listTw.MultiSelect = $false; $listTw.HideSelection = $false
[void]$listTw.Columns.Add("Befehl", 400)
$btnBNeu   = New-Ctrl Button "Neu"            408 346 100 30
$btnBEdit  = New-Ctrl Button "Bearbeiten"     519 346 100 30
$btnBDel   = New-Ctrl Button "Loeschen"       630 346 100 30
$btnBTest  = New-Ctrl Button "Jetzt testen"   408 382 155 30
$btnBOrdn  = New-Ctrl Button "Ordner oeffnen" 575 382 155 30
$tabAusw.Controls.AddRange(@($lblApps,$treeApps,$btnEntf,$btnStatus,$btnUpdate,$lblTw,$listTw,$btnBNeu,$btnBEdit,$btnBDel,$btnBTest,$btnBOrdn))

# ---- Befehlsliste ----
function Update-BefehlListe($merken) {
    $script:Tweaks = @(Get-Befehle)
    $listTw.Items.Clear()
    foreach ($t in $Tweaks) {
        $an = if ($merken -and $merken.ContainsKey($t.Datei)) { $merken[$t.Datei] } else { Test-TweakGewaehlt $t }
        $txt = if ($BefehlStatus[$t.Datei] -eq $true) { "$($t.Name)   [erledigt]" } else { $t.Name }
        $it = New-Object System.Windows.Forms.ListViewItem($txt)
        $it.Checked = [bool]$an
        if ($BefehlStatus[$t.Datei] -eq $true) { $it.ForeColor = [System.Drawing.Color]::Green }
        [void]$listTw.Items.Add($it)
    }
}
function Update-BefehlStatus {
    Write-Log "Pruefe, welche Befehle schon erledigt sind ..."
    $mit = 0; $erl = 0
    foreach ($t in $Tweaks) {
        $s = Invoke-BefehlPruefung $t
        $script:BefehlStatus[$t.Datei] = $s
        if ($null -ne $s) { $mit++ }
        if ($s -eq $true) { $erl++ }
        [System.Windows.Forms.Application]::DoEvents()
    }
    Update-BefehlListe (Get-BefehlHaken)
    Write-Log "   $erl von $mit pruefbaren Befehlen sind bereits erledigt ([erledigt] - werden beim Installieren uebersprungen)."
}
function Get-BefehlHaken {
    $h = @{}
    for ($j=0; $j -lt $Tweaks.Count; $j++) { $h[$Tweaks[$j].Datei] = $listTw.Items[$j].Checked }
    return $h
}

# ---- Editor-Fenster fuer einen Befehl ----
function Show-BefehlEditor($b) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $(if ($b) { "Befehl bearbeiten" } else { "Neuer Befehl" })
    $dlg.Size = New-Object System.Drawing.Size(760,600); $dlg.StartPosition = 'CenterParent'
    $dlg.Font = $form.Font

    $l1 = New-Ctrl Label "Nr.:" 10 14
    $txtNr = New-Ctrl TextBox "" 45 10 50 26
    $l2 = New-Ctrl Label "Name:" 105 14
    $txtName = New-Ctrl TextBox "" 155 10 360 26
    $l3 = New-Ctrl Label "Typ:" 528 14
    $cbTyp = New-Ctrl ComboBox "" 565 10 165 28
    $cbTyp.DropDownStyle = 'DropDownList'
    [void]$cbTyp.Items.AddRange(@("PowerShell (.ps1)","CMD (.cmd)"))
    $l4 = New-Ctrl Label "Nr. = Reihenfolge (z.B. 75). Kein 'pause' verwenden. Fehler: in PowerShell 'throw', in CMD 'exit /b 1'." 10 44
    $l4.ForeColor = [System.Drawing.Color]::Gray
    $txtCode = New-Ctrl TextBox "" 10 68 722 440
    $txtCode.Multiline = $true; $txtCode.AcceptsReturn = $true; $txtCode.AcceptsTab = $true
    $txtCode.ScrollBars = 'Both'; $txtCode.WordWrap = $false
    $txtCode.Font = New-Object System.Drawing.Font("Consolas",10)
    $bOk = New-Ctrl Button "Speichern" 520 518 100 32
    $bAb = New-Ctrl Button "Abbrechen" 630 518 100 32
    $bAb.DialogResult = 'Cancel'; $dlg.CancelButton = $bAb
    $dlg.Controls.AddRange(@($l1,$txtNr,$l2,$txtName,$l3,$cbTyp,$l4,$txtCode,$bOk,$bAb))

    if ($b) {
        if ($b.Datei -match '^(\d+)[\s_-]+') { $txtNr.Text = $Matches[1] }
        $txtName.Text = $b.Name
        $cbTyp.SelectedIndex = $(if ($b.Typ -eq 'ps1') { 0 } else { 1 })
        $txtCode.Text = (Get-Content $b.Pfad -Raw -Encoding $(if ($b.Typ -eq 'ps1') { 'UTF8' } else { 'Default' })) -replace "`r?`n", "`r`n"
    } else {
        $txtNr.Text = "90"; $cbTyp.SelectedIndex = 0
        $txtCode.Text = ("# Beschreibung: ...`r`nparam([switch]`$Pruefen)`r`n`r`n" +
            "# --- Pruefung (optional) ---------------------------------------`r`n" +
            "# `$true zurueckgeben, wenn der Befehl schon erledigt ist -> wird dann uebersprungen.`r`n" +
            "# Ohne Pruefung: diesen Block und die param-Zeile loeschen.`r`n" +
            "if (`$Pruefen) {`r`n    return `$false`r`n}`r`n`r`n" +
            "# --- Befehl -----------------------------------------------------`r`n" +
            "Write-Host `"Mache etwas ...`"`r`n")
    }
    $cbTyp.Add_SelectedIndexChanged({
        if (-not $b -and $cbTyp.SelectedIndex -eq 1 -and $txtCode.Text -like '# Beschreibung*') {
            $txtCode.Text = ("@echo off`r`nrem Beschreibung: ...`r`n`r`n" +
                "rem --- Pruefung (optional): exit /b 0 = schon erledigt, exit /b 1 = noch nicht ---`r`n" +
                "rem Ohne Pruefung: diesen Block loeschen.`r`n" +
                "if /i `"%~1`"==`"pruefen`" (`r`n    exit /b 1`r`n)`r`n`r`n" +
                "rem --- Befehl ---`r`necho Mache etwas ...`r`n")
        }
    })
    $bOk.Add_Click({
        $name = ($txtName.Text.Trim() -replace '[\\/:*?"<>|]', '-')
        if (-not $name) { [System.Windows.Forms.MessageBox]::Show("Bitte einen Namen eingeben.") | Out-Null; return }
        $nr  = ($txtNr.Text.Trim() -replace '\D', '')
        $ext = $(if ($cbTyp.SelectedIndex -eq 0) { '.ps1' } else { '.cmd' })
        $datei = $(if ($nr) { "$nr $name$ext" } else { "$name$ext" })
        $pfad  = Join-Path $BefehlDir $datei
        if ((Test-Path $pfad) -and (-not $b -or $b.Datei -ne $datei)) {
            [System.Windows.Forms.MessageBox]::Show("Es gibt schon einen Befehl '$datei'.") | Out-Null; return
        }
        if ($ext -eq '.ps1') { Set-Content -Path $pfad -Value $txtCode.Text -Encoding UTF8 -NoNewline }
        else                 { Set-Content -Path $pfad -Value $txtCode.Text -Encoding Default -NoNewline }
        if ($b -and $b.Datei -ne $datei) { Remove-Item $b.Pfad -Force }
        $script:EditorErgebnis = @{ Alt = $(if ($b) { $b.Datei }); Neu = $datei }
        $dlg.DialogResult = 'OK'; $dlg.Close()
    })
    $script:EditorErgebnis = $null
    [void]$dlg.ShowDialog($form)
    return $script:EditorErgebnis
}

function Get-MarkierterBefehl {
    $i = if ($listTw.SelectedIndices.Count) { $listTw.SelectedIndices[0] } else { -1 }
    if ($i -lt 0) { Write-Log "Bitte zuerst rechts einen Befehl anklicken."; return $null }
    return $Tweaks[$i]
}
$btnBNeu.Add_Click({
    $h = Get-BefehlHaken
    $r = Show-BefehlEditor $null
    if ($r) { $h[$r.Neu] = $true; Update-BefehlListe $h; Write-Log "Befehl angelegt: befehle\$($r.Neu)  (mit 'Speichern' Haken uebernehmen)" }
})
$btnBEdit.Add_Click({
    $b = Get-MarkierterBefehl; if (-not $b) { return }
    $h = Get-BefehlHaken
    $r = Show-BefehlEditor $b
    if ($r) { $h[$r.Neu] = $h[$r.Alt]; Update-BefehlListe $h; Write-Log "Befehl gespeichert: befehle\$($r.Neu)" }
})
$btnBDel.Add_Click({
    $b = Get-MarkierterBefehl; if (-not $b) { return }
    $a = [System.Windows.Forms.MessageBox]::Show("Befehl '$($b.Name)' wirklich loeschen?`n(Datei: befehle\$($b.Datei))", "Loeschen", 'YesNo', 'Warning')
    if ($a -ne 'Yes') { return }
    $h = Get-BefehlHaken
    Remove-Item $b.Pfad -Force
    Update-BefehlListe $h
    Write-Log "Befehl geloescht: befehle\$($b.Datei)"
})
$btnBTest.Add_Click({
    $b = Get-MarkierterBefehl; if (-not $b) { return }
    if (-not (Ask-JaNein "'$($b.Name)' jetzt auf diesem PC ausfuehren?" "Testen")) { return }
    Set-Sperre $true
    Write-Log "TEST: $($b.Name)"
    $ok = $false
    try { $ok = Invoke-Befehl $b } catch { Write-Log "   $_" }
    Write-Log $(if ($ok) { "   OK" } else { "   FEHLER" })
    $s = Invoke-BefehlPruefung $b
    $script:BefehlStatus[$b.Datei] = $s
    if ($null -ne $s) { Write-Log "   Pruefung: $(if ($s) { 'erledigt' } else { 'noch nicht erledigt' })" }
    Update-BefehlListe (Get-BefehlHaken)
    Set-Sperre $false
})
$btnBOrdn.Add_Click({ Start-Process explorer.exe $BefehlDir })

# ---- Programmbaum ----
$script:busy = $false
$script:Installiert = $null
function Update-KatStatus($kat) {
    $script:busy = $true
    $kat.Checked = ($kat.Nodes.Count -gt 0) -and (@($kat.Nodes | Where-Object { -not $_.Checked }).Count -eq 0)
    $script:busy = $false
}
function Set-NodeStatus($n) {
    $inst = $script:Installiert -and $script:Installiert.ContainsKey($n.Tag.WingetID.ToLower())
    $n.Text      = $(if ($inst) { "$($n.Tag.Name)   [installiert]" } else { $n.Tag.Name })
    $n.ForeColor = $(if ($inst) { [System.Drawing.Color]::Green } else { [System.Drawing.SystemColors]::WindowText })
}
function Add-AppNode($a) {
    $kat = $null
    foreach ($k in $treeApps.Nodes) { if ($k.Text -eq $a.Kategorie) { $kat = $k } }
    if (-not $kat) { $kat = $treeApps.Nodes.Add($a.Kategorie) }
    $n = $kat.Nodes.Add($a.Name)
    $n.Tag = $a
    $script:busy = $true; $n.Checked = (Test-AppGewaehlt $a); $script:busy = $false
    Set-NodeStatus $n
    Update-KatStatus $kat
    $kat.Expand()
    return $n
}
function Update-StatusAnzeige {
    foreach ($k in $treeApps.Nodes) { foreach ($c in $k.Nodes) { Set-NodeStatus $c } }
}
function Update-Status {
    Write-Log "Pruefe, welche Programme installiert sind ..."
    $form.Cursor = 'WaitCursor'
    $script:Installiert = Get-InstallierteIDs
    Update-StatusAnzeige
    $form.Cursor = 'Default'
    $n = @($Apps | Where-Object { $script:Installiert.ContainsKey($_.WingetID.ToLower()) }).Count
    Write-Log "   $n von $($Apps.Count) Programmen der Liste sind installiert (gruen markiert)."
}

$treeApps.Add_AfterCheck({
    param($s,$e)
    if ($script:busy) { return }
    $script:busy = $true
    if ($e.Node.Nodes.Count -gt 0) { foreach ($c in $e.Node.Nodes) { $c.Checked = $e.Node.Checked } }
    $script:busy = $false
    if ($e.Node.Parent) { Update-KatStatus $e.Node.Parent }
})
$btnEntf.Add_Click({
    $n = $treeApps.SelectedNode
    if (-not $n -or -not $n.Parent) { Write-Log "Bitte zuerst ein Programm (nicht die Kategorie) anklicken."; return }
    $kat = $n.Parent
    $Apps.Remove($n.Tag)
    $kat.Nodes.Remove($n)
    if ($kat.Nodes.Count -eq 0) { $treeApps.Nodes.Remove($kat) } else { Update-KatStatus $kat }
    Write-Log "Entfernt: $($n.Tag.Name)  (mit 'Speichern' dauerhaft uebernehmen)"
})
$btnStatus.Add_Click({ Set-Sperre $true; Update-Status; Update-BefehlStatus; Set-Sperre $false })
$btnUpdate.Add_Click({
    if (-not (Ask-JaNein "Alle installierten Programme mit verfuegbarem Update jetzt aktualisieren (winget upgrade --all)?" "Aktualisieren")) { return }
    Set-Sperre $true
    Write-Log ""
    Write-Log "===== ALLE PROGRAMME AKTUALISIEREN ====="
    $code = Invoke-Prozess "winget" "upgrade --all --silent --accept-package-agreements --accept-source-agreements"
    Write-Log $(if ($code -eq 0) { "   Fertig." } else { "   Beendet mit Code $code (einzelne Updates evtl. fehlgeschlagen)." })
    Update-Status
    Set-Sperre $false
})

# ---------------- Reiter 2: Suche ----------------
$lblS1 = New-Ctrl Label "Suche (Regex auf Name und ID, z.B.  ^Mozilla\.  oder  obs|vlc|gimp ):" 8 8
$txtSuche = New-Ctrl TextBox "" 8 32 600 26
$btnSuche = New-Ctrl Button "Suchen" 615 30 115 30
$lblTreffer = New-Ctrl Label "" 8 64; $lblTreffer.ForeColor = [System.Drawing.Color]::Gray
$lv = New-Ctrl ListView "" 8 86 722 290
$lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true
[void]$lv.Columns.Add("Name",300); [void]$lv.Columns.Add("ID",280); [void]$lv.Columns.Add("Version",120)
$lblKat  = New-Ctrl Label "Kategorie:" 8 389
$comboKat = New-Ctrl ComboBox "" 80 385 200 28
$comboKat.DropDownStyle = 'DropDown'
$btnAdd = New-Ctrl Button "Angehakte zum Baum hinzufuegen" 290 383 260 30
$btnLvAlle = New-Ctrl Button "Alle/keine anhaken" 560 383 170 30
$tabSuche.Controls.AddRange(@($lblS1,$txtSuche,$btnSuche,$lblTreffer,$lv,$lblKat,$comboKat,$btnAdd,$btnLvAlle))

function Add-LvItem($p, $anhaken) {
    $schon = @($Apps | ForEach-Object { $_.WingetID.ToLower() }) -contains $p.WingetID.ToLower()
    $it = New-Object System.Windows.Forms.ListViewItem($(if ($schon) { "$($p.Name)  (bereits im Baum)" } else { $p.Name }))
    [void]$it.SubItems.Add($p.WingetID); [void]$it.SubItems.Add($p.Version)
    $it.Tag = $p
    if ($schon) { $it.ForeColor = [System.Drawing.Color]::Gray } else { $it.Checked = [bool]$anhaken }
    [void]$lv.Items.Add($it)
}

$btnSuche.Add_Click({
    $muster = $txtSuche.Text.Trim()
    if (-not $muster) { return }
    try { $rx = New-Object System.Text.RegularExpressions.Regex($muster, 'IgnoreCase') }
    catch { $lblTreffer.Text = "Ungueltiger Regex: $($_.Exception.Message)"; return }
    # winget kennt keinen Regex -> Woerter aus dem Muster suchen, danach mit Regex filtern
    $woerter = @([regex]::Matches($muster, '[A-Za-z0-9]{2,}') | ForEach-Object Value | Sort-Object Length -Descending -Unique)
    $lang = @($woerter | Where-Object { $_.Length -ge 3 })
    $begriffe = @($(if ($lang.Count) { $lang } else { $woerter }) | Select-Object -First 5)
    if (-not $begriffe.Count) { $lblTreffer.Text = "Der Regex braucht mindestens 2 Buchstaben/Ziffern am Stueck."; return }

    $form.Cursor = 'WaitCursor'; $btnSuche.Enabled = $false
    $lv.Items.Clear()
    $lblTreffer.Text = "Suche bei winget nach: $($begriffe -join ', ') ..."
    [System.Windows.Forms.Application]::DoEvents()
    $gefunden = @{}
    foreach ($b in $begriffe) {
        foreach ($p in (Get-WingetTabelle @('search','--query',$b,'--source','winget','--accept-source-agreements'))) {
            if (-not $gefunden.ContainsKey($p.WingetID) -and ($rx.IsMatch($p.Name) -or $rx.IsMatch($p.WingetID))) {
                $gefunden[$p.WingetID] = $p
            }
        }
    }
    foreach ($p in ($gefunden.Values | Sort-Object Name)) { Add-LvItem $p $false }
    $lblTreffer.Text = "$($gefunden.Count) Treffer (winget-Suche: $($begriffe -join ', '), gefiltert mit Regex)"
    $form.Cursor = 'Default'; $btnSuche.Enabled = $true
})
$txtSuche.Add_KeyDown({ param($s,$e) if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; $btnSuche.PerformClick() } })
$btnLvAlle.Add_Click({
    $frei = @($lv.Items | Where-Object { $_.ForeColor -ne [System.Drawing.Color]::Gray })
    $ziel = @($frei | Where-Object { -not $_.Checked }).Count -gt 0
    foreach ($it in $frei) { $it.Checked = $ziel }
})
$btnAdd.Add_Click({
    $kat = $comboKat.Text.Trim().TrimStart('_'); if (-not $kat) { $kat = "Sonstiges" }
    $neu = 0
    foreach ($it in @($lv.CheckedItems)) {
        $p = $it.Tag
        if (@($Apps | ForEach-Object { $_.WingetID.ToLower() }) -contains $p.WingetID.ToLower()) { continue }
        $a = [pscustomobject]@{ Aktiv='1'; Kategorie=$kat; Name=($p.Name -replace ';',','); WingetID=$p.WingetID }
        [void]$Apps.Add($a)
        [void](Add-AppNode $a)
        $it.Checked = $false; $it.ForeColor = [System.Drawing.Color]::Gray; $it.Text = "$($p.Name)  (bereits im Baum)"
        Write-Log "Hinzugefuegt: $($a.Name) ($($a.WingetID)) -> Kategorie '$kat'"
        $neu++
    }
    if (-not $comboKat.Items.Contains($kat)) { [void]$comboKat.Items.Add($kat) }
    if ($neu) { Write-Log "   $neu Programm(e) im Baum angehakt. Mit 'Speichern' dauerhaft ins Profil uebernehmen." }
    else      { Write-Log "Nichts hinzugefuegt (nichts angehakt oder schon vorhanden)." }
})

# ---------------- Reiter 3: Vom alten PC uebernehmen ----------------
$lblAlt = New-Ctrl Label ("Diese Funktionen auf dem ALTEN PC ausfuehren, bevor er neu aufgesetzt wird.`r`n" +
    "Danach 'Speichern' klicken und den Ordner PC-Setup (bzw. die Flipper-Datei) mitnehmen.") 8 10
$grpP = New-Ctrl GroupBox "1. Installierte Programme" 8 60 722 130
$lblP = New-Ctrl Label ("Liest alle installierten Programme aus, die es bei winget gibt, und zeigt sie im Reiter`r`n" +
    "'Programme suchen / hinzufuegen'. Neue sind angehakt - Kategorie waehlen und hinzufuegen.`r`n" +
    "Programme, die winget nicht kennt (z.B. Spezialsoftware), muessen manuell installiert werden.") 12 24
$btnAltProg = New-Ctrl Button "Installierte Programme einlesen" 12 88 260 30
$grpP.Controls.AddRange(@($lblP,$btnAltProg))

$grpW = New-Ctrl GroupBox "2. WLAN-Profile mit Passwoertern" 8 200 722 200
$lblW = New-Ctrl Label ("Exportiert alle gespeicherten WLANs inkl. Passwort in den Ordner 'wlan'.`r`n" +
    "Auf dem neuen PC importiert der Befehl 'WLAN-Profile importieren' sie wieder.`r`n" +
    "Firmen-WLANs mit Benutzername/Zertifikat (802.1X) werden ohne Zugangsdaten uebernommen.") 12 24
$lblWarn = New-Ctrl Label ("ACHTUNG: Die Passwoerter stehen im Klartext in den Dateien - auch in der Flipper-Datei.`r`n" +
    "Ordner/Flipper-SD nicht weitergeben. Nach dem Einrichten 'wlan' leeren.") 12 88
$lblWarn.ForeColor = [System.Drawing.Color]::DarkRed
$btnWlanExp  = New-Ctrl Button "WLAN-Profile exportieren" 12 135 220 30
$btnWlanOrdn = New-Ctrl Button "Ordner oeffnen" 240 135 140 30
$btnWlanDel  = New-Ctrl Button "Exportierte loeschen" 388 135 170 30
$lblWlanAnz  = New-Ctrl Label "" 12 172; $lblWlanAnz.ForeColor = [System.Drawing.Color]::Gray
$grpW.Controls.AddRange(@($lblW,$lblWarn,$btnWlanExp,$btnWlanOrdn,$btnWlanDel,$lblWlanAnz))
$tabAlt.Controls.AddRange(@($lblAlt,$grpP,$grpW))

# Frueher versehentlich im Hauptordner gelandete WLAN-Exporte in den Ordner "wlan" verschieben
function Move-WlanAusHauptordner {
    foreach ($f in @(Get-ChildItem $Root -Filter *.xml -File -ErrorAction SilentlyContinue)) {
        if ((Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue) -match '<WLANProfile') {
            New-Item -ItemType Directory -Path $WlanDir -Force | Out-Null
            Move-Item $f.FullName (Join-Path $WlanDir $f.Name) -Force
        }
    }
}
function Update-WlanAnzeige {
    $n = @(Get-ChildItem $WlanDir -Filter *.xml -ErrorAction SilentlyContinue).Count
    $lblWlanAnz.Text = "Im Ordner 'wlan' liegen aktuell $n WLAN-Profil(e)."
}

$btnAltProg.Add_Click({
    Set-Sperre $true; $form.Cursor = 'WaitCursor'
    Write-Log "Lese installierte Programme ein (winget export + winget list) ..."
    $ids   = Get-InstallierteIDs
    $liste = @(Get-WingetTabelle @('list','--source','winget','--accept-source-agreements'))
    $lv.Items.Clear()
    $neu = 0
    foreach ($id in ($ids.Values | Sort-Object)) {
        $e = $liste | Where-Object { $_.WingetID -eq $id } | Select-Object -First 1
        if (-not $e) {   # ID in der Tabelle abgeschnitten?
            $e = $liste | Where-Object { $_.WingetID.EndsWith($Ell) -and $id.StartsWith($_.WingetID.TrimEnd($Ell)) } | Select-Object -First 1
        }
        $name = if ($e -and $e.Name) { $e.Name.TrimEnd($Ell).Trim() } else { $id }
        $p = [pscustomobject]@{ Name=$name; WingetID=$id; Version=$(if ($e) { $e.Version } else { '' }) }
        Add-LvItem $p $true
        if (-not (@($Apps | ForEach-Object { $_.WingetID.ToLower() }) -contains $id.ToLower())) { $neu++ }
    }
    $lblTreffer.Text = "$($ids.Count) installierte Programme gefunden, davon $neu neu (angehakt)."
    Write-Log "   $($ids.Count) Programme gefunden, $neu davon sind noch nicht im Baum."
    $comboKat.Text = "Vom alten PC"
    $tabs.SelectedTab = $tabSuche
    $form.Cursor = 'Default'; Set-Sperre $false
})

$btnWlanExp.Add_Click({
    $t = "Alle WLAN-Profile werden MIT PASSWORT IM KLARTEXT in den Ordner 'wlan' exportiert.`n`nFortfahren?"
    if ([System.Windows.Forms.MessageBox]::Show($t, "WLAN-Export", 'YesNo', 'Warning') -ne 'Yes') { return }
    New-Item -ItemType Directory -Path $WlanDir -Force | Out-Null
    Write-Log "netsh wlan export profile key=clear  (Ziel: $WlanDir)"
    Push-Location $WlanDir     # netsh exportiert ins aktuelle Verzeichnis
    try {
        & netsh.exe wlan export profile key=clear 2>&1 | ForEach-Object { if ("$_".Trim()) { Write-Log "   $_" } }
    } finally { Pop-Location }
    Move-WlanAusHauptordner
    Update-WlanAnzeige
    Write-Log "   $($lblWlanAnz.Text)"
})
$btnWlanOrdn.Add_Click({ New-Item -ItemType Directory -Path $WlanDir -Force | Out-Null; Start-Process explorer.exe $WlanDir })
$btnWlanDel.Add_Click({
    if (-not (Ask-JaNein "Alle exportierten WLAN-Dateien im Ordner 'wlan' loeschen?" "WLAN")) { return }
    Remove-Item (Join-Path $WlanDir "*.xml") -Force -ErrorAction SilentlyContinue
    Update-WlanAnzeige
    Write-Log "Exportierte WLAN-Profile geloescht."
})

# ---------------- Reiter 4: Netzlaufwerke ----------------
$lblN = New-Ctrl Label ("Netzlaufwerke und Zugangsdaten (z.B. NAS). 'Vom PC einlesen' uebernimmt Laufwerke, Pfade und Benutzer`r`n" +
    "vom aktuellen PC - Passwoerter gibt Windows nicht heraus, die bitte einmal eintragen. Leerer Laufwerksbuchstabe = nur Zugangsdaten.") 8 6
$grid = New-Ctrl DataGridView "" 8 46 722 262
$grid.AllowUserToAddRows = $true; $grid.RowHeadersWidth = 24
$grid.AutoSizeColumnsMode = 'Fill'; $grid.SelectionMode = 'FullRowSelect'
foreach ($c in @(@("Laufwerk",12),@("Pfad",45),@("Benutzer",22),@("Passwort",21))) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $c[0]; $col.HeaderText = $c[0]; $col.FillWeight = $c[1]
    [void]$grid.Columns.Add($col)
}
$chkPwZeigen = New-Ctrl CheckBox "Passwoerter anzeigen" 8 314
$btnNEin   = New-Ctrl Button "Vom PC einlesen"  8   340 160 30
$btnNDel   = New-Ctrl Button "Zeile loeschen"   174 340 130 30
$btnNSave  = New-Ctrl Button "Speichern"        310 340 120 30
$btnCred   = New-Ctrl Button "Windows-Anmeldeinformationen ..." 470 340 260 30
$lblNWarn = New-Ctrl Label ("ACHTUNG: Passwoerter stehen im Klartext in netzlaufwerke.csv und in der Flipper-Datei.`r`n" +
    "Auf dem neuen PC den Befehl 'Netzlaufwerke verbinden' anhaken.") 8 378
$lblNWarn.ForeColor = [System.Drawing.Color]::DarkRed
$tabNetz.Controls.AddRange(@($lblN,$grid,$chkPwZeigen,$btnNEin,$btnNDel,$btnNSave,$btnCred,$lblNWarn))

# Passwort-Spalte verdecken
$grid.Add_CellFormatting({
    param($s,$e)
    if ($e.ColumnIndex -eq 3 -and -not $chkPwZeigen.Checked -and $e.Value) {
        $e.Value = [string]([char]0x25CF) * ([string]$e.Value).Length; $e.FormattingApplied = $true
    }
})
$grid.Add_EditingControlShowing({
    param($s,$e)
    $tb = $e.Control -as [System.Windows.Forms.TextBox]
    if ($tb) { $tb.UseSystemPasswordChar = ($grid.CurrentCell.ColumnIndex -eq 3 -and -not $chkPwZeigen.Checked) }
})
$chkPwZeigen.Add_CheckedChanged({ $grid.Invalidate() })

function Add-NetzZeile($lw, $pfad, $user, $pw) { [void]$grid.Rows.Add($lw, $pfad, $user, $pw) }
function Import-Netzlaufwerke {
    $grid.Rows.Clear()
    if (Test-Path $NetzDatei) {
        foreach ($e in (Import-Csv $NetzDatei -Delimiter ';' -Encoding UTF8)) { Add-NetzZeile $e.Laufwerk $e.Pfad $e.Benutzer $e.Passwort }
    }
}
function Get-NetzZeilen {
    foreach ($r in $grid.Rows) {
        if ($r.IsNewRow) { continue }
        $pfad = "$($r.Cells[1].Value)".Trim()
        if (-not $pfad) { continue }
        $lw = "$($r.Cells[0].Value)".Trim().ToUpper().TrimEnd(':')
        [pscustomobject]@{
            Laufwerk = $(if ($lw) { "$($lw.Substring(0,1)):" } else { '' })
            Pfad     = $pfad
            Benutzer = "$($r.Cells[2].Value)".Trim()
            Passwort = "$($r.Cells[3].Value)"
        }
    }
}

# Laufwerke + Benutzer vom aktuellen PC lesen (Passwoerter sind nicht auslesbar)
function Get-NetzlaufwerkeVomPC {
    $creds = @{}; $ziel = $null
    foreach ($l in @(cmdkey.exe /list 2>$null)) {
        if ($l -match '(?i)target=(.+)$') {
            $ziel = $Matches[1].Trim()
            if ($l -notmatch '(?i)Domain:target=' -or $ziel -match '/') { $ziel = $null }
        } elseif ($ziel -and $l -match '^\s*(Benutzer|User)\s*:\s*(.+)$') {
            $creds[$ziel.ToLower()] = $Matches[2].Trim(); $ziel = $null
        }
    }
    $maps = @{}
    foreach ($k in @(Get-ChildItem "HKCU:\Network" -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $k.PSPath
        $maps["$($k.PSChildName.ToUpper()):"] = @{ Pfad = $p.RemotePath; User = $p.UserName }
    }
    try {
        foreach ($m in @(Get-SmbMapping -ErrorAction Stop)) {
            if ($m.LocalPath -and -not $maps.ContainsKey($m.LocalPath.ToUpper())) { $maps[$m.LocalPath.ToUpper()] = @{ Pfad = $m.RemotePath; User = '' } }
        }
    } catch {}
    $erg = @(); $mitLw = @{}
    foreach ($lw in ($maps.Keys | Sort-Object)) {
        $srv = ("$($maps[$lw].Pfad)" -split '\\')[2]
        $u = $maps[$lw].User
        if (-not $u -and $srv -and $creds.ContainsKey($srv.ToLower())) { $u = $creds[$srv.ToLower()] }
        $erg += [pscustomobject]@{ Laufwerk=$lw; Pfad=$maps[$lw].Pfad; Benutzer="$u" }
        if ($srv) { $mitLw[$srv.ToLower()] = $true }
    }
    foreach ($c in $creds.Keys) {
        if (-not $mitLw.ContainsKey($c)) { $erg += [pscustomobject]@{ Laufwerk=''; Pfad="\\$c"; Benutzer=$creds[$c] } }
    }
    return $erg
}

$btnNEin.Add_Click({
    Write-Log "Lese Netzlaufwerke und gespeicherte Zugangsdaten ein ..."
    $vorh = @(Get-NetzZeilen | ForEach-Object { "$($_.Laufwerk)|$($_.Pfad)".ToLower() })
    $neu = 0
    foreach ($e in (Get-NetzlaufwerkeVomPC)) {
        if ($vorh -contains "$($e.Laufwerk)|$($e.Pfad)".ToLower()) { continue }
        Add-NetzZeile $e.Laufwerk $e.Pfad $e.Benutzer ''
        Write-Log "   $(if ($e.Laufwerk) { $e.Laufwerk } else { '(nur Zugangsdaten)' })  $($e.Pfad)  Benutzer: $(if ($e.Benutzer) { $e.Benutzer } else { '-' })"
        $neu++
    }
    Write-Log "   $neu neue Eintraege. Passwoerter eintragen und 'Speichern' klicken."
})
$btnNDel.Add_Click({
    foreach ($r in @($grid.SelectedRows)) { if (-not $r.IsNewRow) { $grid.Rows.Remove($r) } }
})
$btnNSave.Add_Click({
    $grid.EndEdit()
    $z = @(Get-NetzZeilen)
    if ($z.Count) { $z | Export-Csv $NetzDatei -Delimiter ';' -NoTypeInformation -Encoding UTF8 }
    else { Remove-Item $NetzDatei -ErrorAction SilentlyContinue }
    $ohne = @($z | Where-Object { $_.Benutzer -and -not $_.Passwort }).Count
    Write-Log "Netzlaufwerke gespeichert: $($z.Count) Eintraege -> netzlaufwerke.csv"
    if ($ohne) { Write-Log "   Hinweis: $ohne Eintrag/Eintraege mit Benutzer, aber ohne Passwort." }
    Import-Netzlaufwerke
})
$btnCred.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(("Es oeffnet sich die Windows-Anmeldeinformationsverwaltung.`n`n" +
        "Dort unter 'Windows-Anmeldeinformationen':`n" +
        " - 'Anmeldeinformationen sichern' -> alle gespeicherten Zugangsdaten in eine verschluesselte .crd-Datei`n" +
        " - 'Anmeldeinformationen wiederherstellen' -> auf dem neuen PC wieder einlesen`n`n" +
        "Windows verlangt dabei einmal Strg+Alt+Entf und ein Passwort fuer die Datei."), "Windows-Anmeldeinformationen") | Out-Null
    Start-Process control.exe "/name Microsoft.CredentialManager"
})

# ---------------- unterer Bereich ----------------
$lblProf = New-Ctrl Label "Profil:" 12 476
$comboProf = New-Ctrl ComboBox "" 60 472 170 28
$comboProf.DropDownStyle = 'DropDownList'
$btnProfNeu = New-Ctrl Button "Neues Profil"   238 470 115 30
$btnProfDel = New-Ctrl Button "Profil loeschen" 358 470 115 30
$lblSpr = New-Ctrl Label "Sprache:" 485 476
$comboSpr = New-Ctrl ComboBox "" 545 472 210 28
$comboSpr.DropDownStyle = 'DropDownList'
foreach ($s in $Sprachen) { [void]$comboSpr.Items.Add($s.Name) }

$btnAlle  = New-Ctrl Button "Alle"  12 510 70 32
$btnKeine = New-Ctrl Button "Keine" 88 510 70 32
$btnSave  = New-Ctrl Button "Speichern" 164 510 110 32
$btnProbe = New-Ctrl Button "Probelauf" 280 510 100 32
$btnInst  = New-Ctrl Button "Installieren" 386 510 120 32
$btnDown  = New-Ctrl Button "Offline-Installer laden" 512 510 243 32
$btnInst.BackColor = [System.Drawing.Color]::FromArgb(0,120,215); $btnInst.ForeColor = 'White'

$chkRestore = New-Ctrl CheckBox "Vorher Wiederherstellungspunkt" 12 550
$chkRestart = New-Ctrl CheckBox "Am Ende neu starten" 245 550
$btnLog    = New-Ctrl Button "Log oeffnen" 410 545 110 28
$btnRstrui = New-Ctrl Button "Systemwiederherstellung" 525 545 230 28
$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($comboSpr, "Ist die Sprache fuer ein Programm nicht verfuegbar, wird Englisch verwendet.")
$tip.SetToolTip($btnRstrui, "Oeffnet die Windows-Systemwiederherstellung (rstrui), um zu einem Wiederherstellungspunkt zurueckzukehren.")

$script:pbar = New-Ctrl ProgressBar "" 12 580 680 14
$script:lblFortschritt = New-Ctrl Label "" 698 579
$script:logBox = New-Ctrl TextBox "" 12 598 743 162
$logBox.Multiline = $true; $logBox.ScrollBars = 'Vertical'; $logBox.ReadOnly = $true
$logBox.Font = New-Object System.Drawing.Font("Consolas",9)

$form.Controls.AddRange(@($tabs,$lblProf,$comboProf,$btnProfNeu,$btnProfDel,$lblSpr,$comboSpr,
    $btnAlle,$btnKeine,$btnSave,$btnProbe,$btnInst,$btnDown,$chkRestore,$chkRestart,$btnLog,$btnRstrui,$pbar,$lblFortschritt,$logBox))
$tip.SetToolTip($btnProbe, "Zeigt im Log, was installiert/ausgefuehrt wuerde - ohne etwas zu veraendern.")
$tip.SetToolTip($btnLog, "Oeffnet das Log dieser Sitzung im Editor. Alle Logs liegen im Ordner 'logs'.")

function Get-Gewaehlt {
    foreach ($k in $treeApps.Nodes) { foreach ($c in $k.Nodes) { if ($c.Checked) { $c } } }
}
function Get-TweakAuswahl {
    for ($j=0; $j -lt $Tweaks.Count; $j++) { if ($listTw.Items[$j].Checked) { $Tweaks[$j] } }
}
function Set-Sperre($gesperrt) {
    foreach ($c in @($tabs,$comboProf,$btnProfNeu,$btnProfDel,$comboSpr,$btnAlle,$btnKeine,$btnSave,$btnProbe,$btnInst,$btnDown,$chkRestore,$chkRestart)) {
        $c.Enabled = -not $gesperrt
    }
}

# ---- Profil anzeigen / speichern ----
function Show-Profil($name) {
    $script:laden = $true
    Import-Profil $name
    $treeApps.BeginUpdate(); $treeApps.Nodes.Clear()
    foreach ($a in $Apps) { [void](Add-AppNode $a) }
    $treeApps.EndUpdate()
    Update-BefehlListe $null
    $comboSpr.SelectedIndex = $SprachIndex
    $chkRestore.Checked = [bool]$Optionen.restorepoint
    $chkRestart.Checked = [bool]$Optionen.restart
    $comboKat.Items.Clear()
    foreach ($k in ($Apps | ForEach-Object Kategorie | Sort-Object -Unique)) { [void]$comboKat.Items.Add($k) }
    if (-not $comboKat.Text) { $comboKat.Text = "Sonstiges" }
    $form.Text = "PC-Setup - Profil: $name"
    $script:laden = $false
    Write-Log "Profil '$name' geladen: $($Apps.Count) Programme, $(@($Tweaks | Where-Object { Test-TweakGewaehlt $_ }).Count) Befehle angehakt."
}
function Update-ProfilListe($auswahl) {
    $script:laden = $true
    $comboProf.Items.Clear()
    foreach ($n in (Get-ProfilNamen)) { [void]$comboProf.Items.Add($n) }
    $comboProf.SelectedItem = $auswahl
    $script:laden = $false
}
function Save-Profil($pfad) {
    foreach ($k in $treeApps.Nodes) { foreach ($c in $k.Nodes) { $c.Tag.Aktiv = $(if ($c.Checked) { '1' } else { '0' }) } }
    $z = New-Object System.Collections.Generic.List[string]
    $z.Add("Aktiv;Kategorie;Name;WingetID")
    foreach ($a in $Apps) { $z.Add(("{0};{1};{2};{3}" -f $a.Aktiv, ($a.Kategorie -replace ';',','), ($a.Name -replace ';',','), $a.WingetID)) }
    for ($j=0; $j -lt $Tweaks.Count; $j++) {
        $z.Add(("{0};_Einstellung;{1};{2}" -f $(if ($listTw.Items[$j].Checked) { '1' } else { '0' }), ($Tweaks[$j].Name -replace ';',','), $Tweaks[$j].Datei))
    }
    $code = $Sprachen[$comboSpr.SelectedIndex].Code; if (-not $code) { $code = 'standard' }
    $z.Add("1;_Sprache;$($Sprachen[$comboSpr.SelectedIndex].Name);$code")
    $z.Add(("{0};_Option;Wiederherstellungspunkt;restorepoint" -f $(if ($chkRestore.Checked) { '1' } else { '0' })))
    $z.Add(("{0};_Option;Neustart am Ende;restart" -f $(if ($chkRestart.Checked) { '1' } else { '0' })))
    if (Test-Path $pfad) { Copy-Item $pfad "$pfad.bak" -Force }
    Set-Content -Path $pfad -Value $z -Encoding UTF8
}

$comboProf.Add_SelectedIndexChanged({
    if ($script:laden -or -not $comboProf.SelectedItem) { return }
    Show-Profil ([string]$comboProf.SelectedItem)
})
$btnProfNeu.Add_Click({
    $n = [Microsoft.VisualBasic.Interaction]::InputBox("Name des neuen Profils (z.B. Gaming, Eltern-PC).`nEs wird als Kopie der aktuellen Auswahl angelegt.", "Neues Profil", "")
    $n = ($n.Trim() -replace '[\\/:*?"<>|_]', '-').Trim('-')
    if (-not $n) { return }
    $pfad = Join-Path $ProfilDir "$n.csv"
    if (Test-Path $pfad) { Show-Fehler "Das Profil '$n' gibt es schon."; return }
    Save-Profil $pfad
    Update-ProfilListe $n
    Show-Profil $n
    Write-Log "Neues Profil '$n' angelegt (Kopie der bisherigen Auswahl)."
})
$btnProfDel.Add_Click({
    $alle = @(Get-ProfilNamen)
    if ($alle.Count -le 1) { Show-Fehler "Das letzte Profil kann nicht geloescht werden."; return }
    if (-not (Ask-JaNein "Profil '$ProfilName' wirklich loeschen?" "Profil loeschen")) { return }
    Remove-Item $CsvPfad -Force
    Remove-Item "$CsvPfad.bak" -Force -ErrorAction SilentlyContinue
    Write-Log "Profil '$ProfilName' geloescht."
    $rest = @(Get-ProfilNamen)
    Update-ProfilListe $rest[0]
    Show-Profil $rest[0]
})

$btnAlle.Add_Click({  foreach($k in $treeApps.Nodes){ $k.Checked=$true } })
$btnKeine.Add_Click({ foreach($k in $treeApps.Nodes){ $k.Checked=$false } })

$btnSave.Add_Click({
    try {
        Save-Profil $CsvPfad
        Set-Content -Path $AktivDatei -Value $ProfilName -Encoding UTF8
        Write-Log ("Profil '{0}' gespeichert: {1} Programme ({2} angehakt), {3} Befehle angehakt, Sprache {4}" -f `
            $ProfilName, $Apps.Count, @(Get-Gewaehlt).Count, @(Get-TweakAuswahl).Count, $Sprachen[$comboSpr.SelectedIndex].Name)
        Write-Log "   -> profile\$ProfilName.csv  (vorherige Version: .bak)"
    } catch { Write-Log "Speichern fehlgeschlagen: $_" }
})

$btnInst.Add_Click({
    Set-Sperre $true
    $appListe   = @(Get-Gewaehlt | ForEach-Object { $_.Tag })
    $tweakListe = @(Get-TweakAuswahl)
    [void](Start-Installation $appListe $tweakListe $Sprachen[$comboSpr.SelectedIndex].Code $chkRestore.Checked $false)
    Update-Status
    Update-BefehlListe (Get-BefehlHaken)
    Set-Sperre $false
    if ($chkRestart.Checked -and (Ask-JaNein "Installation abgeschlossen. PC jetzt neu starten?" "Neustart")) {
        Restart-Computer -Force
    }
})

$btnProbe.Add_Click({
    Set-Sperre $true
    $appListe   = @(Get-Gewaehlt | ForEach-Object { $_.Tag })
    $tweakListe = @(Get-TweakAuswahl)
    [void](Start-Installation $appListe $tweakListe $Sprachen[$comboSpr.SelectedIndex].Code $chkRestore.Checked $true)
    if ($chkRestart.Checked) { Write-Log "Neustart am Ende: wuerde abgefragt (Probelauf)" }
    Update-BefehlListe (Get-BefehlHaken)
    Set-Sperre $false
})
$btnLog.Add_Click({
    if (Test-Path $LogDatei) { Start-Process notepad.exe "`"$LogDatei`"" }
    else { Start-Process explorer.exe $LogDir }
})

$btnRstrui.Add_Click({
    Write-Log "Oeffne Windows-Systemwiederherstellung (rstrui.exe) ..."
    try { Start-Process "$env:SystemRoot\System32\rstrui.exe" -ErrorAction Stop }
    catch { Show-Fehler "Systemwiederherstellung konnte nicht geoeffnet werden:`n$($_.Exception.Message)" }
})

$btnDown.Add_Click({
    Set-Sperre $true
    $loc = $Sprachen[$comboSpr.SelectedIndex].Code
    $sub = if ($loc) { $loc } else { "standard" }
    $auswahl = @(Get-Gewaehlt); $i = 0
    foreach ($n in $auswahl) {
        $i++; $id = $n.Tag.WingetID
        $ziel = Join-Path (Join-Path $InstDir $sub) $id
        New-Item -ItemType Directory -Path $ziel -Force | Out-Null
        Write-Log "[$i/$($auswahl.Count)] Lade $($n.Tag.Name) herunter ($sub)"
        $code = Invoke-WingetMitFallback "download" $id $loc "--download-directory `"$ziel`"" "--accept-package-agreements --accept-source-agreements"
        if ($code -ne 0) { Write-Log "   -> Fehler (Code $code)" }
    }
    Write-Log "Download fertig. Ordner: $InstDir"
    Set-Sperre $false
})

# ---- Start ----
Update-ProfilListe $ProfilName
Show-Profil $ProfilName
Move-WlanAusHauptordner
Update-WlanAnzeige
Import-Netzlaufwerke
# Einstellung "Status beim Start pruefen" (Standard: aus)
$StartPruefen = $false
if (Test-Path $EinstDatei) {
    foreach ($l in (Get-Content $EinstDatei -Encoding UTF8)) { if ($l -match '^\s*StatusBeimStart\s*=\s*1') { $StartPruefen = $true } }
}
$chkStartPruef.Checked = $StartPruefen
$chkStartPruef.Add_CheckedChanged({
    Set-Content -Path $EinstDatei -Value ("StatusBeimStart=" + $(if ($chkStartPruef.Checked) { '1' } else { '0' })) -Encoding UTF8
    Write-Log $(if ($chkStartPruef.Checked) { "Status wird ab jetzt beim Start geprueft." } else { "Status wird beim Start nicht mehr geprueft (Button 'Status pruefen' nutzen)." })
})
if ($StartPruefen) {
    $form.Add_Shown({ Set-Sperre $true; Update-Status; Update-BefehlStatus; Set-Sperre $false })
} else {
    Write-Log "Status-Pruefung beim Start ist aus - bei Bedarf 'Status pruefen' klicken."
}
[void]$form.ShowDialog()
