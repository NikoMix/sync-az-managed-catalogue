#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[sync-az-managed-catalogue] $*"
}

error() {
  echo "[sync-az-managed-catalogue] ERROR: $*" >&2
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "Required command not found: ${cmd}"
    exit 1
  fi
}

require_env() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "$value" ]]; then
    error "Missing required input: ${name}"
    exit 1
  fi
}

safe_name() {
  local value="$1"
  value="${value,,}"
  value="${value//[^a-z0-9-]/-}"
  value="${value#-}"
  value="${value%-}"
  if [[ -z "$value" ]]; then
    value="managedapp"
  fi
  echo "$value"
}

require_command az
require_command zip

azure_login_credentials_json="${INPUT_AZURE_LOGIN_CREDENTIALS_JSON:-}"
creds_client_id=""
creds_tenant_id=""
creds_subscription_id=""

if [[ -n "$azure_login_credentials_json" ]]; then
  require_command python3

  mapfile -t creds_fields < <(
    INPUT_AZURE_LOGIN_CREDENTIALS_JSON="$azure_login_credentials_json" python3 - <<'PY'
import json
import os
import sys

raw = os.environ.get("INPUT_AZURE_LOGIN_CREDENTIALS_JSON", "").strip()
if not raw:
    print()
    print()
    print()
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception as exc:
    print(f"Invalid INPUT_AZURE_LOGIN_CREDENTIALS_JSON: {exc}", file=sys.stderr)
    sys.exit(2)

if not isinstance(data, dict):
    print("INPUT_AZURE_LOGIN_CREDENTIALS_JSON must be a JSON object", file=sys.stderr)
    sys.exit(2)

def pick(*keys):
    for key in keys:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""

print(pick("clientId", "client-id", "client_id"))
print(pick("tenantId", "tenant-id", "tenant_id"))
print(pick("subscriptionId", "subscription-id", "subscription_id"))
PY
  )

  if [[ ${#creds_fields[@]} -gt 0 ]]; then
    creds_client_id="${creds_fields[0]}"
  fi
  if [[ ${#creds_fields[@]} -gt 1 ]]; then
    creds_tenant_id="${creds_fields[1]}"
  fi
  if [[ ${#creds_fields[@]} -gt 2 ]]; then
    creds_subscription_id="${creds_fields[2]}"
  fi

  if [[ -z "${INPUT_SUBSCRIPTION_ID:-}" && -n "$creds_subscription_id" ]]; then
    INPUT_SUBSCRIPTION_ID="$creds_subscription_id"
  fi

  if [[ -z "${INPUT_AUTHORIZATION_PRINCIPAL_ID:-}" && -n "$creds_client_id" ]]; then
    resolved_principal_id="$(az ad sp show --id "$creds_client_id" --query id --output tsv 2>/dev/null || true)"
    if [[ -n "$resolved_principal_id" ]]; then
      INPUT_AUTHORIZATION_PRINCIPAL_ID="$resolved_principal_id"
      log "Resolved authorization-principal-id from azure-login-credentials-json clientId"
    else
      log "Could not auto-resolve authorization-principal-id from clientId; provide authorization-principal-id explicitly"
    fi
  fi

  if [[ -n "$creds_tenant_id" ]]; then
    log "Read tenantId from azure-login-credentials-json"
  fi
fi

require_env INPUT_STORAGE_ACCOUNT_NAME
require_env INPUT_STORAGE_ACCOUNT_KEY
require_env INPUT_DEFINITION_RESOURCE_GROUP
require_env INPUT_DEFINITION_LOCATION
require_env INPUT_AUTHORIZATION_PRINCIPAL_ID
require_env INPUT_AUTHORIZATION_ROLE_DEFINITION_ID

source_folder="${INPUT_SOURCE_FOLDER:-catalog}"
storage_account_name="${INPUT_STORAGE_ACCOUNT_NAME}"
storage_account_key="${INPUT_STORAGE_ACCOUNT_KEY}"
storage_container="${INPUT_STORAGE_CONTAINER:-managedapp-packages}"
definition_resource_group="${INPUT_DEFINITION_RESOURCE_GROUP}"
definition_location="${INPUT_DEFINITION_LOCATION}"
default_authorizations="${INPUT_AUTHORIZATION_PRINCIPAL_ID}:${INPUT_AUTHORIZATION_ROLE_DEFINITION_ID}"
default_lock_level="${INPUT_LOCK_LEVEL:-ReadOnly}"
name_prefix="${INPUT_NAME_PREFIX:-}"
subscription_id="${INPUT_SUBSCRIPTION_ID:-}"
register_solutions_provider_raw="${INPUT_REGISTER_SOLUTIONS_PROVIDER:-true}"
bicep_template_name="${INPUT_BICEP_TEMPLATE_NAME:-main}"
bicep_template_name="${bicep_template_name%.bicep}"

register_solutions_provider="true"
case "${register_solutions_provider_raw,,}" in
  true|1|yes|y|on)
    register_solutions_provider="true"
    ;;
  false|0|no|n|off)
    register_solutions_provider="false"
    ;;
  *)
    error "Invalid boolean value for register-solutions-provider: ${register_solutions_provider_raw}"
    exit 1
    ;;
esac

if [[ -z "$bicep_template_name" ]]; then
  bicep_template_name="main"
fi

# Mask the storage key in workflow logs.
echo "::add-mask::${storage_account_key}"

if ! az account show >/dev/null 2>&1; then
  error "Azure CLI is not authenticated. Run azure/login before this action."
  exit 1
fi

if [[ -n "$subscription_id" ]]; then
  log "Setting Azure subscription context to ${subscription_id}"
  az account set --subscription "$subscription_id"
fi

if [[ "$register_solutions_provider" == "true" ]]; then
  provider_namespace="Microsoft.Solutions"
  provider_state="$(az provider show --namespace "$provider_namespace" --query registrationState --output tsv 2>/dev/null || true)"

  if [[ "$provider_state" != "Registered" ]]; then
    log "Attempting to register resource provider ${provider_namespace} (current state: ${provider_state:-Unknown})"
    if az provider register --namespace "$provider_namespace" --wait --output none; then
      log "Resource provider ${provider_namespace} is registered"
    else
      echo "::warning::[sync-az-managed-catalogue] Failed to register ${provider_namespace}. Ensure it is pre-registered or grant Microsoft.Resources/subscriptions/providers/register/action."
    fi
  else
    log "Resource provider ${provider_namespace} is already registered"
  fi
else
  log "Skipping resource provider registration because register-solutions-provider is disabled"
fi

if [[ ! -d "$source_folder" ]]; then
  error "Source folder does not exist: ${source_folder}"
  exit 1
fi

log "Ensuring storage container exists: ${storage_container}"
if ! az storage container create \
  --name "$storage_container" \
  --account-name "$storage_account_name" \
  --account-key "$storage_account_key" \
  --public-access off \
  --output none; then
  error "Failed to ensure storage container exists: ${storage_container}"
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

processed_count=0
created_count=0
updated_count=0
failed_count=0

process_folder() {
  local folder="$1"
  local folder_name
  folder_name="$(basename "$folder")"

  local main_template="${folder}/mainTemplate.json"
  local bicep_file="${folder}/${bicep_template_name}.bicep"
  local create_ui="${folder}/createUiDefinition.json"

  if [[ -f "$bicep_file" ]]; then
    if [[ -f "$main_template" ]]; then
      local transpiled_tmp="${tmp_dir}/${folder_name}-transpiled-mainTemplate.json"
      log "Compiling ${bicep_template_name}.bicep for validation in ${folder_name}"
      if ! az bicep build --file "$bicep_file" --outfile "$transpiled_tmp" --output none; then
        error "Skipping ${folder_name}: failed to compile ${bicep_template_name}.bicep"
        return 1
      fi
      echo "::warning::[sync-az-managed-catalogue] ${folder_name}: mainTemplate.json already exists. Using existing file and not overriding it."
    else
      log "Compiling ${bicep_template_name}.bicep -> mainTemplate.json for ${folder_name}"
      if ! az bicep build --file "$bicep_file" --outfile "$main_template" --output none; then
        error "Skipping ${folder_name}: failed to compile ${bicep_template_name}.bicep"
        return 1
      fi
    fi
  elif [[ ! -f "$main_template" ]]; then
    error "Skipping ${folder_name}: missing ${bicep_template_name}.bicep and mainTemplate.json"
    return 1
  fi

  if [[ -f "$create_ui" ]]; then
    log "Including optional createUiDefinition.json in package for ${folder_name}"
  else
    log "Optional createUiDefinition.json not found for ${folder_name}; continuing"
  fi

  local definition_name
  definition_name="$(safe_name "${name_prefix}${folder_name}")"
  local display_name
  display_name="${folder_name}"
  local description
  description="Managed application definition published from folder ${folder_name}"
  local lock_level
  lock_level="$default_lock_level"
  local authorizations
  authorizations="$default_authorizations"
  local target_resource_group
  target_resource_group="$definition_resource_group"
  local target_location
  target_location="$definition_location"

  local metadata_file="${folder}/managedapp-metadata.json"
  if [[ -f "$metadata_file" ]]; then
    require_command python3
    definition_name="$(python3 - "$metadata_file" "$definition_name" <<'PY'
import json
import sys
path = sys.argv[1]
default = sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
print(data.get('name', default))
PY
)"
    display_name="$(python3 - "$metadata_file" "$display_name" <<'PY'
import json
import sys
path = sys.argv[1]
default = sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
print(data.get('displayName', default))
PY
)"
    description="$(python3 - "$metadata_file" "$description" <<'PY'
import json
import sys
path = sys.argv[1]
default = sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
print(data.get('description', default))
PY
)"
    lock_level="$(python3 - "$metadata_file" "$lock_level" <<'PY'
import json
import sys
path = sys.argv[1]
default = sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
print(data.get('lockLevel', default))
PY
)"
    authorizations="$(python3 - "$metadata_file" "$authorizations" <<'PY'
import json
import sys
path = sys.argv[1]
default = sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
value = data.get('authorizations', default)
if isinstance(value, list):
    print(' '.join(value))
else:
    print(value)
PY
)"
    target_resource_group="$(python3 - "$metadata_file" "$target_resource_group" <<'PY'
import json
import sys
path = sys.argv[1]
default = sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
print(data.get('resourceGroup', default))
PY
)"
    target_location="$(python3 - "$metadata_file" "$target_location" <<'PY'
import json
import sys
path = sys.argv[1]
default = sys.argv[2]
with open(path, encoding='utf-8') as f:
    data = json.load(f)
print(data.get('location', default))
PY
)"

    log "${folder_name}: managedapp-metadata.json overrides in effect (resourceGroup=${target_resource_group}, location=${target_location})"

    definition_name="$(safe_name "$definition_name")"
  fi

  local zip_path="${tmp_dir}/${definition_name}.zip"
  local blob_name
  blob_name="${definition_name}-$(date +%Y%m%d%H%M%S).zip"

  log "Packaging ${folder_name} -> ${zip_path}"
  (
    cd "$folder"
    zip -q -r "$zip_path" .
  )

  log "Uploading package blob ${blob_name}"
  if ! az storage blob upload \
    --account-name "$storage_account_name" \
    --account-key "$storage_account_key" \
    --container-name "$storage_container" \
    --name "$blob_name" \
    --file "$zip_path" \
    --overwrite true \
    --output none; then
    error "Skipping ${folder_name}: failed to upload package blob ${blob_name}"
    return 1
  fi

  local blob_url
  blob_url="$(az storage blob url \
    --account-name "$storage_account_name" \
    --account-key "$storage_account_key" \
    --container-name "$storage_container" \
    --name "$blob_name" \
    --output tsv 2>/dev/null || true)"

  if [[ -z "$blob_url" ]]; then
    error "Skipping ${folder_name}: failed to resolve blob URL for ${blob_name}"
    return 1
  fi

  local -a auth_args
  read -r -a auth_args <<< "$authorizations"
  if [[ ${#auth_args[@]} -eq 0 ]]; then
    error "Skipping ${folder_name}: authorizations resolved to empty value"
    return 1
  fi

  log "Publishing managed app definition ${definition_name} in resource group ${target_resource_group}"
  if az managedapp definition show \
    --name "$definition_name" \
    --resource-group "$target_resource_group" \
    --output none >/dev/null 2>&1; then
    local update_output
    if ! update_output="$(az managedapp definition update \
      --name "$definition_name" \
      --resource-group "$target_resource_group" \
      --lock-level "$lock_level" \
      --display-name "$display_name" \
      --description "$description" \
      --authorizations "${auth_args[@]}" \
      --package-file-uri "$blob_url" \
      --output none 2>&1)"; then
      error "Skipping ${folder_name}: failed to update definition ${definition_name} in ${target_resource_group}"
      echo "$update_output" >&2
      return 1
    fi

    if [[ "$update_output" == *"AuthorizationFailed"* || "$update_output" == *"ERROR:"* ]]; then
      error "Skipping ${folder_name}: update reported an authorization/platform error for ${definition_name} in ${target_resource_group}"
      echo "$update_output" >&2
      return 1
    fi

    if ! az managedapp definition show \
      --name "$definition_name" \
      --resource-group "$target_resource_group" \
      --query id \
      --output tsv >/dev/null 2>&1; then
      error "Skipping ${folder_name}: update did not produce an accessible definition ${definition_name} in ${target_resource_group}"
      return 1
    fi

    updated_count=$((updated_count + 1))
  else
    local create_output
    if ! create_output="$(az managedapp definition create \
      --name "$definition_name" \
      --resource-group "$target_resource_group" \
      --location "$target_location" \
      --lock-level "$lock_level" \
      --display-name "$display_name" \
      --description "$description" \
      --authorizations "${auth_args[@]}" \
      --package-file-uri "$blob_url" \
      --output none 2>&1)"; then
      error "Skipping ${folder_name}: failed to create definition ${definition_name} in ${target_resource_group}"
      echo "$create_output" >&2
      return 1
    fi

    if [[ "$create_output" == *"AuthorizationFailed"* || "$create_output" == *"ERROR:"* ]]; then
      error "Skipping ${folder_name}: create reported an authorization/platform error for ${definition_name} in ${target_resource_group}"
      echo "$create_output" >&2
      return 1
    fi

    if ! az managedapp definition show \
      --name "$definition_name" \
      --resource-group "$target_resource_group" \
      --query id \
      --output tsv >/dev/null 2>&1; then
      error "Skipping ${folder_name}: create did not produce an accessible definition ${definition_name} in ${target_resource_group}"
      return 1
    fi

    created_count=$((created_count + 1))
  fi

  processed_count=$((processed_count + 1))
  return 0
}

shopt -s nullglob
folders=("${source_folder}"/*/)
shopt -u nullglob

if [[ ${#folders[@]} -eq 0 ]]; then
  error "No subfolders found under source folder: ${source_folder}"
  exit 1
fi

for folder in "${folders[@]}"; do
  if ! process_folder "${folder%/}"; then
    failed_count=$((failed_count + 1))
  fi
done

if [[ "$failed_count" -gt 0 ]]; then
  error "Completed with failures. processed=${processed_count}, failed=${failed_count}"
  exit 1
fi

log "Completed successfully. processed=${processed_count}, created=${created_count}, updated=${updated_count}"

{
  echo "processed-count=${processed_count}"
  echo "created-count=${created_count}"
  echo "updated-count=${updated_count}"
} >> "$GITHUB_OUTPUT"
