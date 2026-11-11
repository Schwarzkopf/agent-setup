# evooming agent-setup für Windows 10/11
#
# Start über install.ps1:
#   irm https://github.com/Schwarzkopf/agent-setup/releases/latest/download/install.ps1 | iex
#
# Oder direkt:
#   powershell -ExecutionPolicy Bypass -File setup.ps1 [-Role agent|workstation] [-Yes] [-SkipHermes] [-DryRun]
#
# Dieselben Schalter als Umgebungsvariablen (für "irm | iex"): EVOOMING_ROLE,
# EVOOMING_YES=1, EVOOMING_SKIP_HERMES=1, EVOOMING_DRY_RUN=1
#
# Passwörter ohne Rückfrage (z. B. für -Yes):
#   EVOOMING_RUSTDESK_PASSWORD, EVOOMING_SYNCTHING_PASSWORD, EVOOMING_SYNCTHING_USER
#
# Ablauf: Fragen in diesem Fenster, dann ein Fenster mit Administratorrechten für
# Syncthing-Dienst, RustDesk, Chrome und Energieeinstellungen, danach hier weiter mit
# Obsidian, ChatGPT und Hermes (die gehören in dein normales Benutzerkonto).
# Mehrfach ausführbar: Installiertes wird aktualisiert, Erledigtes übersprungen.

[CmdletBinding()]
param(
    [string]$Role = $env:EVOOMING_ROLE,
    [switch]$Yes,
    [switch]$SkipHermes,
    [switch]$DryRun,
    # intern: Administrator-Teil, gestartet von diesem Skript
    [string]$Phase = '',
    [string]$StateFile = ''
)

# Schalter auch als Umgebungsvariablen, denn "irm | iex" kann keine Parameter übergeben
if ($env:EVOOMING_YES -eq '1') { $Yes = [switch]$true }
if ($env:EVOOMING_SKIP_HERMES -eq '1') { $SkipHermes = [switch]$true }
if ($env:EVOOMING_DRY_RUN -eq '1') { $DryRun = [switch]$true }

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$SetupVersion = 'dev'
$RustDeskHost = 'rustdesk.klaus-schwarzkopf.de'
# Exportierte Netzwerkeinstellungen (ID-Server, Relay-Server, öffentlicher Schlüssel)
$RustDeskConfig = '==Qfi0TU1wmcQFmcpVUT4QXVsh3MERXaNNmaRdkerxmW4ZDTjVDSpVHSiFFNkVWbiojI5V2aiwiIiojIpBXYiwiI3ETMxIjOlRmLmB3brpnchdHajNXLzVXYstmLrNXZkR3c1JnI6ISehxWZyJCLiYTMxEjM6UGZuYGcvtmeyF2doN2ctMXdhx2aus2clRGdzVnciojI0N3boJye'
$HermesInstaller = 'https://hermes-agent.nousresearch.com/install.ps1'
$ChatGptStoreId = '9NT1R1C2HH7J'
$IgnorePatterns = @('.obsidian/workspace.json', '.obsidian/workspace-mobile.json', '.trash')

$script:Results = New-Object System.Collections.ArrayList
$script:NextSteps = New-Object System.Collections.ArrayList
$script:RustDeskId = ''
$script:SyncthingId = ''

# ------------------------------------------------------------------ Ausgabe

function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor White }
function Write-Info([string]$Text) { Write-Host "    $Text" }

function Add-Result([string]$Status, [string]$Name, [string]$Detail) {
    [void]$script:Results.Add([pscustomobject]@{ Status = $Status; Name = $Name; Detail = $Detail })
    switch ($Status) {
        'ok'   { Write-Host "    + $Name $Detail" -ForegroundColor Green }
        'warn' { Write-Host "    ! $Name $Detail" -ForegroundColor Yellow }
        'fail' { Write-Host "    x $Name $Detail" -ForegroundColor Red }
        'skip' { Write-Host "    - $Name $Detail" -ForegroundColor DarkGray }
    }
}
function Ok([string]$Name, [string]$Detail)   { Add-Result 'ok' $Name $Detail }
function Warn([string]$Name, [string]$Detail) { Add-Result 'warn' $Name $Detail }
function Fail([string]$Name, [string]$Detail) { Add-Result 'fail' $Name $Detail }
function Skip([string]$Name, [string]$Detail) { Add-Result 'skip' $Name $Detail }
function Add-NextStep([string]$Text) { if (-not $script:NextSteps.Contains($Text)) { [void]$script:NextSteps.Add($Text) } }

