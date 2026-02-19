#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================
# Terraform Backend on Azure (didáctico)
# Crea: RG + Storage Account + Container + Versioning + Soft delete
# (Opcional) Asigna RBAC Data Plane al SP de GitHub Actions (OIDC)
# ==========================

# ---- Defaults (override via env or flags) ----
LOCATION="${LOCATION:-spaincentral}"
RESOURCE_GROUP="${RESOURCE_GROUP:-ems-tfstate-rg}"
NAME_BASE="${NAME_BASE:-emstfstate}"   # lowercase/numbers
CONTAINER="${CONTAINER:-tfstate}"
DELETE_RETENTION_DAYS="${DELETE_RETENTION_DAYS:-7}"

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"   # opcional
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}"   # opcional (clientId de la App OIDC)

# Para ayudar a “recordar” la App del Paso 2 (opcional)
OWNER="${OWNER:-}"
REPO="${REPO:-}"
APP_NAME="${APP_NAME:-}"                # opcional, display-name de la App (ej: ems-<OWNER>-gha-oidc)

AUTO_ASSIGN_RBAC=1  # por defecto sí intentamos asignar Storage Blob Data Contributor

log()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*"; exit 1; }

usage() {
  cat <<EOF
Usage:
  $0 [options]

Options:
  --location <azure-region>              Default: ${LOCATION}
  --resource-group|--rg <name>           Default: ${RESOURCE_GROUP}
  --name-base <sa-name-prefix>           Default: ${NAME_BASE}
  --container <blob-container-name>      Default: ${CONTAINER}
  --delete-retention-days <n>            Default: ${DELETE_RETENTION_DAYS}
  --subscription-id <id>                 Optional: set active subscription
  --azure-client-id <guid>               Optional: OIDC App clientId (AZURE_CLIENT_ID)
  --owner <github-owner>                 Optional: ayuda a resolver APP_NAME del paso 2
  --repo <github-repo>                   Optional: ayuda a resolver APP_NAME del paso 2
  --app-name <display-name>              Optional: nombre App Registration (ej: ems-\$OWNER-gha-oidc)
  --skip-rbac                             No asigna Storage Blob Data Contributor
  -h, --help                             Show help

Ejemplos:
  $0
  AZURE_CLIENT_ID=<guid> $0
  OWNER=miorg REPO=mirepo $0
  APP_NAME="ems-miorg-gha-oidc" $0
EOF
}

prompt() {
  local var="$1" msg="$2" def="${3:-}" cur="${!var:-}"
  [[ -n "$cur" ]] && return 0
  while true; do
    if [[ -n "$def" ]]; then
      read -r -p "${msg} [${def}]: " cur || true
      cur="${cur:-$def}"
    else
      read -r -p "${msg}: " cur || true
    fi
    cur="$(printf '%s' "$cur" | xargs || true)"
    [[ -n "$cur" ]] || { warn "No puede estar vacío."; continue; }
    printf -v "$var" '%s' "$cur"
    return 0
  done
}

# ---- Flags parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)                LOCATION="$2"; shift 2 ;;
    --resource-group|--rg)     RESOURCE_GROUP="$2"; shift 2 ;;
    --name-base)               NAME_BASE="$2"; shift 2 ;;
    --container)               CONTAINER="$2"; shift 2 ;;
    --delete-retention-days)   DELETE_RETENTION_DAYS="$2"; shift 2 ;;
    --subscription-id)         SUBSCRIPTION_ID="$2"; shift 2 ;;
    --azure-client-id)         AZURE_CLIENT_ID="$2"; shift 2 ;;
    --owner)                   OWNER="$2"; shift 2 ;;
    --repo)                    REPO="$2"; shift 2 ;;
    --app-name)                APP_NAME="$2"; shift 2 ;;
    --skip-rbac)               AUTO_ASSIGN_RBAC=0; shift ;;
    -h|--help)                 usage; exit 0 ;;
    *) err "Unknown option: $1 (use --help)" ;;
  esac
done

# ---- Pre-flight checks ----
command -v az >/dev/null 2>&1 || err "Azure CLI no encontrado."

log "Checking Azure CLI login..."
if ! az account show >/dev/null 2>&1; then
  warn "No estás logueado. Ejecutando 'az login'..."
  az login --use-device-code >/dev/null
fi

if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  log "Setting subscription: ${SUBSCRIPTION_ID}"
  az account set --subscription "${SUBSCRIPTION_ID}"
