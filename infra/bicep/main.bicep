targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = 'eastus'

@description('CIDR (x.x.x.x/32) allowed to reach RDP/SSH admin ports.')
param adminSourceIp string = '161.142.151.25/32'

@description('Object ID of the engineer/service principal running this deployment.')
param deployerObjectId string

@description('GitHub org that owns this repository, used for OIDC federation subject.')
param githubOrg string = 'vinothtestorg'

@description('GitHub repository name, used for OIDC federation subject.')
param githubRepo string = 'azure-windows-aap-automation'

@description('When true, deploys compute modules (Tasks 4 and 5) in addition to the foundation.')
param deployCompute bool = false

// Consumed by the Task 5 compute module; the foundation pass has no compute yet.
// The matching private key lives only on the admin workstation (deploy.sh
// generates it under ~/.ssh and never commits it).
@description('SSH public key for the Nexus VM admin user (Task 5). Empty during the foundation-only pass.')
param nexusSshPublicKey string = ''

var kvName = 'kv-winapp-poc-${take(uniqueString(resourceGroup().id), 6)}'
var commonTags = { env: 'poc' }

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    adminSourceIp: adminSourceIp
    tags: commonTags
  }
}

module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: kvName
    location: location
    tags: commonTags
    deployerObjectId: deployerObjectId
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    tags: commonTags
    githubOrg: githubOrg
    githubRepo: githubRepo
  }
}

// The nexus-deployer-password secret is seeded after the foundation-only pass,
// so this assignment is gated on deployCompute: it only exists once the
// compute pass runs (Tasks 4/5), by which point seed-secrets.sh has run.
module ghDeployerNexusSecretReader 'modules/secret-reader.bicep' = if (deployCompute) {
  name: 'gh-deployer-nexus-secret-reader'
  params: {
    vaultName: keyvault.outputs.name
    secretName: 'nexus-deployer-password'
    principalId: identity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// Compute (Tasks 4 and 5)

resource kvRef 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: kvName }

module appVm 'modules/vm-windows.bicep' = if (deployCompute) {
  name: 'app-vm'
  params: {
    location: location
    tags: commonTags
    subnetId: network.outputs.appSubnetId
    adminPassword: kvRef.getSecret('vm-admin-password')
    ansiblePassword: kvRef.getSecret('ansible-svc-password')
  }
}

// Task 5's Nexus deployer reads the app VM's automation credential too, so the
// app VM's own identity only needs read access to the Nexus reader secret it
// consumes at configuration time.
module appVmSecret 'modules/secret-reader.bicep' = if (deployCompute) {
  name: 'app-vm-nexus-reader-secret'
  params: {
    vaultName: keyvault.outputs.name
    secretName: 'nexus-reader-password'
    // ARM's if() short-circuits, so appVm.outputs is never actually read when
    // deployCompute is false; BCP318 cannot see that the ternary and the
    // module's own condition are the same expression.
    #disable-next-line BCP318
    principalId: deployCompute ? appVm.outputs.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

module nexusVm 'modules/vm-nexus.bicep' = if (deployCompute) {
  name: 'nexus-vm'
  params: {
    location: location
    tags: commonTags
    subnetId: network.outputs.toolsSubnetId
    sshPublicKey: nexusSshPublicKey
  }
}

output keyVaultName string = keyvault.outputs.name
output keyVaultUri string = keyvault.outputs.uri
output ghDeployerClientId string = identity.outputs.clientId
output ghDeployerPrincipalId string = identity.outputs.principalId
output appSubnetId string = network.outputs.appSubnetId
output toolsSubnetId string = network.outputs.toolsSubnetId
// Same BCP318 false positive as above: guarded by the identical deployCompute condition.
#disable-next-line BCP318
output appVmFqdn string = deployCompute ? appVm.outputs.fqdn : ''
#disable-next-line BCP318
output appVmPrincipalId string = deployCompute ? appVm.outputs.principalId : ''
#disable-next-line BCP318
output nexusFqdn string = deployCompute ? nexusVm.outputs.fqdn : ''