function Stop-Setup([string]$Text) {
    Write-Host ''
    Write-Host "Abbruch: $Text" -ForegroundColor Red
    if ($Phase -eq 'admin') { Start-Sleep -Seconds 10 }
    exit 1
}

# ------------------------------------------------------------------ Eingaben

function Test-Interactive { return (-not $Yes) -and (-not $DryRun) -and [Environment]::UserInteractive }

function Read-Answer([string]$Question, [string]$Default) {
    if (-not (Test-Interactive)) { return $Default }
    $a = Read-Host "$Question [$Default]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim()
}

function Read-YesNo([string]$Question, [bool]$Default) {
    if (-not (Test-Interactive)) { return $Default }
    $hint = if ($Default) { '[J/n]' } else { '[j/N]' }
    $a = Read-Host "$Question $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return ($a -match '^(j|ja|y|yes)$')
}

function ConvertFrom-Secure([Security.SecureString]$Secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Gibt das Passwort als SecureString zurück oder $null (= später selbst setzen)
function Read-Secret([string]$Label, [int]$MinLength) {
    if (-not (Test-Interactive)) { return $null }
    while ($true) {
        $a = Read-Host "$Label (mind. $MinLength Zeichen, leer lassen = später selbst setzen)" -AsSecureString
        $plain = ConvertFrom-Secure $a
        if ($plain.Length -eq 0) { return $null }
        if ($plain.Length -lt $MinLength) { Write-Host '    Zu kurz, bitte noch einmal.'; continue }
        $b = Read-Host 'Noch einmal zur Bestätigung' -AsSecureString
        if ($plain -ceq (ConvertFrom-Secure $b)) { return $a }
        Write-Host '    Die Eingaben sind verschieden, bitte noch einmal.'
    }
}

# ------------------------------------------------------------------ Hilfen

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Get-LatestGitHubAsset([string]$Repo, [string]$Pattern) {
    try {
        $rel = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'evooming-agent-setup' }
    } catch { return $null }
    $asset = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
    if (-not $asset) { return $null }
    $version = ([regex]::Match($asset.name, '\d+(\.\d+)+')).Value
    return [pscustomobject]@{ Url = $asset.browser_download_url; Name = $asset.name; Version = $version }
}

function Save-Download([string]$Url, [string]$Path) {
    if ($DryRun) {
        try { Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Url | Out-Null } catch { return $false }
        Write-Host "    [dry-run] Download $Url" -ForegroundColor DarkGray
        return $true
    }
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path; return $true }
        catch { Start-Sleep -Seconds 3 }
    }
    return $false
}

function Get-InstalledVersion([string]$NamePattern) {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $entry = Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $NamePattern } | Select-Object -First 1
    if ($entry) { return [string]$entry.DisplayVersion }
    return ''
}

function Test-Winget { return [bool](Get-Command winget -ErrorAction SilentlyContinue) }

