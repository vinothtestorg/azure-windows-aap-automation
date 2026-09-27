@description('Azure region for all network resources.')
param location string

@description('CIDR (in x.x.x.x/32 form) allowed to reach RDP and SSH admin ports.')
param adminSourceIp string

@description('Tags applied to all resources in this module.')
param tags object

var vnetName = 'vnet-winapp-poc'
var appSubnetName = 'snet-app'
var toolsSubnetName = 'snet-tools'

resource nsgApp 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-winapp-app'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-http-in'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        // Accepted risk K1: WinRM/PSRP over HTTPS open to Internet for the PoC.
        name: 'allow-psrp-https-in'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '5986'
        }
      }
      {
        name: 'allow-rdp-admin'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSourceIp
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource nsgTools 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-winapp-tools'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-https-in'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        // ACME HTTP-01 challenge + redirect to HTTPS.
        name: 'allow-http-in'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'allow-ssh-admin'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSourceIp
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.20.0.0/16' ]
    }
    // Declared explicitly (matching the platform default) so `deployment
    // group what-if` does not report drift on this property every run.
    privateEndpointVNetPolicies: 'Disabled'
    subnets: [
      {
        name: appSubnetName
        properties: {
          addressPrefix: '10.20.1.0/24'
          networkSecurityGroup: { id: nsgApp.id }
        }
      }
      {
        name: toolsSubnetName
        properties: {
          addressPrefix: '10.20.2.0/24'
          networkSecurityGroup: { id: nsgTools.id }
        }
      }
    ]
  }
}

output appSubnetId string = vnet.properties.subnets[0].id
output toolsSubnetId string = vnet.properties.subnets[1].id
