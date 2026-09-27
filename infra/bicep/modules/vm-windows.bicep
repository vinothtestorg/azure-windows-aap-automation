@description('Azure region for the VM and its network resources.')
param location string

@description('Tags applied to all resources in this module.')
param tags object

@description('Resource ID of the subnet the VM NIC attaches to.')
param subnetId string

@description('Local administrator username for the VM.')
param adminUsername string = 'azureadmin'

@secure()
@description('Local administrator password for the VM.')
param adminPassword string

@secure()
@description('Password set for the ansible_svc automation account by the Run Command.')
param ansiblePassword string

// Standard_B2ms (and every other common B-/D-series size checked) is
// NotAvailableForSubscription in this Free Trial subscription; Standard_D2as_v7
// is unrestricted with quota 0/4 on StandardDasv7Family and is Gen2/NVMe-only,
// hence the matching diskControllerType below (HLD ruling, 2026-09-28).
@description('VM size.')
param vmSize string = 'Standard_D2as_v7'

@description('DNS label for the public IP; the resulting FQDN is used as the PSRP certificate subject.')
param dnsLabel string = 'winapp-poc'

@description('Daily auto-shutdown time in 24h HHmm, UTC.')
param shutdownTimeUtc string = '1800'

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-winapp-vm'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-vm-winapp-01'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'vm-winapp-01'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      // Standard_D2as_v7 supports only the NVMe disk controller (no SCSI); the
      // image supports both, so this must be set explicitly.
      diskControllerType: 'NVMe'
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'vm-winapp-01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource configure 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'configure-remoting'
  location: location
  properties: {
    source: { script: loadTextContent('../scripts/configure-remoting.ps1') }
    parameters: [
      { name: 'AnsibleUser', value: 'ansible_svc' }
      { name: 'CertDnsName', value: pip.properties.dnsSettings.fqdn }
    ]
    protectedParameters: [
      { name: 'AnsiblePassword', value: ansiblePassword }
    ]
    asyncExecution: false
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}

resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-vm-winapp-01'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: shutdownTimeUtc
    }
    timeZoneId: 'UTC'
    targetResourceId: vm.id
    notificationSettings: {
      status: 'Disabled'
    }
  }
}

output fqdn string = pip.properties.dnsSettings.fqdn
output principalId string = vm.identity.principalId
