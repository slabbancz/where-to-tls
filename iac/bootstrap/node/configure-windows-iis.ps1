param(
    [Parameter(Mandatory=$true)]
    [string]$ArtifactArchivePath,

    [Parameter(Mandatory=$true)]
    [string]$CertificatePfxPath,

    [string]$TlsVersion = "1.2",

    [ValidateSet("P-256", "X25519")]
    [string]$TlsGroup = "P-256",

    [bool]$PayloadPreallocate = $true
)

$ErrorActionPreference = "Stop"

function Install-IISFeatures {
    Write-Output "==> [IIS] Installing IIS and ASP.NET 4.8..."
    Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, NET-Framework-45-ASPNET -IncludeManagementTools
}

function Install-AppArtifact {
    param([string]$ArchivePath)

    if (-not (Test-Path $ArchivePath -PathType Leaf)) {
        throw "FATAL: Application artifact does not exist: $ArchivePath"
    }

    $stagingPath = "C:\wtt\artifact"
    Remove-Item -Path $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $stagingPath -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $ArchivePath -DestinationPath $stagingPath -Force

    if (-not (Test-Path "$stagingPath\web.config" -PathType Leaf) -or
        -not (Test-Path "$stagingPath\bin\NetFx48Server.dll" -PathType Leaf)) {
        throw "FATAL: Application artifact is missing web.config or bin\NetFx48Server.dll"
    }

    Copy-Item -Path "$stagingPath\*" -Destination "C:\inetpub\wwwroot" -Recurse -Force
}

function Set-SchannelProtocols {
    param([string]$TargetVersion)

    $schannelPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL"
    $protocolsBase = "$schannelPath\Protocols"

    New-ItemProperty -Path $schannelPath -Name "ServerCacheTime" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $schannelPath -Name "MaximumCacheSize" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $schannelPath -Name "EnableSessionTicket" -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $schannelPath -Name "DisableRenegoOnServer" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $schannelPath -Name "DisableRenegoOnClient" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $schannelPath -Name "EnableOcspStaplingForSni" -Value 0 -PropertyType DWord -Force | Out-Null

    $protocols = @("SSL 2.0", "SSL 3.0", "TLS 1.0", "TLS 1.1", "TLS 1.2", "TLS 1.3")
    $targetProtocol = "TLS $TargetVersion"
    foreach ($protocol in $protocols) {
        foreach ($role in @("Server", "Client")) {
            $protocolPath = "$protocolsBase\$protocol\$role"
            New-Item -Path $protocolPath -Force | Out-Null
            $enabled = if ($protocol -eq $targetProtocol) { 1 } else { 0 }
            $disabledByDefault = if ($protocol -eq $targetProtocol) { 0 } else { 1 }
            New-ItemProperty -Path $protocolPath -Name "Enabled" -Value $enabled -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $protocolPath -Name "DisabledByDefault" -Value $disabledByDefault -PropertyType DWord -Force | Out-Null
        }
    }

    Enable-TlsCipherSuite -Name "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256" -Position 0 -ErrorAction SilentlyContinue

    $markerPath = "HKLM:\SOFTWARE\WTT"
    New-Item -Path $markerPath -Force | Out-Null
    New-ItemProperty -Path $markerPath -Name "SchannelConfigured" -Value 1 -PropertyType DWord -Force | Out-Null
}

function Write-WttConfig {
    param(
        [string]$TlsVer,
        [bool]$Preallocate
    )

    $wttDir = "C:\wtt"
    New-Item -Path $wttDir -ItemType Directory -Force | Out-Null
    $preallocateValue = if ($Preallocate) { "true" } else { "false" }
    $content = @"
{
  "plaintextPort": 8080,
  "tls": {
    "enabled": true,
    "port": 8443,
    "version": "$TlsVer",
    "group": "$TlsGroup",
    "certFile": "C:\\wtt\\tls\\tls.crt",
    "keyFile": "C:\\wtt\\tls\\tls.key",
    "resumption": false
  },
  "payload": {
    "preallocate": $preallocateValue
  }
}
"@
    Set-Content -Path "$wttDir\config.json" -Value $content -Encoding UTF8
}

function Import-WttCertificate {
    param([string]$PfxPath)

    if (-not (Test-Path $PfxPath -PathType Leaf)) {
        throw "FATAL: Certificate PFX file is missing: $PfxPath"
    }

    $storageFlags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
    $certFinal = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $PfxPath,
        "",
        $storageFlags
    )
    if (-not $certFinal.HasPrivateKey) {
        throw "FATAL: Certificate PFX does not contain a private key"
    }

    $store = New-Object Security.Cryptography.X509Certificates.X509Store(
        [Security.Cryptography.X509Certificates.StoreName]::My,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $store.Add($certFinal)
    } finally {
        $store.Close()
    }
    return $certFinal.Thumbprint
}

