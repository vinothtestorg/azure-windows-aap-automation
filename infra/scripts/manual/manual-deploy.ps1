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

# Only touch the app pool / junction when the target release is actually
# changing. IIS/ASP.NET keeps the previously-loaded assembly resident in a
# running worker process and does not notice files changing underneath an
# already-open junction, so a version change would otherwise go unserved
# until the pool happened to recycle on its own for an unrelated reason.
# A same-version re-run must not bounce the site, so it skips this whole
# block. $current not existing yet (first-ever deploy) always takes the
# swap path below.
$needsSwap = $true
if (Test-Path $current) {
    if (@((Get-Item $current).Target) -contains $release) { $needsSwap = $false }
}

if ($needsSwap) {
    if ((Get-Item 'IIS:\AppPools\DemoAppPool').state -ne 'Stopped') {
        Stop-WebAppPool -Name 'DemoAppPool'
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Item 'IIS:\AppPools\DemoAppPool').state -ne 'Stopped') {
            if ((Get-Date) -gt $deadline) { throw 'timed out waiting for DemoAppPool to stop' }
            Start-Sleep -Milliseconds 500
        }
    }

    if (Test-Path $current) { cmd /c rmdir "$current" | Out-Null }
    New-Item -ItemType Junction -Path $current -Target $release | Out-Null

    Start-WebAppPool -Name 'DemoAppPool'
}

if (-not (Get-Website -Name 'DemoApp' -ErrorAction SilentlyContinue)) {
    New-Website -Name 'DemoApp' -Port 80 -PhysicalPath $current -ApplicationPool 'DemoAppPool' | Out-Null
}
if ((Get-Website -Name 'DemoApp').State -ne 'Started') { Start-Website -Name 'DemoApp' }

Add-Content -Path (Join-Path $root 'deployments.log') -Value ("{0:o} version={1} git_sha=manual job=manual result=success" -f (Get-Date).ToUniversalTime(), $Version)
"manual deploy ok $Version"
