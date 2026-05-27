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
| authorization-principal-id | Conditionally | empty | Principal object ID granted permissions on managed resource groups. If omitted and azure-login-credentials-json is provided, action tries to resolve it from clientId |
| authorization-role-definition-id | Yes | - | Role definition ID (GUID) used with the principal |
| azure-login-credentials-json | No | empty | Optional Azure login JSON (same shape as azure/login creds) used to derive subscription-id and authorization-principal-id |
| lock-level | No | ReadOnly | Managed application lock level |
| name-prefix | No | empty | Prefix added to generated definition names |
| subscription-id | No | empty | Subscription to set before processing |
| register-solutions-provider | No | true | Attempts to register Microsoft.Solutions provider before publish; disable if registration is centrally managed |
| bicep-template-name | No | main | Bicep template base filename (without extension), compiled to fixed output name `mainTemplate.json` |

## Azure Login JSON Mapping

When you pass `azure-login-credentials-json`, the action reads these fields:

- `subscriptionId` -> `subscription-id` (only when `subscription-id` input is empty)
- `clientId` -> used to resolve `authorization-principal-id` via `az ad sp show --id <clientId> --query id`
- `tenantId` -> read for validation/logging only

The action does not use `clientSecret` directly.

By default, the action also attempts to register the `Microsoft.Solutions` resource provider (`register-solutions-provider: true`).

These required values are not available in the Azure login JSON and must still be provided separately:

- `storage-account-name`
- `storage-account-key`
- `definition-resource-group`
- `definition-location`
- `authorization-role-definition-id`

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

Important: If `managedapp-metadata.json` contains `resourceGroup`, it overrides the top-level `definition-resource-group` input for that package. The managed app definition scope in Azure errors will then reference the metadata-provided resource group.

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
					azure-login-credentials-json: ${{ secrets.AZURE_CREDENTIALS }}
					storage-account-name: ${{ secrets.PACKAGE_STORAGE_ACCOUNT_NAME }}
					storage-account-key: ${{ secrets.PACKAGE_STORAGE_ACCOUNT_KEY }}
					storage-container: managedapp-packages
					definition-resource-group: managed-app-definition-rg
					definition-location: westeurope
					authorization-role-definition-id: ${{ secrets.MANAGEDAPP_ROLE_DEFINITION_ID }}
					register-solutions-provider: true
					lock-level: ReadOnly
```

## Required Azure Permissions

Your logged-in identity must be able to:

1. Upload blobs in the target storage account/container.
2. Create or update managed application definitions in definition-resource-group.
3. Perform the Azure RBAC action `Microsoft.Solutions/applicationDefinitions/write` at the scope of the target definition resource group (or higher).
4. Read role/principal IDs you provide.
5. Optional when `register-solutions-provider` is true: perform `Microsoft.Resources/subscriptions/providers/register/action` at subscription scope to register `Microsoft.Solutions`.

## Best Practices

1. Use OIDC with azure/login instead of stored Azure credentials.
2. Store storage-account-key in GitHub Secrets and rotate regularly.
3. Pin this action to a release tag or commit SHA in production workflows.
4. Keep package zip size and contents minimal and intentional.
5. Use least-privilege role assignments for authorization-principal-id.