function New-WttBindings {
    param([string]$Thumbprint)

    foreach ($port in @(8080, 8443)) {
        $ruleName = "WTT Benchmark TCP $port"
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $port `
            -Profile Any | Out-Null
    }

    Import-Module WebAdministration
    Set-ItemProperty "IIS:\AppPools\DefaultAppPool" -Name managedRuntimeVersion -Value "v4.0"
    Set-ItemProperty "IIS:\AppPools\DefaultAppPool" -Name managedPipelineMode -Value "Integrated"
    Remove-WebBinding -Name "Default Web Site" -BindingInformation "*:80:" -ErrorAction SilentlyContinue

    if (-not (Get-WebBinding -Name "Default Web Site" -Port 8080 -Protocol "http")) {
        New-WebBinding -Name "Default Web Site" -IP "*" -Port 8080 -Protocol "http"
    }
    if (-not (Get-WebBinding -Name "Default Web Site" -Port 8443 -Protocol "https")) {
        New-WebBinding -Name "Default Web Site" -IP "*" -Port 8443 -Protocol "https" -SslFlags 0
    }

    Remove-Item "IIS:\SslBindings\0.0.0.0!8443" -Force -ErrorAction SilentlyContinue
    Get-Item "cert:\LocalMachine\My\$Thumbprint" |
        New-Item "IIS:\SslBindings\0.0.0.0!8443" -Force
    Set-WebConfigurationProperty `
        -PSPath "MACHINE/WEBROOT/APPHOST" `
        -Filter 'system.applicationHost/sites/site[@name="Default Web Site"]/logFile' `
        -Name "enabled" `
        -Value "False"

    Restart-Service W3SVC
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:8080/healthz" -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) {
                return
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    throw "FATAL: IIS application did not become healthy on port 8080"
}

if ($TlsVersion -ne "1.2") {
    throw "FATAL: .NET Framework 4.8 benchmark supports TLS 1.2 only"
}

# Schannel policy is host-wide and cached. Never claim a live restriction until
# the operator has rebooted after changing the enabled group list.
$curveName = if ($TlsGroup -eq "P-256") { "NistP256" } else { "curve25519" }
foreach ($command in @("Get-TlsEccCurve", "Enable-TlsEccCurve", "Disable-TlsEccCurve")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "FATAL: This Windows release cannot enforce TLS groups ($command unavailable)"
    }
}
$curves = @(Get-TlsEccCurve)
if ($curves.Count -ne 1 -or $curves[0] -ine $curveName) {
    $markerPath = "HKLM:\SOFTWARE\WTT"
    New-Item -Path $markerPath -Force | Out-Null
    New-ItemProperty -Path $markerPath -Name "GroupPolicyBoot" -Value (
        (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")
    ) -PropertyType String -Force | Out-Null
    Enable-TlsEccCurve -Name $curveName -Position 0 -ErrorAction Stop
    foreach ($curve in @(Get-TlsEccCurve)) {
        if ($curve -ine $curveName) {
            Disable-TlsEccCurve -Name $curve -ErrorAction Stop
        }
    }
    if (@(Get-TlsEccCurve).Count -ne 1 -or (Get-TlsEccCurve) -ine $curveName) {
        throw "FATAL: Schannel did not accept the requested TLS group restriction"
    }
    throw "FATAL: Schannel group policy changed; reboot Windows and rerun deployment before benchmarking"
}
$policyBoot = Get-ItemProperty -Path "HKLM:\SOFTWARE\WTT" -Name "GroupPolicyBoot" -ErrorAction SilentlyContinue
if ($policyBoot -and $policyBoot.GroupPolicyBoot -eq (
    (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")
)) {
    throw "FATAL: Schannel group policy requires a Windows reboot before deployment"
}

Install-IISFeatures
Install-AppArtifact -ArchivePath $ArtifactArchivePath
Set-SchannelProtocols -TargetVersion $TlsVersion
Write-WttConfig -TlsVer $TlsVersion -Preallocate $PayloadPreallocate
$thumbprint = Import-WttCertificate -PfxPath $CertificatePfxPath
New-WttBindings -Thumbprint $thumbprint
$healthz = (Invoke-WebRequest -Uri "http://127.0.0.1:8080/healthz" -UseBasicParsing -TimeoutSec 5).Content
$meta = (Invoke-WebRequest -Uri "http://127.0.0.1:8080/meta" -UseBasicParsing -TimeoutSec 5).Content
Write-Output "WTT_HEALTHZ=$healthz"
Write-Output "WTT_META=$meta"
@{
    imageDigest = "sha256:" + (Get-FileHash $ArtifactArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    tlsEnabled = $true
    tlsVersion = $TlsVersion
    tlsGroup = $TlsGroup
    activePort = 8443
} | ConvertTo-Json | Set-Content -Path "C:\wtt\deployment.json" -Encoding UTF8
Write-Output "==> Windows IIS application deployment completed successfully."
Write-Output "WTT_WINDOWS_DEPLOY_OK=1"
