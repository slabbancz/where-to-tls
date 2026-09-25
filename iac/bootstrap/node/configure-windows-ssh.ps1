param(
    [Parameter(Mandatory=$true)]
    [string]$UserName,

    [Parameter(Mandatory=$true)]
    [string]$PublicKeyBase64,

    [Parameter(Mandatory=$true)]
    [string]$AllowedSource
)

$ErrorActionPreference = "Stop"
$logDirectory = "C:\wtt\logs"
$logPath = "$logDirectory\configure-windows-ssh.log"
New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
Start-Transcript -Path $logPath -Append -Force

try {
    $publicKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PublicKeyBase64))
    if ($publicKey -notmatch '^ssh-(ed25519|rsa|ecdsa-\S+)\s+\S+') {
        throw "FATAL: Supplied value is not an OpenSSH public key"
    }
    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        throw "FATAL: Windows account '$UserName' does not exist"
    }

    $capability = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0"
    if ($capability.State -ne "Installed") {
        Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
    }

    $sshDirectory = "$env:ProgramData\ssh"
    $authorizedKeys = "$sshDirectory\administrators_authorized_keys"
    New-Item -Path $sshDirectory -ItemType Directory -Force | Out-Null
    Set-Content -Path $authorizedKeys -Value $publicKey -Encoding ASCII
    & icacls.exe $authorizedKeys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

    $configurationPath = "$sshDirectory\sshd_config"
    $configuration = Get-Content -Path $configurationPath -Raw
    $configuration = [regex]::Replace($configuration, '(?m)^\s*#?\s*PubkeyAuthentication\s+.*$', 'PubkeyAuthentication yes')
    $configuration = [regex]::Replace($configuration, '(?m)^\s*#?\s*PasswordAuthentication\s+.*$', 'PasswordAuthentication no')
    $configuration = [regex]::Replace($configuration, "(?m)^\s*AllowUsers\s+$([regex]::Escape($UserName))\s*\r?\n", '')
    $configuration = "AllowUsers $UserName`r`n$configuration"
    Set-Content -Path $configurationPath -Value $configuration -Encoding ASCII

    Remove-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -Name "OpenSSH-Server-In-TCP" `
        -DisplayName "OpenSSH Server (sshd) - WTT VNet only" `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -Action Allow `
        -LocalPort 22 `
        -RemoteAddress $AllowedSource | Out-Null

    & "$env:WINDIR\System32\OpenSSH\sshd.exe" -t
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
    Write-Output "WTT_WINDOWS_SSH_OK=1"
} finally {
    Stop-Transcript
}
