param location string
param tags object
param githubOrg string
param githubRepo string

resource ghDeployer 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-gh-deployer'
  location: location
  tags: tags
}

// The federated credential's resource NAME (unlike its subject, below) is
// validated by Azure against a reserved/trademarked-word list; embedding the
// repo name here (it contains "azure"/"windows") is rejected with
// ReservedResourceName, so the name is a fixed, repo-agnostic string. The
// subject claim is what actually has to match the GitHub OIDC token.
resource ghFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: ghDeployer
  name: 'github-oidc-poc'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubOrg}/${githubRepo}:environment:poc'
    audiences: [ 'api://AzureADTokenExchange' ]
  }
}

output clientId string = ghDeployer.properties.clientId
output principalId string = ghDeployer.properties.principalId
