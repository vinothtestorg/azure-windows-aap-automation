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

function Start-DemoAppPoolAndSite {
    # Best-effort: called both on the happy path and while recovering from a
    # failure, so it must never itself throw past a genuinely broken pool -
    # the caller already has (or is building) the real error to report.
    Start-WebAppPool -Name $PoolName
    if ((Get-Website -Name $SiteName).State -ne 'Started') { Start-Website -Name $SiteName }
}

# I2 fix: previously, any exception after Stop-WebAppPool (pool not
# stopping in 30s, `cmd /c rmdir` failing silently, or Start-WebAppPool/
# Start-Website throwing) left the pool stopped or an unverified release
# live, with no rollback - tasks/switch.yml never got to set
# demoapp_switched, so tasks/rollback.yml's `when` never fired. Wrap the
# whole stop/swap/start sequence in try/catch: on any failure, best-effort
# restore the junction to $previous (if it changed and $previous is
# non-empty) and make sure the pool and site are running, THEN rethrow the
# original error so the play still fails and demoapp_deploy's block/rescue
# still records the failure.
try {
    if ((Get-WebAppPoolState -Name $PoolName).Value -ne 'Stopped') {
        Stop-WebAppPool -Name $PoolName
        for ($i = 0; $i -lt 30 -and (Get-WebAppPoolState -Name $PoolName).Value -ne 'Stopped'; $i++) { Start-Sleep -Seconds 1 }
        if ((Get-WebAppPoolState -Name $PoolName).Value -ne 'Stopped') { throw "$PoolName did not stop within 30s" }
    }
    if (Test-Path $current) {
        cmd /c rmdir "$current" | Out-Null   # removes the junction only, never the release
        if ($LASTEXITCODE -ne 0) { throw "cmd /c rmdir on $current failed with exit code $LASTEXITCODE" }
    }
    New-Item -ItemType Junction -Path $current -Target $target | Out-Null
    Start-DemoAppPoolAndSite
}
catch {
    $originalFailure = $_
    try {
        # Restore is needed whenever $current is missing (rmdir succeeded
        # but the New-Item below it never ran or failed) or still/now
        # points somewhere other than $previous (New-Item succeeded but
        # Start-WebAppPool/Start-Website then threw, leaving an unverified
        # release live). If $current already points at $previous untouched
        # (e.g. Stop-WebAppPool itself threw before anything else ran),
        # there is nothing to repoint.
        if ($previous) {
            $needsRestore = $true
            if (Test-Path $current) {
                $currentTarget = [string]((Get-Item $current -Force).Target | Select-Object -First 1)
                if ($currentTarget -eq $previous) { $needsRestore = $false }
            }
            if ($needsRestore) {
                if (Test-Path $current) { cmd /c rmdir "$current" | Out-Null }
                New-Item -ItemType Junction -Path $current -Target $previous -ErrorAction Stop | Out-Null
            }
        }
        Start-DemoAppPoolAndSite
    }
    catch {
        # The restore itself failed - surface both errors rather than
        # silently swallowing the restore failure behind the original one.
        throw "switch to $target failed ($($originalFailure.Exception.Message)); best-effort restore to '$previous' also failed: $($_.Exception.Message)"
    }
    throw $originalFailure
}

$Ansible.Result = @{ previous = $previous; switched = $true }
$Ansible.Changed = $true
