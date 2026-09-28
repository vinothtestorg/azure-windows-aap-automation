param(
    [Parameter(Mandatory)] [string] $ArtifactUrl,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Sha256,
    [Parameter(Mandatory)] [string] $KeyVaultName
)
$ErrorActionPreference = 'Stop'
$root = 'C:\inetpub\demoapp'
$release = Join-Path $root "releases\$Version"
$current = Join-Path $root 'current'
$zip = Join-Path $root "staging\DemoApp-$Version.zip"
New-Item -ItemType Directory -Force -Path (Join-Path $root 'releases'), (Join-Path $root 'staging') | Out-Null

# Nexus reader password via the VM managed identity
$token = (Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net').access_token
$pw = (Invoke-RestMethod -Headers @{Authorization="Bearer $token"} -Uri "https://$KeyVaultName.vault.azure.net/secrets/nexus-reader-password?api-version=7.4").value
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("svc-win-reader:${pw}"))
Invoke-WebRequest -UseBasicParsing -Headers @{Authorization="Basic $basic"} -Uri $ArtifactUrl -OutFile $zip
if ((Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant() -ne $Sha256) { throw 'checksum mismatch' }
if (-not (Test-Path $release)) { Expand-Archive -Path $zip -DestinationPath $release }

Import-Module WebAdministration
if (Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue) { Remove-Website -Name 'Default Web Site' }
if (-not (Test-Path 'IIS:\AppPools\DemoAppPool')) { New-WebAppPool -Name 'DemoAppPool' | Out-Null }
Set-ItemProperty 'IIS:\AppPools\DemoAppPool' -Name managedRuntimeVersion -Value 'v4.0'
Set-ItemProperty 'IIS:\AppPools\DemoAppPool' -Name managedPipelineMode -Value 'Integrated'
if (Test-Path $current) { cmd /c rmdir "$current" | Out-Null }
New-Item -ItemType Junction -Path $current -Target $release | Out-Null
if (-not (Get-Website -Name 'DemoApp' -ErrorAction SilentlyContinue)) {
    New-Website -Name 'DemoApp' -Port 80 -PhysicalPath $current -ApplicationPool 'DemoAppPool' | Out-Null
}
Start-Website -Name 'DemoApp'
Add-Content -Path (Join-Path $root 'deployments.log') -Value ("{0:o} version={1} git_sha=manual job=manual result=success" -f (Get-Date).ToUniversalTime(), $Version)
"manual deploy ok $Version"
