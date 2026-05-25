# sync-az-managed-catalogue

GitHub Action to publish Azure Managed Application definitions from a folder structure.

The action runs with Bash and Azure CLI on Ubuntu runners. For each subfolder in your source directory, it:

1. Resolves deployment template files in this order:
	- If `<bicep-template-name>.bicep` exists (default `main.bicep`), it compiles to `mainTemplate.json`.
	- If `mainTemplate.json` already exists, the action keeps it, validates Bicep compilation, and emits a warning instead of overwriting.
	- If no Bicep file exists, it requires an existing `mainTemplate.json`.
2. Packages the folder into a zip archive.
3. Uploads the package to Azure Blob Storage.
4. Creates or updates the Azure Managed Application definition.

`createUiDefinition.json` is optional and included in the package only when present.

This implementation follows the Azure CLI publish flow from Microsoft Learn:
https://learn.microsoft.com/azure/azure-resource-manager/managed-applications/publish-service-catalog-app?tabs=azure-cli

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| source-folder | No | catalog | Folder containing one subfolder per managed application package |
| storage-account-name | Yes | - | Storage account name for package blobs |
| storage-account-key | Yes | - | Storage account key used for blob operations |
| storage-container | No | managedapp-packages | Blob container to store package zip files |
| definition-resource-group | Yes | - | Resource group that stores managed app definitions |
| definition-location | Yes | - | Azure region for managed app definitions |
| authorization-principal-id | Yes | - | Principal object ID granted permissions on managed resource groups |
| authorization-role-definition-id | Yes | - | Role definition ID (GUID) used with the principal |
| lock-level | No | ReadOnly | Managed application lock level |
| name-prefix | No | empty | Prefix added to generated definition names |
| subscription-id | No | empty | Subscription to set before processing |
| bicep-template-name | No | main | Bicep template base filename (without extension), compiled to fixed output name `mainTemplate.json` |

## Outputs

| Name | Description |
| --- | --- |
| processed-count | Number of package folders published successfully |
| created-count | Number of definitions created |
| updated-count | Number of definitions updated |

## Expected Folder Layout

The action scans subfolders under source-folder.

Example:

```text
catalog/
	webapp-a/
		main.bicep              # optional (preferred when present)
		mainTemplate.json       # required only when no Bicep file is found
		createUiDefinition.json # optional
		managedapp-metadata.json   # optional
	webapp-b/
		mainTemplate.json
```

Each package zip is created from the subfolder content. Keep template files at the subfolder root.

## Optional Per-Folder Metadata

Add managedapp-metadata.json in a package folder to override defaults.

```json
{
	"name": "contoso-webapp-a",
	"displayName": "Contoso Web App A",
	"description": "Managed app for Contoso Web App A",
	"lockLevel": "ReadOnly",
	"authorizations": [
		"<principal-object-id>:<role-definition-id>"
	],
	"resourceGroup": "managed-app-definitions-rg",
	"location": "westeurope"
}
```

If omitted, the action uses top-level input defaults.

## Usage From External Repository

Use azure/login first, then call this action.

```yaml
name: Publish Managed Apps

on:
	workflow_dispatch:

permissions:
	contents: read
	id-token: write

jobs:
	publish:
		runs-on: ubuntu-latest
		steps:
			- name: Checkout source repo
				uses: actions/checkout@v4

			- name: Azure login (OIDC)
				uses: azure/login@v2
				with:
					client-id: ${{ secrets.AZURE_CLIENT_ID }}
					tenant-id: ${{ secrets.AZURE_TENANT_ID }}
					subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

			- name: Publish managed app definitions
				uses: nikomix/sync-az-managed-catalogue@v1
				with:
					source-folder: catalog
					storage-account-name: ${{ secrets.PACKAGE_STORAGE_ACCOUNT_NAME }}
					storage-account-key: ${{ secrets.PACKAGE_STORAGE_ACCOUNT_KEY }}
					storage-container: managedapp-packages
					definition-resource-group: managed-app-definition-rg
					definition-location: westeurope
					authorization-principal-id: ${{ secrets.MANAGEDAPP_PRINCIPAL_ID }}
					authorization-role-definition-id: ${{ secrets.MANAGEDAPP_ROLE_DEFINITION_ID }}
					lock-level: ReadOnly
```

## Required Azure Permissions

Your logged-in identity must be able to:

1. Upload blobs in the target storage account/container.
2. Create or update managed application definitions in definition-resource-group.
3. Read role/principal IDs you provide.

## Best Practices

1. Use OIDC with azure/login instead of stored Azure credentials.
2. Store storage-account-key in GitHub Secrets and rotate regularly.
3. Pin this action to a release tag or commit SHA in production workflows.
4. Keep package zip size and contents minimal and intentional.
5. Use least-privilege role assignments for authorization-principal-id.