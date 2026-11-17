# New-SshKey.ps1 - run on the LOCAL machine as the normal user (not elevated).
# Asks for the target host (required), the login account and a short alias, creates one key per target,
# adds a Host entry to ~/.ssh/config, and prints the exact commands for the remote host.
param(
    [string]$Target,     # remote host name or IP; asked for when empty
    [string]$User,       # remote login account; asked for when empty (Enter = local user name)
    [string]$Alias       # name used with "ssh <alias>"; asked for when empty (Enter = target)
)
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) { Write-Error 'PowerShell 7 is required. Install it: winget install Microsoft.PowerShell'; exit 1 }
    $fwd = foreach ($k in $PSBoundParameters.Keys) { "-$k"; [string]$PSBoundParameters[$k] }
    & $pwsh.Source -NoProfile -File $PSCommandPath @fwd; exit $LASTEXITCODE
}
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'

if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Write-Error 'ssh-keygen not found. Install the OpenSSH client (elevated): Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0'; exit 1
}

# --- input -------------------------------------------------------------------------------------
while ([string]::IsNullOrWhiteSpace($Target)) { $Target = Read-Host 'Target host name or IP (required)' }
$Target = $Target.Trim()
if ($Target -notmatch '^[A-Za-z0-9.\-:]+$') { Write-Error "Not a host name or IP: $Target"; exit 1 }

if ([string]::IsNullOrWhiteSpace($User)) {
    $User = Read-Host "Login account on $Target (Enter = $env:USERNAME)"
    if ([string]::IsNullOrWhiteSpace($User)) { $User = $env:USERNAME }
}
$User = $User.Trim()
if ($User -notmatch '^[A-Za-z0-9._\-\\@]+$') { Write-Error "Not an account name: $User"; exit 1 }

if ([string]::IsNullOrWhiteSpace($Alias)) {
    $Alias = Read-Host "Short name for 'ssh <name>' (Enter = $Target)"
    if ([string]::IsNullOrWhiteSpace($Alias)) { $Alias = $Target }
}
$Alias = $Alias.Trim()
if ($Alias -notmatch '^[A-Za-z0-9._\-]+$') { Write-Error "Alias may use letters, digits, . _ - only: $Alias"; exit 1 }

# --- key (one per target) ----------------------------------------------------------------------
$dir = Join-Path $HOME '.ssh'
New-Item -ItemType Directory -Force $dir | Out-Null
$key = Join-Path $dir "id_ed25519_$Alias"

if (Test-Path -LiteralPath $key) {
    Write-Host "Key already exists, NOT overwritten: $key"
} else {
    # The comment has no spaces or shell-special characters, so the key line pastes safely anywhere.
    $comment = "$env:USERNAME-at-$env:COMPUTERNAME-for-$Alias" -replace '[^A-Za-z0-9._\-]', '_'
    & ssh-keygen -t ed25519 -f $key -C $comment -N '' -q
    if ($LASTEXITCODE -ne 0) { Write-Error 'ssh-keygen failed'; exit 1 }
}
& icacls $key /inheritance:r /grant:r "${env:USERNAME}:F" | Out-Null   # OpenSSH refuses a key others can read

# --- ~/.ssh/config entry -----------------------------------------------------------------------
$cfg = Join-Path $dir 'config'
if (-not (Test-Path -LiteralPath $cfg)) { New-Item -ItemType File -Path $cfg | Out-Null }
if (Select-String -LiteralPath $cfg -Pattern ('^\s*Host\s+' + [regex]::Escape($Alias) + '\s*$') -Quiet) {
    Write-Host "~/.ssh/config already has 'Host $Alias' - left unchanged (check it points at $key)."
} else {
    Add-Content -LiteralPath $cfg -Encoding ascii -Value @(
        '',
        "Host $Alias",
        "    HostName $Target",
        "    User $User",
        "    IdentityFile `"$($key -replace '\\', '/')`"",
        '    IdentitiesOnly yes'
    )
    Write-Host "Added 'Host $Alias' to $cfg"
}

# --- output ------------------------------------------------------------------------------------
$pub = (Get-Content -LiteralPath "$key.pub" -Raw).Trim()
$acct = ($User -split '[\\@]')[0]
if ($User -match '\\') { $acct = ($User -split '\\')[-1] }
Write-Host ''
Write-Host "Private key (stays here, never copy it): $key"
& ssh-keygen -lf "$key.pub"
Write-Host ''
Write-Host '=== PUBLIC KEY (one line) ==='
Write-Host $pub
Write-Host ''
Write-Host '=== REMOTE WINDOWS: open PowerShell 7 (pwsh) as Administrator, cd to the script, run: ==='
Write-Host "& .\Enable-SshKeyLogin.ps1 -User '$User' -PublicKey '$pub'"
Write-Host ''
Write-Host '=== REMOTE LINUX: run: ==='
Write-Host "sudo ./enable-ssh-key-login.sh '$acct' '$pub'"
Write-Host ''
Write-Host "=== Then test from this machine: ssh $Alias ==="
