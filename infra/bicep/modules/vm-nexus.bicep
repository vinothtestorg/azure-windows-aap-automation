@description('Azure region for the VM and its network resources.')
param location string

@description('Tags applied to all resources in this module (env only; no app tag — the AAP inventory filters on app=demoapp).')
param tags object

@description('Resource ID of the subnet the VM NIC attaches to.')
param subnetId string

@description('Local administrator username for the VM.')
param adminUsername string = 'azureadmin'

@description('SSH public key for the admin user; the matching private key lives only on the admin workstation.')
param sshPublicKey string

// Standard_D2as_v7 is unrestricted on this Free Trial subscription (see
// vm-windows.bicep for the sizing rationale) and is Gen2/NVMe-only, hence the
// matching diskControllerType below.
@description('VM size.')
param vmSize string = 'Standard_D2as_v7'

@description('DNS label for the public IP; the resulting FQDN is the Caddy/Nexus hostname.')
param dnsLabel string = 'nexus-winapp-poc'

// Bicep injects the compose file and Caddyfile into the cloud-init template at
// the __COMPOSE__/__CADDYFILE__ placeholders. Each already sits on its own
// line indented 6 spaces under a `content: |` block scalar, so only the
// newlines inside the injected text need the extra 6-space indent to keep
// every line of the embedded file aligned under that block scalar; the first
// line inherits the template's own indentation already in front of the
// placeholder.
var composeIndented = replace(loadTextContent('../../nexus/docker-compose.yml'), '\n', '\n      ')
var caddyfileIndented = replace(loadTextContent('../../nexus/Caddyfile'), '\n', '\n      ')
var cloudInit = replace(
  replace(loadTextContent('../../nexus/cloud-init.yaml'), '__COMPOSE__', composeIndented),
  '__CADDYFILE__',
  caddyfileIndented
)

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-nexus'
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
  name: 'nic-vm-nexus-01'
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
  name: 'vm-nexus-01'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
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
      dataDisks: [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: 64
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: 'vm-nexus-01'
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
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

output fqdn string = pip.properties.dnsSettings.fqdn
