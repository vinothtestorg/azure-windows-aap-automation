using './main.bicep'

param location = 'eastus'
param adminSourceIp = '161.142.151.25/32'
param githubOrg = 'vinothtestorg'
param githubRepo = 'azure-windows-aap-automation'
param githubOrgId = '289159619'
param githubRepoId = '1390388831'
param deployerObjectId = readEnvironmentVariable('DEPLOYER_OBJECT_ID')
param deployCompute = bool(readEnvironmentVariable('DEPLOY_COMPUTE', 'false'))
param nexusSshPublicKey = readEnvironmentVariable('NEXUS_SSH_PUBLIC_KEY', '')
