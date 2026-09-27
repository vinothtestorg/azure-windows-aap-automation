Initial State:
1. Build a simple .NET Framework 4.7.2 app
2. Create a Windows VM in azure to run the app
3. Deploy the app to windows VM manually.

Automation:
4. Connect Windows VM to ansible automation platform.
5. Add VM to inventory.
6. Write a ansible job template to automate app deployment (CD)
7. Write CI with github actions
8. With artifact call CD ansible job template from github actions to perform CD.
9. Validate job template and workflow works.
10. Create CD design diagram.
11. Workout Azure Managed Identity based RBAC for Ansible trigger and run. Can use SP as fallback.

Definition of Done:
1. Working .NET Framework 4.7.2 app
2. Windows VM hosting the app sucessfully (manual)
3. Ansible inventory for windows VM and connection
4. Ansible job template to automate CD for windows VM + .Net app.
5. github actions to do CI and then CD -> call ansible template.
6. Entire CD infra and workflow design diagram.
7. Ansible RBAC using Managed identity / SP.