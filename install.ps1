# evooming agent-setup for Windows - bootstrap
#
#   irm https://github.com/Schwarzkopf/agent-setup/releases/latest/download/install.ps1 | iex
#
# This small loader stays ASCII on purpose: it downloads setup.ps1 (UTF-8 with BOM,
# German texts), saves it as a file and runs it. Running from a file keeps umlauts
# intact in Windows PowerShell 5.1 and lets setup.ps1 ask for administrator rights.
#
# Optional environment variables:
#   EVOOMING_SETUP_URL   base URL to load setup.ps1 from (for testing other versions)
#   EVOOMING_ROLE        agent | workstation

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $base = $env:EVOOMING_SETUP_URL
    if (-not $base) { $base = 'https://github.com/Schwarzkopf/agent-setup/releases/latest/download' }

    $dir = Join-Path $env:TEMP ('evooming-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir 'setup.ps1'

    Write-Host 'evooming agent-setup: loading setup.ps1 ...'
    try {
        $bytes = (Invoke-WebRequest -UseBasicParsing -Uri "$base/setup.ps1").Content
        if ($bytes -is [string]) { $bytes = [Text.Encoding]::UTF8.GetBytes($bytes) }
        # Prepend a UTF-8 BOM if missing, so Windows PowerShell 5.1 reads the file as UTF-8
        if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
            $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $bytes)
        }
        [IO.File]::WriteAllBytes($file, $bytes)
    } catch {
        Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Check the internet connection and try again.'
        return
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file
}
