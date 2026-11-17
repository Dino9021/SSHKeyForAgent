# Enable-SshKeyLogin.ps1 - run on the REMOTE Windows host, elevated (PowerShell 7 recommended).
param(
    [Parameter(Mandatory)][string]$PublicKey,          # the one line printed by script 1
    [Parameter(Mandatory)][string]$User,               # account that will log in: name, DOMAIN\name or name@domain
    [ValidateSet('Auto','Admin','User')][string]$KeyFile = 'Auto',
    [string]$AllowFrom                                 # optional, comma-separated: 192.168.10.12,10.10.0.0/24
)
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) { Write-Error 'PowerShell 7 is required. Install it: winget install Microsoft.PowerShell'; exit 1 }
    $fwd = foreach ($k in $PSBoundParameters.Keys) { "-$k"; [string]$PSBoundParameters[$k] }
    & $pwsh.Source -NoProfile -File $PSCommandPath @fwd; exit $LASTEXITCODE
}
$ErrorActionPreference = 'Stop'

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { Write-Error 'Run this script elevated (Run as administrator).'; exit 1 }

$PublicKey = $PublicKey.Trim()
if ($PublicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( \S+)?$') {
    Write-Error "Not an OpenSSH public key line (got: $($PublicKey.Substring(0, [Math]::Min(40, $PublicKey.Length)))...)."; exit 1
}

# --- 1. OpenSSH server: install only if there is no sshd service at all (any edition counts) ---
# Prefers the latest release MSI from https://github.com/PowerShell/Win32-OpenSSH; only when that MSI
# cannot be obtained and verified does it fall back to the Windows built-in capability.
function Get-Win32OpenSshMsi {
    # Returns the path of a downloaded, sha256-verified MSI; throws on any failure.
    $arch = switch ([string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'Win64' } 'Arm64' { 'ARM64' } 'X86' { 'Win32' }
        default { throw "unsupported OS architecture: $_" }
    }
    $rel   = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest' -TimeoutSec 30
    $asset = @($rel.assets | Where-Object { $_.name -match "^OpenSSH-$arch-v[\d.]+\.msi$" })
    if ($asset.Count -ne 1) { throw "expected one OpenSSH-$arch-v*.msi in release $($rel.tag_name), found $($asset.Count)" }
    $asset = $asset[0]
    if ($asset.digest -notmatch '^sha256:([0-9a-f]{64})$') { throw "asset $($asset.name) has no sha256 digest to verify against" }
    $want = $Matches[1]
    $msi  = Join-Path ([IO.Path]::GetTempPath()) $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -TimeoutSec 300
    $got = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $want) { Remove-Item -LiteralPath $msi; throw "sha256 mismatch for $($asset.name): expected $want, got $got" }
    Write-Host "Downloaded $($asset.name) (release $($rel.tag_name)), sha256 verified."
    return $msi
}

$svc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host 'No sshd service found - fetching the latest Win32-OpenSSH release from GitHub...'
    $msi = $null
    try { $msi = Get-Win32OpenSshMsi }
    catch { Write-Warning "Could not get the Win32-OpenSSH MSI ($($_.Exception.Message))." }
    if ($msi) {
        Write-Host "Installing $msi ..."
        $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
        Remove-Item -LiteralPath $msi
        if ($p.ExitCode -notin 0, 3010) { Write-Error "msiexec failed with exit code $($p.ExitCode)"; exit 1 }
    } else {
        Write-Host 'Falling back to the Windows built-in OpenSSH Server (Windows capability)...'
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    }
    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { Write-Error 'Install finished but no sshd service exists.'; exit 1 }
} else {
    Write-Host "sshd already installed: $((Get-CimInstance Win32_Service -Filter "Name='sshd'").PathName)"
}
Set-Service sshd -StartupType Automatic
Start-Service sshd   # also creates %ProgramData%\ssh\sshd_config on first start

# --- 2. Resolve the account: SID, admin or not, profile folder ---------------------------------
$acctName = if ($User -match '@') { $u, $d = $User -split '@', 2; "$($d.Split('.')[0])\$u" } else { $User }
try { $sid = (New-Object Security.Principal.NTAccount($acctName)).Translate([Security.Principal.SecurityIdentifier]).Value }
catch { Write-Error "Account not found: $User (try DOMAIN\name or the local name)"; exit 1 }

$cfgPath = Join-Path $env:ProgramData 'ssh\sshd_config'
$adminFileInUse = (Test-Path $cfgPath) -and
    (Select-String -LiteralPath $cfgPath -Pattern '^\s*AuthorizedKeysFile\s+.*administrators_authorized_keys' -Quiet)

if ($KeyFile -eq 'Auto') {
    $isAdmin = $false
    try {
        $isAdmin = [bool](Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Where-Object { $_.SID.Value -eq $sid })
    } catch { }
    $KeyFile = if ($isAdmin -and $adminFileInUse) { 'Admin' } else { 'User' }
    Write-Host "Account $acctName ($sid): admin=$isAdmin, sshd uses administrators_authorized_keys=$adminFileInUse -> key file: $KeyFile"
    Write-Host '  (if the account is an admin only through a domain/nested group, re-run with -KeyFile Admin)'
}

if ($KeyFile -eq 'Admin') {
    $authFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    $aclArgs  = @('/inheritance:r', '/grant', '*S-1-5-32-544:F', '/grant', '*S-1-5-18:F')
} else {
    $profile = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not $profile -or -not (Test-Path -LiteralPath $profile)) {
        Write-Error "$acctName has no profile on this machine yet - sign in as that account once, then re-run."; exit 1
    }
    $sshDir = Join-Path $profile '.ssh'
    New-Item -ItemType Directory -Force $sshDir | Out-Null
    $authFile = Join-Path $sshDir 'authorized_keys'
    $aclArgs  = @('/inheritance:r', '/grant', "*${sid}:F", '/grant', '*S-1-5-18:F', '/grant', '*S-1-5-32-544:F')
}

# --- 3. Add the key once, ASCII, and lock the ACL (sshd ignores a file others can write) -------
if (-not (Test-Path -LiteralPath $authFile)) { New-Item -ItemType File -Path $authFile | Out-Null }
if ((Get-Content -LiteralPath $authFile -ErrorAction SilentlyContinue) -contains $PublicKey) {
    Write-Host "Key already present in $authFile"
} else {
    Add-Content -LiteralPath $authFile -Value $PublicKey -Encoding ascii
    Write-Host "Key added to $authFile"
}
& icacls $authFile @aclArgs | Out-Null

# --- 4. Firewall: make sure TCP 22 is open inbound; optionally restrict the source -------------
$rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $rule) { $rule = Get-NetFirewallRule -Name 'SshKeyLogin-In-TCP' -ErrorAction SilentlyContinue }
if (-not $rule) {
    $rule = New-NetFirewallRule -Name 'SshKeyLogin-In-TCP' -DisplayName 'OpenSSH Server (TCP 22)' `
            -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow
}
if ($AllowFrom) {
    $list = $AllowFrom -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $rule | Set-NetFirewallRule -RemoteAddress $list
    Write-Host "Rule $($rule.Name): SSH allowed only from $($list -join ', ') (other rules opening port 22 still apply)"
}

# --- 5. Default shell = PowerShell 7 when present, then restart ---------------------------------
$pwsh7 = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (Test-Path $pwsh7) {
    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $pwsh7 -PropertyType String -Force | Out-Null
}
Restart-Service sshd
Write-Host ''
Write-Host 'Done. Test from the local machine with: ssh <the short name you gave script 1>'
