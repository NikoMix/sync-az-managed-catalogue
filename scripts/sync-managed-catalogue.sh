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

if [[ ! -d "$source_folder" ]]; then
  error "Source folder does not exist: ${source_folder}"
  exit 1
fi

log "Ensuring storage container exists: ${storage_container}"
az storage container create \
  --name "$storage_container" \
  --account-name "$storage_account_name" \
  --account-key "$storage_account_key" \
  --public-access off \
  --output none

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
  local create_ui="${folder}/createUiDefinition.json"

  if [[ ! -f "$main_template" ]]; then
    error "Skipping ${folder_name}: missing mainTemplate.json"
    return 1
  fi

  if [[ ! -f "$create_ui" ]]; then
    error "Skipping ${folder_name}: missing createUiDefinition.json"
    return 1
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
  az storage blob upload \
    --account-name "$storage_account_name" \
    --account-key "$storage_account_key" \
    --container-name "$storage_container" \
    --name "$blob_name" \
    --file "$zip_path" \
    --overwrite true \
    --output none

  local blob_url
  blob_url="$(az storage blob url \
    --account-name "$storage_account_name" \
    --account-key "$storage_account_key" \
    --container-name "$storage_container" \
    --name "$blob_name" \
    --output tsv)"

  local -a auth_args
  read -r -a auth_args <<< "$authorizations"
  if [[ ${#auth_args[@]} -eq 0 ]]; then
    error "Skipping ${folder_name}: authorizations resolved to empty value"
    return 1
  fi

  log "Publishing managed app definition ${definition_name}"
  if az managedapp definition show \
    --name "$definition_name" \
    --resource-group "$target_resource_group" \
    --output none >/dev/null 2>&1; then
    az managedapp definition update \
      --name "$definition_name" \
      --resource-group "$target_resource_group" \
      --lock-level "$lock_level" \
      --display-name "$display_name" \
      --description "$description" \
      --authorizations "${auth_args[@]}" \
      --package-file-uri "$blob_url" \
      --output none
    updated_count=$((updated_count + 1))
  else
    az managedapp definition create \
      --name "$definition_name" \
      --resource-group "$target_resource_group" \
      --location "$target_location" \
      --lock-level "$lock_level" \
      --display-name "$display_name" \
      --description "$description" \
      --authorizations "${auth_args[@]}" \
      --package-file-uri "$blob_url" \
      --output none
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