# Installiert oder aktualisiert ein Paket über winget
function Install-WingetPackage([string]$Id, [string]$Name, [string[]]$Extra = @()) {
    $common = @('--id', $Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements') + $Extra
    if ($DryRun) { Write-Host "    [dry-run] winget install $($common -join ' ')" -ForegroundColor DarkGray; Ok $Name '(Probelauf)'; return $true }
    if (-not (Test-Winget)) {
        Fail $Name 'winget fehlt. Bitte "App-Installer" aus dem Microsoft Store installieren und das Skript neu starten.'
        return $false
    }

    $listed = (& winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String)
    if ($LASTEXITCODE -eq 0 -and $listed -match [regex]::Escape($Id)) {
        & winget upgrade @common | Out-Host
        if ($LASTEXITCODE -eq 0) { Ok $Name 'aktualisiert' } else { Ok $Name 'ist aktuell' }
        return $true
    }
    & winget install @common | Out-Host
    $code = $LASTEXITCODE
    # -1978335135 = schon installiert, -1978335189 = kein Update nötig
    if ($code -eq 0 -or $code -eq -1978335135 -or $code -eq -1978335189) { Ok $Name 'installiert'; return $true }
    Fail $Name ('winget meldet Fehler 0x{0:X8}' -f $code)
    return $false
}

function Invoke-Quiet([string]$Exe, [string[]]$Arguments) {
    # RustDesk ist ein Fensterprogramm. Erst über die Pipe kommt seine Ausgabe an und PowerShell wartet.
    return ((& $Exe @Arguments 2>&1 | Out-String).Trim())
}

# ------------------------------------------------------------------ Administrator-Teil

function Set-Power {
    Write-Step 'Dauerbetrieb: kein Standby'
    if ($DryRun) { Write-Host '    [dry-run] powercfg' -ForegroundColor DarkGray; Ok 'Energie' '(Probelauf)'; return }
    & powercfg /change standby-timeout-ac 0
    & powercfg /change hibernate-timeout-ac 0
    & powercfg /change monitor-timeout-ac 15
    if ($LASTEXITCODE -eq 0) { Ok 'Energie' 'Standby aus, Bildschirm aus nach 15 min (am Netzteil)' }
    else { Fail 'Energie' 'powercfg fehlgeschlagen, bitte von Hand einstellen (Lektion 3.1)' }
    Add-NextStep 'Automatische Anmeldung mit netplwiz einschalten, Nutzungszeit für Windows Update festlegen und im BIOS "Restore on AC Power Loss" auf Power On stellen (Lektion 3.1).'
}

function Get-SyncthingExe {
    foreach ($p in @("$env:ProgramFiles\Syncthing\syncthing.exe", "${env:ProgramFiles(x86)}\Syncthing\syncthing.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Install-Syncthing($State) {
    Write-Step 'Syncthing (Windows-Dienst)'
    $rel = Get-LatestGitHubAsset 'Bill-Stewart/SyncthingWindowsSetup' '^syncthing-windows-setup-v[\d.]+\.exe$'
    if (-not $rel) { Fail 'Syncthing' 'neueste Version nicht gefunden (GitHub nicht erreichbar?)'; return }

    # Syncthing aktualisiert sich danach alle 12 Stunden selbst
    if ((Get-InstalledVersion 'Syncthing*') -and (Get-SyncthingExe)) {
        Ok 'Syncthing' 'ist installiert und aktualisiert sich selbst'
    } else {
        $file = Join-Path $State.TempDir $rel.Name
        if (-not (Save-Download $rel.Url $file)) { Fail 'Syncthing' 'Download fehlgeschlagen'; return }
        if (-not $DryRun) {
            $setupArgs = '/allusers /silent /suppressmsgboxes /norestart /noconfigpage /mergetasks="startatboot,startserviceafterinstall"'
            $p = Start-Process -FilePath $file -ArgumentList $setupArgs -Wait -PassThru
            if ($p.ExitCode -ne 0) { Fail 'Syncthing' "Setup endete mit Fehler $($p.ExitCode)"; return }
        }
        Ok 'Syncthing' "$($rel.Version) installiert, startet mit Windows"
    }
    if ($DryRun) { return }

    $exe = Get-SyncthingExe
    $stHome = Join-Path $env:ProgramData 'Syncthing'
    $config = Join-Path $stHome 'config.xml'
    for ($i = 0; $i -lt 30 -and -not (Test-Path $config); $i++) { Start-Sleep -Seconds 1 }
    if (-not $exe -or -not (Test-Path $config)) { Warn 'Syncthing' 'Konfiguration nicht gefunden'; return }

    $service = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'syncthing*' } | Select-Object -First 1
    $env:STHOMEDIR = $stHome
    if ((Get-Content -Raw $config) -match '<user>[^<]+</user>') {
        Ok 'Syncthing-Oberfläche' 'Benutzername und Passwort sind schon gesetzt'
    } elseif ($State.SyncthingPassword) {
        if ($service) { Stop-Service $service.Name -Force -ErrorAction SilentlyContinue }
        $State.SyncthingPassword | & $exe generate "--gui-user=$($State.SyncthingUser)" '--gui-password=-' | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok 'Syncthing-Oberfläche' "geschützt mit Benutzer '$($State.SyncthingUser)'" }
        else { Fail 'Syncthing-Oberfläche' 'Passwort ließ sich nicht setzen' }
        if ($service) { Start-Service $service.Name -ErrorAction SilentlyContinue }
    } else {
        Warn 'Syncthing-Oberfläche' 'noch ohne Passwort'
        Add-NextStep 'Syncthing-Passwort setzen: http://127.0.0.1:8384 → Aktionen → Einstellungen → GUI.'
    }
    $script:SyncthingId = ((& $exe device-id 2>$null) | Out-String).Trim()
    Remove-Item Env:\STHOMEDIR -ErrorAction SilentlyContinue
}

function Set-VaultFolder($State) {
    Write-Step 'Vault-Ordner'
    $vault = $State.VaultDir
    if ($State.Role -eq 'agent') {
        if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $vault | Out-Null }
    } elseif (-not (Test-Path $vault)) {
        Warn 'Vault' "$vault gibt es noch nicht"
        Add-NextStep "Vault-ZIP nach $vault entpacken (Lektion 2.1) und dieses Skript noch einmal starten, dann setzt es Rechte und Ignoriermuster für Syncthing."
        return
    }
    if ($DryRun) { Ok 'Vault' "$vault (Probelauf)"; return }

    # Obsidian-Fensterdateien nicht synchronisieren (Lektion 3.2, Schritt 5). .stignore bleibt lokal.
    $ignore = Join-Path $vault '.stignore'
    $existing = @(); if (Test-Path $ignore) { $existing = @(Get-Content $ignore) }
    $missing = @($IgnorePatterns | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -gt 0) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::AppendAllText($ignore, (($missing -join "`n") + "`n"), $utf8)
    }
    # Der Syncthing-Dienst läuft unter einem eigenen Konto und braucht Schreibrechte (Lektion 2.4)
    & icacls $vault /grant 'SyncthingServiceAcct:(OI)(CI)M' /T /Q | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok 'Vault' "$vault, Syncthing darf schreiben, Ignoriermuster gesetzt" }
    else { Fail 'Vault' "Rechte für SyncthingServiceAcct ließen sich nicht setzen ($vault)" }
}