fi

SUB_DISPLAY_NAME=$(az account show --query name -o tsv)
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
SCOPE="/subscriptions/${SUB_ID}"
log "Active subscription: ${SUB_DISPLAY_NAME} (${SUB_ID})"
log "Tenant: ${TENANT_ID}"
log "Location: ${LOCATION}"

# Validate name-base constraints (lowercase/numbers)
if [[ ! "${NAME_BASE}" =~ ^[a-z0-9]+$ ]]; then
  err "--name-base must contain only lowercase letters and numbers."
fi

# ---- Resolve AZURE_CLIENT_ID if missing (didáctico) ----
# Si el alumno no lo introduce, intentamos deducirlo por APP_NAME (si lo dan) o por OWNER/REPO (default del paso 2)
if [[ -z "${AZURE_CLIENT_ID}" ]]; then
  # Pedimos OWNER/REPO solo si queremos ayudar a resolver APP_NAME
  if [[ -z "${APP_NAME}" ]]; then
    # No obligamos, pero es útil para el lab
    read -r -p "GitHub OWNER (opcional, para localizar la App del Paso 2) [enter para omitir]: " OWNER || true
    OWNER="$(printf '%s' "$OWNER" | xargs || true)"
    read -r -p "GitHub REPO  (opcional, para mostrar el repo) [enter para omitir]: " REPO || true
    REPO="$(printf '%s' "$REPO" | xargs || true)"

    if [[ -n "${OWNER}" ]]; then
      APP_NAME="ems-${OWNER}-gha-oidc"
      log "Asumiendo APP_NAME por defecto del lab: ${APP_NAME}"
    fi
  fi

  if [[ -n "${APP_NAME}" ]]; then
    # Intento de auto-resolución por display-name
    count="$(az ad app list --display-name "${APP_NAME}" --query "length(@)" -o tsv 2>/dev/null || echo 0)"
    if [[ "${count}" == "1" ]]; then
      AZURE_CLIENT_ID="$(az ad app list --display-name "${APP_NAME}" --query "[0].appId" -o tsv)"
      log "He resuelto AZURE_CLIENT_ID desde APP_NAME='${APP_NAME}': ${AZURE_CLIENT_ID}"
    elif [[ "${count}" != "0" ]]; then
      warn "Hay ${count} apps con el nombre '${APP_NAME}'. No puedo elegir automáticamente."
      az ad app list --display-name "${APP_NAME}" --query "[].{displayName:displayName, appId:appId, objectId:id}" -o table
    fi
  fi
fi

# Si aún no hay AZURE_CLIENT_ID, lo pedimos (solo si vamos a asignar RBAC)
if [[ "$AUTO_ASSIGN_RBAC" -eq 1 && -z "${AZURE_CLIENT_ID}" ]]; then
  read -r -p "AZURE_CLIENT_ID (App Registration clientId) para asignar RBAC [enter para saltar]: " AZURE_CLIENT_ID || true
  AZURE_CLIENT_ID="$(printf '%s' "$AZURE_CLIENT_ID" | xargs || true)"
fi

# ---- Compute unique Storage Account name (<=24 chars) ----
RAND="$(date +%s)$(shuf -i 1000-9999 -n 1)"
SA_RAW="${NAME_BASE}${RAND}"
SA="${SA_RAW:0:24}"

attempt=1
max_attempts=5
while az storage account check-name --name "${SA}" --query nameAvailable -o tsv 2>/dev/null | grep -qi "false"; do
  if (( attempt >= max_attempts )); then
    err "Could not find an available Storage Account name after ${max_attempts} attempts."
  fi
  warn "Name ${SA} is taken. Retrying..."
  RAND="$(date +%s)$(shuf -i 1000-9999 -n 1)"
  SA_RAW="${NAME_BASE}${RAND}"
  SA="${SA_RAW:0:24}"
  ((attempt++))
done

# ---- Plan (listado) ----
echo ""
log "PLAN"
echo "  Resource Group:     ${RESOURCE_GROUP}"
echo "  Storage Account:    ${SA}"
echo "  Container:          ${CONTAINER}"
echo "  Location:           ${LOCATION}"
echo "  Subscription:       ${SUB_ID}"
echo "  Tenant:             ${TENANT_ID}"
echo "  Repo (opcional):    ${OWNER:-<n/a>}/${REPO:-<n/a>}"
echo "  AZURE_CLIENT_ID:    ${AZURE_CLIENT_ID:-<skip RBAC>}"
echo ""

