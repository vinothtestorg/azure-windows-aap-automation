<#
  Runs once through a managed Run Command on vm-winapp-01.
  Installs IIS + ASP.NET 4.x, creates the automation account, and exposes
  PowerShell remoting over HTTPS 5986 only.
#>
param(
    [Parameter(Mandatory)] [string] $AnsibleUser,
    [Parameter(Mandatory)] [string] $AnsiblePassword,
    [Parameter(Mandatory)] [string] $CertDnsName
)
$ErrorActionPreference = 'Stop'

# IIS and ASP.NET 4.x
Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, NET-Framework-45-ASPNET, Web-Mgmt-Console | Out-Null

# Automation account (local admin; required for IIS management)
$secure = ConvertTo-SecureString $AnsiblePassword -AsPlainText -Force
if (Get-LocalUser -Name $AnsibleUser -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $AnsibleUser -Password $secure -PasswordNeverExpires $true
} else {
    New-LocalUser -Name $AnsibleUser -Password $secure -PasswordNeverExpires -AccountNeverExpires -Description 'Ansible automation (PoC)' | Out-Null
}
if (-not (Get-LocalGroupMember -Group 'Administrators' -Member $AnsibleUser -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group 'Administrators' -Member $AnsibleUser
}
# Local admin accounts need a full token over remoting
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null

# Lockout high enough that password spraying cannot lock out the pipeline (HLD section 9)
net accounts /lockoutthreshold:20 /lockoutwindow:15 /lockoutduration:15 | Out-Null

# HTTPS listener on 5986 with a self-signed certificate; HTTP listener removed
Enable-PSRemoting -SkipNetworkProfileCheck -Force | Out-Null
$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -eq "CN=$CertDnsName" -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
    Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName $CertDnsName, $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(1)
}
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' } | Remove-Item -Recurse -Force
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTP' } | Remove-Item -Recurse -Force
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false

if (-not (Get-NetFirewallRule -Name 'PSRP-HTTPS-In' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'PSRP-HTTPS-In' -DisplayName 'PowerShell remoting HTTPS (5986)' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow | Out-Null
}
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule

Write-Output "remoting configured: https listener thumbprint $($cert.Thumbprint)"