function Install-RustDesk($State) {
    Write-Step 'RustDesk'
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
    $rel = Get-LatestGitHubAsset 'rustdesk/rustdesk' "^rustdesk-[\d.]+-$arch\.msi$"
    if (-not $rel) { Fail 'RustDesk' 'neueste Version nicht gefunden (GitHub nicht erreichbar?)'; return }

    $current = Get-InstalledVersion 'RustDesk*'
    if ($current -and $current.StartsWith($rel.Version)) {
        Ok 'RustDesk' "ist aktuell ($($rel.Version))"
    } else {
        $file = Join-Path $State.TempDir $rel.Name
        if (-not (Save-Download $rel.Url $file)) { Fail 'RustDesk' 'Download fehlgeschlagen'; return }
        if (-not $DryRun) {
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$file`" /qn /norestart" -Wait -PassThru
            if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { Fail 'RustDesk' "Installation endete mit Fehler $($p.ExitCode)"; return }
        }
        Ok 'RustDesk' "$($rel.Version) installiert, läuft als Dienst"
    }
    if ($DryRun) { return }

    $exe = "$env:ProgramFiles\RustDesk\rustdesk.exe"
    if (-not (Test-Path $exe)) { Fail 'RustDesk' "$exe nicht gefunden"; return }
    for ($i = 0; $i -lt 30; $i++) {
        $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { break }
        Start-Sleep -Seconds 1
    }
    Start-Sleep -Seconds 3

    if ((Invoke-Quiet $exe @('--option', 'custom-rendezvous-server')) -match [regex]::Escape($RustDeskHost)) {
        Ok 'RustDesk-Server' "$RustDeskHost ist schon eingetragen"
    } else {
        Invoke-Quiet $exe @('--config', $RustDeskConfig) | Out-Null
        Start-Sleep -Seconds 2
        if ((Invoke-Quiet $exe @('--option', 'custom-rendezvous-server')) -match [regex]::Escape($RustDeskHost)) {
            Ok 'RustDesk-Server' "$RustDeskHost eingetragen"
        } else {
            Warn 'RustDesk-Server' 'ließ sich nicht automatisch eintragen'
            try { Set-Clipboard -Value $RustDeskConfig } catch { }
            Add-NextStep 'RustDesk-Server von Hand eintragen (Lektion 2.5, Schritt 2). Der Text dafür steht in der Lektion und liegt schon in deiner Zwischenablage.'
        }
    }

    if ($State.Role -eq 'agent') {
        if ($State.RustDeskPassword) {
            # Das Passwort nimmt nur der laufende RustDesk-Dienst an, der braucht nach der Installation ein paar Sekunden
            $out = ''
            for ($i = 0; $i -lt 6; $i++) {
                $out = Invoke-Quiet $exe @('--password', $State.RustDeskPassword)
                if ($out -match 'Done') { break }
                Start-Sleep -Seconds 3
            }
            if ($out -notmatch 'Done') {
                Fail 'RustDesk-Zugriff' "Passwort ließ sich nicht setzen: $out"
                Add-NextStep 'RustDesk: dauerhaftes Passwort von Hand setzen (Lektion 3.3, Schritt 3).'
            } else {
                Invoke-Quiet $exe @('--option', 'verification-method', 'use-permanent-password') | Out-Null
                Ok 'RustDesk-Zugriff' 'dauerhaftes Passwort gesetzt, nur dieses Passwort gilt'
            }
        } elseif ((Invoke-Quiet $exe @('--option', 'verification-method')) -match 'use-permanent-password') {
            Ok 'RustDesk-Zugriff' 'dauerhaftes Passwort ist schon eingerichtet'
        } else {
            Warn 'RustDesk-Zugriff' 'noch kein dauerhaftes Passwort'
            Add-NextStep 'RustDesk: dauerhaftes Passwort setzen (Lektion 3.3, Schritt 3).'
        }
        $script:RustDeskId = (Invoke-Quiet $exe @('--get-id')) -replace '\s', ''
        Add-NextStep 'Von der Workstation aus mit RustDesk verbinden und den Agent-Rechner als Favorit speichern (Lektion 3.3, Schritt 4).'
    }
}

function Invoke-AdminPart($State) {
    if ($State.Role -eq 'agent') { Set-Power }
    Install-Syncthing $State
    Set-VaultFolder $State
    Install-RustDesk $State
    if ($State.Role -eq 'agent') {
        Write-Step 'Google Chrome'
        Install-WingetPackage 'Google.Chrome' 'Google Chrome' @('--scope', 'machine') | Out-Null
    }
}

# ------------------------------------------------------------------ Benutzer-Teil

function Install-Hermes($State) {
    Write-Step 'Hermes (evooming agent)'
    if ($SkipHermes) { Skip 'Hermes' 'übersprungen (-SkipHermes)'; return }
    if (Test-Admin) {
        Warn 'Hermes' 'nicht installiert, weil dieses Fenster Administratorrechte hat'
        Add-NextStep "Hermes in einer normalen PowerShell (ohne Administrator) installieren: iex (irm $HermesInstaller) (Lektion 3.5)."
        return
    }
    Update-PathFromRegistry
    $hermes = Get-Command hermes -ErrorAction SilentlyContinue
    if ($hermes) {
        if ($DryRun) { Ok 'Hermes' '(Probelauf: würde aktualisieren)'; return }
        & $hermes.Source update
        if ($LASTEXITCODE -eq 0) { Ok 'Hermes' 'aktualisiert' } else { Warn 'Hermes' 'installiert, Update fehlgeschlagen' }
        return
    }
    Write-Info 'Jetzt kommt der offizielle Hermes-Installer. Am Ende startet sein Einrichtungsassistent.'
    Write-Info 'Lass ihn durchlaufen, nimm die Vorschläge und lass leer, was du noch nicht hast.'
    $file = Join-Path $State.TempDir 'hermes-install.ps1'
    if (-not (Save-Download $HermesInstaller $file)) { Fail 'Hermes' 'Installer nicht erreichbar'; return }
    if ($DryRun) { return }
    $hermesArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file)
    if (-not (Test-Interactive)) { $hermesArgs += '-NonInteractive' }
    & powershell.exe @hermesArgs
    if ($LASTEXITCODE -eq 0) {
        Ok 'Hermes' 'installiert'
        Add-NextStep 'Neue PowerShell öffnen, dann: hermes model → ChatGPT-Abo verbinden, hermes gateway setup → Telegram (Lektion 3.5).'
    } else {
        Fail 'Hermes' "Installer endete mit Fehler $LASTEXITCODE"
    }
}

function Invoke-UserPart($State) {
    if ($State.Role -eq 'workstation') {
        Write-Step 'Obsidian'
        if (Install-WingetPackage 'Obsidian.Obsidian' 'Obsidian') {
            Add-NextStep "Obsidian öffnen → „Ordner als Vault öffnen“ → $($State.VaultDir) (Lektion 2.2)."
        }
    } else {
        Write-Step 'ChatGPT Desktop'
        if (Install-WingetPackage $ChatGptStoreId 'ChatGPT Desktop' @('--source', 'msstore')) {
            Add-NextStep 'ChatGPT Desktop öffnen, mit deinem Abo anmelden, Projekt mit dem Ordner evooming-Brain anlegen und Computer Use samt Chrome-Erweiterung einrichten (Lektion 3.4).'
        }
        Install-Hermes $State
    }
}

# ------------------------------------------------------------------ Zusammenfassung

function Show-Summary($State, $AllResults) {
    $roleName = if ($State.Role -eq 'agent') { 'Agent-Rechner' } else { 'Workstation' }
    Write-Host ''
    Write-Host '=====================================================' -ForegroundColor White
    Write-Host " evooming agent-setup $SetupVersion – Ergebnis ($roleName)" -ForegroundColor White
    Write-Host '=====================================================' -ForegroundColor White
    $fails = 0
    foreach ($r in $AllResults) {
        $line = ' {0} {1,-22} {2}'
        switch ($r.Status) {
            'ok'   { Write-Host ($line -f '+', $r.Name, $r.Detail) -ForegroundColor Green }
            'warn' { Write-Host ($line -f '!', $r.Name, $r.Detail) -ForegroundColor Yellow }
            'fail' { Write-Host ($line -f 'x', $r.Name, $r.Detail) -ForegroundColor Red; $fails++ }
            'skip' { Write-Host ($line -f '-', $r.Name, $r.Detail) -ForegroundColor DarkGray }
        }
    }
    if ($State.RustDeskId -or $State.SyncthingId) {
        Write-Host ''
        Write-Host 'Diese Angaben brauchst du gleich:' -ForegroundColor White
        if ($State.RustDeskId) { Write-Host "  RustDesk-ID:          $($State.RustDeskId)" }
        if ($State.SyncthingId) { Write-Host "  Syncthing-Geräte-ID:  $($State.SyncthingId)" }
    }
    if ($State.Role -eq 'agent') {
        Add-NextStep "Syncthing: Workstation hinzufügen und den Vault-Ordner annehmen, Pfad $($State.VaultDir) (Lektion 3.2, Schritt 2 bis 4)."
    } else {
        Add-NextStep 'Syncthing: Vault-Ordner teilen, sobald der Agent-Rechner eingerichtet ist (Lektion 3.2).'
    }
    if ($script:NextSteps.Count -gt 0) {
        Write-Host ''
        Write-Host 'Noch von Hand zu tun:' -ForegroundColor White
        $n = 1
        foreach ($s in $script:NextSteps) { Write-Host "  $n. $s"; $n++ }
    }
    Write-Host ''
    Write-Host "Protokoll: $($State.LogFile)"
    if ($fails -gt 0) {
        Write-Host "Es gab $fails Fehler. Du kannst das Skript einfach noch einmal starten." -ForegroundColor Red
        Write-Host 'Hilft das nicht, schick das Protokoll an den Support.'
    }
}

# ------------------------------------------------------------------ Ablauf

function Protect-Secret($Secure) {
    if ($null -eq $Secure) { return '' }
    return (ConvertFrom-SecureString $Secure)   # DPAPI: nur dieses Benutzerkonto kann es lesen
}
function Unprotect-Secret([string]$Text) {
    if (-not $Text) { return '' }
    try { return ConvertFrom-Secure (ConvertTo-SecureString $Text) } catch { return '' }
}

function Invoke-AdminPhase {
    # Läuft im Fenster mit Administratorrechten
    $raw = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
    $log = $raw.LogFile -replace '\.log$', '-admin.log'
    try { Start-Transcript -Path $log -Append | Out-Null } catch { }
    Write-Host "evooming agent-setup – Teil mit Administratorrechten" -ForegroundColor White
    $state = [pscustomobject]@{
        Role = $raw.Role; VaultDir = $raw.VaultDir; TempDir = $raw.TempDir
        SyncthingUser = $raw.SyncthingUser
        SyncthingPassword = (Unprotect-Secret $raw.SyncthingPassword)
        RustDeskPassword = (Unprotect-Secret $raw.RustDeskPassword)
    }
    # Hat ein anderes Administratorkonto bestätigt, sind die Passwörter hier nicht lesbar
    if ($raw.SyncthingPassword -and -not $state.SyncthingPassword) {
        $s = Read-Secret 'Passwort für Syncthing' 8; if ($s) { $state.SyncthingPassword = ConvertFrom-Secure $s }
    }
    if ($raw.RustDeskPassword -and -not $state.RustDeskPassword) {
        $s = Read-Secret 'Dauerhaftes RustDesk-Passwort' 12; if ($s) { $state.RustDeskPassword = ConvertFrom-Secure $s }
    }

    Invoke-AdminPart $state

    $out = [pscustomobject]@{
        Results = @($script:Results); NextSteps = @($script:NextSteps)
        RustDeskId = $script:RustDeskId; SyncthingId = $script:SyncthingId
    }
    $out | ConvertTo-Json -Depth 4 | Set-Content -Path ($StateFile + '.result') -Encoding UTF8
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host ''
    Write-Host 'Fertig. Dieses Fenster schließt sich gleich, im ersten Fenster geht es weiter.' -ForegroundColor Green
    Start-Sleep -Seconds 5
}

function Invoke-Main {
    $log = Join-Path $env:USERPROFILE 'evooming-setup.log'
    if (-not $DryRun) { try { Start-Transcript -Path $log -Append | Out-Null } catch { } }

    Write-Host ''
    Write-Host "evooming agent-setup $SetupVersion  ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))" -ForegroundColor White
    if ([Environment]::OSVersion.Version.Build -lt 17763) { Stop-Setup 'Bitte Windows 10 (Version 1809 oder neuer) oder Windows 11 verwenden.' }
    if ($DryRun) { Write-Info 'Probelauf: es wird nichts verändert.' }
    if (-not (Test-Winget)) { Write-Host '    Hinweis: winget fehlt. Chrome, Obsidian und ChatGPT lassen sich dann nicht installieren.' -ForegroundColor Yellow }

    # Rolle
    $Role = "$Role".ToLower()
    if ($Role -and $Role -ne 'agent' -and $Role -ne 'workstation') { Stop-Setup "Unbekannte Rolle '$Role'. Erlaubt: agent, workstation." }
    if (-not $Role) {
        if (Test-Interactive) {
            Write-Host ''
            Write-Host 'Welchen Rechner richtest du ein?'
            Write-Host '  1) Agent-Rechner  (läuft rund um die Uhr: Syncthing, RustDesk, Chrome, ChatGPT, Hermes)'
            Write-Host '  2) Workstation    (dein Arbeitsplatz: Obsidian, Syncthing, RustDesk)'
            do { $a = Read-Host 'Auswahl [1]'; if (-not $a) { $a = '1' } } while ($a -ne '1' -and $a -ne '2')
            $Role = if ($a -eq '1') { 'agent' } else { 'workstation' }
        } else { $Role = 'agent' }
    }
    Write-Info ("Rolle: " + $(if ($Role -eq 'agent') { 'Agent-Rechner' } else { 'Workstation' }))

    $docs = [Environment]::GetFolderPath('MyDocuments')
    $tempDir = Join-Path $env:TEMP ('evooming-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    # Fragen vorab, danach läuft alles durch
    Write-Step 'Ein paar Angaben vorab'
    Write-Info 'Danach läuft die Installation ohne weitere Fragen durch (bis auf Hermes am Ende).'
    $stConfig = Join-Path $env:ProgramData 'Syncthing\config.xml'
    $stHasUser = (Test-Path $stConfig) -and ((Get-Content -Raw $stConfig -ErrorAction SilentlyContinue) -match '<user>[^<]+</user>')
    $stUser = if ($env:EVOOMING_SYNCTHING_USER) { $env:EVOOMING_SYNCTHING_USER } else { $env:USERNAME }
    $stPw = $null
    if ($env:EVOOMING_SYNCTHING_PASSWORD) { $stPw = ConvertTo-SecureString $env:EVOOMING_SYNCTHING_PASSWORD -AsPlainText -Force }
    elseif (-not $stHasUser) {
        Write-Info 'Syncthing-Oberfläche: Benutzername und Passwort (schützt die Oberfläche unter http://127.0.0.1:8384).'
        Write-Info 'Hast du beides schon gesetzt, lass das Passwort einfach leer.'
        $stUser = Read-Answer 'Benutzername für Syncthing' $stUser
        $stPw = Read-Secret 'Passwort für Syncthing' 8
    }
    $rdPw = $null
    if ($Role -eq 'agent') {
        if ($env:EVOOMING_RUSTDESK_PASSWORD) { $rdPw = ConvertTo-SecureString $env:EVOOMING_RUSTDESK_PASSWORD -AsPlainText -Force }
        else {
            Write-Info ''
            Write-Info 'RustDesk: dauerhaftes Passwort für den Fernzugriff auf diesen Rechner.'
            Write-Info 'Wähle ein langes Passwort und speichere es gleich in deinem Passwort-Manager.'
            Write-Info 'Hast du es bei einem früheren Lauf schon gesetzt, lass das Feld einfach leer.'
            $rdPw = Read-Secret 'Dauerhaftes RustDesk-Passwort' 12
        }
    }

    $state = [pscustomobject]@{
        Role = $Role; VaultDir = (Join-Path $docs 'evooming-Brain'); TempDir = $tempDir; LogFile = $log
        SyncthingUser = $stUser
        SyncthingPassword = (Protect-Secret $stPw)
        RustDeskPassword = (Protect-Secret $rdPw)
        RustDeskId = ''; SyncthingId = ''
    }
    $allResults = New-Object System.Collections.ArrayList

    # Administrator-Teil
    if ($DryRun -or (Test-Admin)) {
        $adminState = [pscustomobject]@{
            Role = $Role; VaultDir = $state.VaultDir; TempDir = $tempDir; SyncthingUser = $stUser
            SyncthingPassword = $(if ($stPw) { ConvertFrom-Secure $stPw } else { '' })
            RustDeskPassword = $(if ($rdPw) { ConvertFrom-Secure $rdPw } else { '' })
        }
        Invoke-AdminPart $adminState
        $state.RustDeskId = $script:RustDeskId; $state.SyncthingId = $script:SyncthingId
    } else {
        Write-Step 'Administratorrechte'
        Write-Info 'Gleich fragt Windows, ob dieses Skript Änderungen vornehmen darf. Bitte mit "Ja" bestätigen.'
        Write-Info 'Es öffnet sich ein zweites Fenster für Syncthing-Dienst, RustDesk, Chrome und Energieeinstellungen.'
        $stateFile = Join-Path $tempDir 'state.json'
        $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Phase admin -StateFile `"$stateFile`""
        if ($Yes) { $argLine += ' -Yes' }
        try {
            $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine -Wait -PassThru
        } catch {
            $p = $null
        }
        $resultFile = $stateFile + '.result'
        if ($p -and (Test-Path $resultFile)) {
            $res = Get-Content -Raw $resultFile | ConvertFrom-Json
            foreach ($r in @($res.Results)) { [void]$script:Results.Add($r) }
            foreach ($s in @($res.NextSteps)) { Add-NextStep $s }
            $state.RustDeskId = $res.RustDeskId; $state.SyncthingId = $res.SyncthingId
        } else {
            Fail 'Administratorrechte' 'abgelehnt oder abgebrochen: Syncthing, RustDesk und Chrome fehlen noch'
        }
        Remove-Item -Force $stateFile -ErrorAction SilentlyContinue
    }

    Invoke-UserPart $state

    foreach ($r in $script:Results) { [void]$allResults.Add($r) }
    Show-Summary $state $allResults
    if (-not $DryRun) { try { Stop-Transcript | Out-Null } catch { } }
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    if (@($allResults | Where-Object { $_.Status -eq 'fail' }).Count -gt 0) { exit 1 }
}

if ($Phase -eq 'admin') { Invoke-AdminPhase } else { Invoke-Main }