warn "Confirma para continuar creando el backend de Terraform."
warn "Escribe EXACTAMENTE: CREATE"
read -r -p "> " ans || true
[[ "${ans}" == "CREATE" ]] || err "Cancelado por el usuario."

# ---- Create Resource Group (idempotent) ----
log "Creating/updating Resource Group: ${RESOURCE_GROUP} in ${LOCATION}"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" >/dev/null

# ---- Create Storage Account ----
log "Creating Storage Account (StorageV2, HTTPS only, TLS1_2, no public access, no shared key auth)..."
az storage account create \
  --name "${SA}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --https-only true \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  >/dev/null

# ---- Enable blob versioning and soft delete ----
log "Enabling blob versioning and delete retention (${DELETE_RETENTION_DAYS} days)..."
az storage account blob-service-properties update \
  --account-name "${SA}" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days "${DELETE_RETENTION_DAYS}" \
  >/dev/null

log "Enabling container soft delete (${DELETE_RETENTION_DAYS} days)..."
az storage account blob-service-properties update \
  --account-name "${SA}" \
  --enable-container-delete-retention true \
  --container-delete-retention-days "${DELETE_RETENTION_DAYS}" \
  >/dev/null

# ---- Create private container for Terraform state ----
log "Creating private blob container: ${CONTAINER}"
az storage container create \
  --name "${CONTAINER}" \
  --account-name "${SA}" \
  --auth-mode login \
  >/dev/null

# ---- Assign RBAC (Data Plane) to the OIDC App (if provided) ----
if [[ "$AUTO_ASSIGN_RBAC" -eq 1 && -n "${AZURE_CLIENT_ID}" ]]; then
  log "Resolving Service Principal object id from clientId..."
  SP_OBJECT_ID=$(az ad sp show --id "${AZURE_CLIENT_ID}" --query id -o tsv 2>/dev/null || true)

  if [[ -z "${SP_OBJECT_ID}" ]]; then
    warn "No se encontró Service Principal para clientId ${AZURE_CLIENT_ID}. Saltando role assignment."
  else
    SA_ID=$(az storage account show -g "${RESOURCE_GROUP}" -n "${SA}" --query id -o tsv)
    log "Assigning role 'Storage Blob Data Contributor' on scope: ${SA_ID}"
    az role assignment create \
      --assignee-object-id "${SP_OBJECT_ID}" \
      --assignee-principal-type ServicePrincipal \
      --role "Storage Blob Data Contributor" \
      --scope "${SA_ID}" >/dev/null || true

    log "Current data-plane role assignments for the principal on the Storage Account:"
    az role assignment list \
      --assignee-object-id "${SP_OBJECT_ID}" \
      --scope "${SA_ID}" \
      --query "[].{role:roleDefinitionName, scope:scope, principalType:principalType, createdOn:createdOn}" \
      -o table
  fi
else
  log "RBAC assignment skipped (either --skip-rbac or no AZURE_CLIENT_ID)."
fi

# ---- Output values for GitHub Actions ----
echo ""
echo "=== VALORES PARA GitHub Actions (Variables/Secrets) ==="
echo "AZURE_SUBSCRIPTION_ID=${SUB_ID}"
echo "AZURE_TENANT_ID=${TENANT_ID}"
echo "AZURE_CLIENT_ID=${AZURE_CLIENT_ID:-<set-from-step-2>}"
echo "AZURE_LOCATION=${LOCATION}"
echo ""
echo "TFSTATE_RESOURCE_GROUP=${RESOURCE_GROUP}"
echo "TFSTATE_STORAGE_ACCOUNT=${SA}"
echo "TFSTATE_CONTAINER=${CONTAINER}"
echo "TFSTATE_KEY_STAGING=staging.tfstate"
echo "TFSTATE_KEY_PRODUCTION=production.tfstate"

echo ""
echo "=== Bloque backend de Terraform (ejemplo) ==="
cat <<EOF
# backend.tf
terraform {
  backend "azurerm" {
    resource_group_name  = "${RESOURCE_GROUP}"
    storage_account_name = "${SA}"
    container_name       = "${CONTAINER}"
    key                  = "staging.tfstate"  # o "production.tfstate"
    use_azuread_auth     = true  # Recomendado con OIDC
  }
}
EOF

echo ""
log "✅ Done."
