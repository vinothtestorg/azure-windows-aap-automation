param(
    [Parameter(Mandatory)] [string] $Root,
    [Parameter(Mandatory)] [string] $PoolName,
    [Parameter(Mandatory)] [string] $SiteName,
    [string] $Version,
    [string] $TargetPath
)
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration
$current = Join-Path $Root 'current'
$target = if ($TargetPath) { $TargetPath } else { Join-Path $Root "releases\$Version" }
$previous = ''
if (Test-Path $current) { $previous = [string]((Get-Item $current -Force).Target | Select-Object -First 1) }
if ($previous -eq $target) {
    $Ansible.Changed = $false
    $Ansible.Result = @{ previous = $previous; switched = $false }
    return
}
if ((Get-WebAppPoolState -Name $PoolName).Value -ne 'Stopped') {
    Stop-WebAppPool -Name $PoolName
    for ($i = 0; $i -lt 30 -and (Get-WebAppPoolState -Name $PoolName).Value -ne 'Stopped'; $i++) { Start-Sleep -Seconds 1 }
}
if (Test-Path $current) { cmd /c rmdir "$current" | Out-Null }   # removes the junction only, never the release
New-Item -ItemType Junction -Path $current -Target $target | Out-Null
Start-WebAppPool -Name $PoolName
if ((Get-Website -Name $SiteName).State -ne 'Started') { Start-Website -Name $SiteName }
$Ansible.Result = @{ previous = $previous; switched = $true }
$Ansible.Changed = $true
