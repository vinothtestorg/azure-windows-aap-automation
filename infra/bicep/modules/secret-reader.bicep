@description('Grants Key Vault Secrets User on ONE secret.')
param vaultName string
param secretName string
param principalId string
@allowed([ 'ServicePrincipal', 'User', 'Group' ])
param principalType string = 'ServicePrincipal'

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: vaultName }
resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = { parent: kv, name: secretName }

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: secret
  name: guid(secret.id, principalId, '4633458b-17de-408a-b874-0445c86b69e6')
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}
