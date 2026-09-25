param(
    [Parameter(Mandatory=$true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory=$true)]
    [string]$Registry,

    [Parameter(Mandatory=$true)]
    [string]$ArtifactRepository,

    [Parameter(Mandatory=$true)]
    [string]$ArtifactTag,

    [Parameter(Mandatory=$true)]
    [string]$CommonScriptRepository,

    [string]$TlsVersion = "1.2",

    [ValidateSet("P-256", "X25519")]
    [string]$TlsGroup = "P-256",

    [string]$PayloadPreallocate = "true"
)

$ErrorActionPreference = "Stop"
if ($TlsVersion -ne "1.2") {
    throw "FATAL: .NET Framework 4.8 benchmark supports TLS 1.2 only"
}

if ($PayloadPreallocate -notin @("true", "false")) {
    throw "FATAL: PayloadPreallocate must be true or false"
}
$payloadPreallocateValue = [bool]::Parse($PayloadPreallocate)
$logDirectory = "C:\wtt\logs"
$logPath = "$logDirectory\configure-windows-iis.log"
New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
Start-Transcript -Path $logPath -Append -Force

function Get-AzureManagedIdentityToken {
    param([string]$Resource)

    $encodedResource = [Uri]::EscapeDataString($Resource)
    $lastError = $null
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $response = Invoke-RestMethod `
                -Headers @{"Metadata"="true"} `
                -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$encodedResource" `
                -Method GET `
                -TimeoutSec 10
            if ($response.access_token) {
                return $response.access_token
            }
        } catch {
            $lastError = $_.Exception.Message
            if ($attempt -eq 1 -or $attempt % 5 -eq 0) {
                Write-Warning "Managed-identity token attempt $attempt failed: $lastError"
            }
            Start-Sleep -Seconds 3
        }
    }
    throw "FATAL: Failed to acquire an Azure managed-identity token for $Resource. Last error: $lastError"
}

function Get-AzureKeyVaultSecret {
    param(
        [string]$VaultName,
        [string]$SecretName,
        [string]$Token
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le 120; $attempt++) {
        try {
            $secret = Invoke-RestMethod `
                -Headers @{"Authorization"="Bearer $Token"} `
                -Uri "https://$VaultName.vault.azure.net/secrets/${SecretName}?api-version=7.4" `
                -Method GET `
                -TimeoutSec 30
            if ($secret.value) {
                return $secret.value
            }
        } catch {
            $lastError = $_.Exception.Message
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 400) {
                throw "FATAL: Key Vault rejected the request for secret '$SecretName': $lastError"
            }
            if ($attempt -eq 1 -or $attempt % 6 -eq 0) {
                Write-Warning "Key Vault secret '$SecretName' attempt $attempt failed: $lastError"
            }
            Start-Sleep -Seconds 10
        }
    }
    throw "FATAL: Key Vault secret '$SecretName' was unavailable after 1200 seconds. Last error: $lastError"
}

function Get-AcrBasicAuthorization {
    param(
        [string]$DockerConfigJson,
        [string]$RegistryName
    )

    $dockerConfig = $DockerConfigJson | ConvertFrom-Json
    $registryAuth = $dockerConfig.auths.PSObject.Properties |
        Where-Object { $_.Name -eq $RegistryName } |
        Select-Object -First 1
    if (-not $registryAuth) {
        throw "FATAL: ACR credentials for $RegistryName were not found"
    }

    $credential = "$($registryAuth.Value.username):$($registryAuth.Value.password)"
    return "Basic $([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credential)))"
}

function Get-AcrRepositoryAuthorization {
    param(
        [string]$RegistryName,
        [string]$Repository,
        [string]$BasicAuthorization
    )

    $scope = [Uri]::EscapeDataString("repository:$Repository`:pull")
    $tokenResponse = Invoke-RestMethod `
        -Headers @{"Authorization"=$BasicAuthorization} `
        -Uri "https://$RegistryName/oauth2/token?service=$RegistryName&scope=$scope" `
        -Method GET `
        -TimeoutSec 30
    if (-not $tokenResponse.access_token) {
        throw "FATAL: ACR did not return a repository access token for $Repository"
    }
    return "Bearer $($tokenResponse.access_token)"
}

function Save-AcrLayer {
    param(
        [string]$RegistryName,
        [string]$Repository,
        [string]$Tag,
        [string]$Authorization,
        [string]$MediaType,
        [string]$Destination
    )

    $manifest = Invoke-RestMethod `
        -Headers @{
            "Authorization" = $Authorization
            "Accept" = "application/vnd.oci.image.manifest.v1+json"
        } `
        -Uri "https://$RegistryName/v2/$Repository/manifests/$Tag" `
        -Method GET `
        -TimeoutSec 30
    $layer = $manifest.layers |
        Where-Object { $_.mediaType -eq $MediaType } |
        Select-Object -First 1
    if (-not $layer) {
        throw "FATAL: OCI artifact $Repository`:$Tag does not contain a $MediaType layer"
    }

    Invoke-WebRequest `
        -Headers @{"Authorization"=$Authorization} `
        -Uri "https://$RegistryName/v2/$Repository/blobs/$($layer.digest)" `
        -OutFile $Destination `
        -UseBasicParsing `
        -TimeoutSec 120
}

try {
    $workDir = "C:\wtt\azure-bootstrap"
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $workDir -ItemType Directory -Force | Out-Null

    $commonScriptPath = "$workDir\configure-windows-iis.ps1"
    $artifactPath = "$workDir\netfx48-server.zip"
    $certificatePfxPath = "$workDir\tls.pfx"

    $vaultToken = Get-AzureManagedIdentityToken -Resource "https://vault.azure.net"
    $dockerConfig = Get-AzureKeyVaultSecret `
        -VaultName $KeyVaultName `
        -SecretName "acr-pull-dockerconfigjson" `
        -Token $vaultToken
    $basicAuthorization = Get-AcrBasicAuthorization `
        -DockerConfigJson $dockerConfig `
        -RegistryName $Registry
    $artifactAuthorization = Get-AcrRepositoryAuthorization `
        -RegistryName $Registry `
        -Repository $ArtifactRepository `
        -BasicAuthorization $basicAuthorization
    $commonScriptAuthorization = Get-AcrRepositoryAuthorization `
        -RegistryName $Registry `
        -Repository $CommonScriptRepository `
        -BasicAuthorization $basicAuthorization
    Save-AcrLayer `
        -RegistryName $Registry `
        -Repository $ArtifactRepository `
        -Tag $ArtifactTag `
        -Authorization $artifactAuthorization `
        -MediaType "application/zip" `
        -Destination $artifactPath
    Save-AcrLayer `
        -RegistryName $Registry `
        -Repository $CommonScriptRepository `
        -Tag $ArtifactTag `
        -Authorization $commonScriptAuthorization `
        -MediaType "application/vnd.microsoft.powershell" `
        -Destination $commonScriptPath

    $certificatePfxBase64 = Get-AzureKeyVaultSecret `
        -VaultName $KeyVaultName `
        -SecretName "wtt-server-pfx" `
        -Token $vaultToken
    [IO.File]::WriteAllBytes($certificatePfxPath, [Convert]::FromBase64String($certificatePfxBase64))

    & $commonScriptPath `
        -ArtifactArchivePath $artifactPath `
        -CertificatePfxPath $certificatePfxPath `
        -TlsVersion $TlsVersion `
        -TlsGroup $TlsGroup `
        -PayloadPreallocate $payloadPreallocateValue
} finally {
    Stop-Transcript
}
