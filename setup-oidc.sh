#!/usr/bin/env bash
set -Eeuo pipefail

#############################################
# Configuración (puedes sobreescribir por env)
#############################################
# En Cloud Shell queremos pedir explícitamente OWNER/REPO si no vienen por env.
OWNER="${OWNER:-}"
REPO="${REPO:-}"

# APP_NAME se puede sobreescribir por env; en reset/destroy se preguntará con default.
APP_NAME="${APP_NAME:-}"
ROLE="${ROLE:-Contributor}"

# Contexto Azure actual (se rellena tras login)
SUBSCRIPTION_ID=""
TENANT_ID=""
SCOPE=""

# Acción (create|reset|destroy)
ACTION="create"

# IDs resueltos (según App Registration encontrada)
APP_ID=""
APP_OBJECT_ID=""
SP_OBJECT_ID=""

#############################################
# Utilidades
#############################################
log()  { printf '\n\033[1;34m[INFO]\033[0m %s\n'  "$*"; }
warn() { printf '\n\033[1;33m[WARN]\033[0m %s\n'  "$*"; }
err()  { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*"; exit 1; }

trap 'err "Fallo en la línea $LINENO. Revisa el mensaje anterior."' ERR

usage() {
  cat <<'EOF'
Uso:
  ./setup-oidc.sh --create
  ./setup-oidc.sh --reset
  ./setup-oidc.sh --destroy
  ./setup-oidc.sh -h|--help

Acciones:
  --create   Crea/reutiliza App Registration + SP, asigna RBAC y crea federated credentials (OIDC).
  --reset    Limpia OIDC + RBAC del SP, pero mantiene App/SP (ideal para repetir el lab).
  --destroy  Limpia y borra App Registration (y su SP asociado).

Variables opcionales (env):
  OWNER, REPO           GitHub owner/repo
  APP_NAME              Nombre (display-name) de la App Registration
  ROLE                  Rol de trabajo (default: Contributor)

Ejemplos:
  ./setup-oidc.sh --create
  OWNER=miorg REPO=mirepo ./setup-oidc.sh --create
  ./setup-oidc.sh --reset
  APP_NAME="ems-alumno1-gha-oidc" ./setup-oidc.sh --destroy
EOF
}

require_cmd() {
  command -v az >/dev/null 2>&1 || err "Azure CLI no encontrado."
}

require_login() {
  az account show -o none 2>/dev/null || err "No hay sesión activa en Azure CLI (ejecuta 'az login')."
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    err "Debes indicar una acción: --create | --reset | --destroy"
  fi

  local seen=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --create)  ACTION="create";  seen=$((seen+1)); shift ;;
      --reset)   ACTION="reset";   seen=$((seen+1)); shift ;;
      --destroy) ACTION="destroy"; seen=$((seen+1)); shift ;;
      -h|--help) usage; exit 0 ;;
      *) err "Argumento desconocido: $1 (usa --help)" ;;
    esac
  done

  [[ "$seen" -eq 1 ]] || err "Indica exactamente UNA acción: --create | --reset | --destroy"
}

# Pide una variable si está vacía. Mantiene compatibilidad con ejecución no interactiva vía env.
prompt_var() {
  local varname="$1"
  local prompt="$2"
  local default="${3:-}"
  local current="${!varname:-}"

  if [[ -n "${current}" ]]; then
    return 0
  fi

  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "${prompt} [${default}]: " current || true
      current="${current:-$default}"
    else
      read -r -p "${prompt}: " current || true
    fi

    current="$(printf '%s' "$current" | xargs || true)"

    if [[ -z "$current" ]]; then
      warn "El valor no puede estar vacío."
      continue
    fi
    if [[ ! "$current" =~ ^[A-Za-z0-9._-]+$ ]]; then
      warn "Formato no válido. Usa solo letras/números y . _ -"
      continue
    fi

    printf -v "$varname" '%s' "$current"
    return 0
  done
}

resolve_context() {
  SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
  TENANT_ID="$(az account show --query tenantId -o tsv)"
  SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
}

#############################################
# Resolución de App/SP para reset/destroy
#############################################
resolve_app_by_name() {
  local count
  count="$(az ad app list --display-name "$APP_NAME" --query "length(@)" -o tsv)"

  if [[ "${count:-0}" -eq 0 ]]; then
    err "No existe App Registration con display-name='$APP_NAME'."
  fi
  if [[ "${count:-0}" -gt 1 ]]; then
    warn "Hay ${count} apps con el mismo display-name='$APP_NAME'. Lista:"
    az ad app list --display-name "$APP_NAME" --query "[].{displayName:displayName, appId:appId, objectId:id}" -o table
    err "APP_NAME debe ser único. Cambia el nombre o usa uno más específico."
  fi

  APP_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
  APP_OBJECT_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].id" -o tsv)"

  [[ -n "${APP_ID:-}" ]] || err "No se pudo resolver APP_ID para '$APP_NAME'."
}

resolve_sp_by_appid() {
  SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)"
}

#############################################
# Listados + confirmación segura
#############################################
list_plan_reset_destroy() {
  echo ""
  log "PLAN (${ACTION})"
  echo "  App Registration:  $APP_NAME"
  echo "  APP_ID (clientId): ${APP_ID:-<no>}"
  echo "  App objectId:      ${APP_OBJECT_ID:-<no>}"
  echo "  SP objectId:       ${SP_OBJECT_ID:-<no>}"
  echo "  Subscription:      ${SUBSCRIPTION_ID:-<no>}"
  echo "  Scope (RBAC):      ${SCOPE:-<no>}"
  echo "  Repo GitHub:       ${OWNER:-<no>}/${REPO:-<no>}"
  echo ""

  log "Federated credentials objetivo (las del lab para este repo):"
  local n1="github-${OWNER}-${REPO}-staging"
  local n2="github-${OWNER}-${REPO}-production"
  local n3="github-${OWNER}-${REPO}-main"
  echo "  - $n1"
  echo "  - $n2"
  echo "  - $n3"
  echo ""
  log "Federated credentials actuales (filtradas por repo si existen):"
  az ad app federated-credential list --id "$APP_ID" \
    --query "[?starts_with(subject, 'repo:${OWNER}/${REPO}:')].[name,subject]" -o table 2>/dev/null || true

  echo ""
  if [[ -n "${SP_OBJECT_ID:-}" ]]; then
    log "Role assignments del SP bajo '${SCOPE}' (o descendientes):"
    az role assignment list --assignee-object-id "$SP_OBJECT_ID" --all \
      --query "[?starts_with(scope, '${SCOPE}')].[roleDefinitionName,scope]" -o table 2>/dev/null || true
  else
    warn "No se encontró Service Principal para APP_ID=$APP_ID (puede que ya esté borrado)."
  fi
  echo ""
}

confirm_or_exit() {
  local token=""
  if [[ "$ACTION" == "reset" ]]; then
    token="RESET"
    warn "Vas a limpiar OIDC + RBAC (manteniendo App/SP)."
  else
    token="DELETE"
    warn "Vas a limpiar y BORRAR la App Registration (y su SP asociado)."
  fi

  warn "Para continuar escribe exactamente: ${token}"
  local ans=""
  read -r -p "> " ans || true
  [[ "$ans" == "$token" ]] || err "Cancelado por el usuario."
}

#############################################
# Limpieza (reset/destroy)
#############################################
cleanup_federated_credentials_for_repo() {
  log "Eliminando federated credentials del lab para ${OWNER}/${REPO} (si existen)..."
  local targets=(
    "github-${OWNER}-${REPO}-staging"
    "github-${OWNER}-${REPO}-production"
    "github-${OWNER}-${REPO}-main"
  )

  # Obtener nombres existentes
  local existing
  existing="$(az ad app federated-credential list --id "$APP_ID" --query "[].name" -o tsv 2>/dev/null || true)"

  for name in "${targets[@]}"; do
    if printf '%s\n' "$existing" | grep -qx "$name"; then
      log " - borrando federated credential: $name"
      az ad app federated-credential delete --id "$APP_ID" --federated-credential-id "$name" >/dev/null
    else
      log " - no existe (omitido): $name"
    fi
  done
}

cleanup_role_assignments_under_scope() {
  [[ -z "${SP_OBJECT_ID:-}" ]] && { warn "Sin SP, no hay role assignments que limpiar."; return 0; }

  log "Eliminando role assignments del SP bajo '${SCOPE}' (si existen)..."
  local ids
  ids="$(az role assignment list --assignee-object-id "$SP_OBJECT_ID" --all \
          --query "[?starts_with(scope, '${SCOPE}')].id" -o tsv 2>/dev/null || true)"

  if [[ -z "${ids:-}" ]]; then
    log "No hay role assignments que borrar en el scope indicado."
    return 0
  fi

  while IFS= read -r rid; do
    [[ -z "$rid" ]] && continue
    log " - borrando role assignment: $rid"
    az role assignment delete --ids "$rid" >/dev/null 2>&1 || true
  done <<< "$ids"
}

do_reset() {
  echo ""
  log "RESET: necesito los datos del repo GitHub y la App Registration a limpiar."
  prompt_var OWNER "GitHub OWNER (tu usuario u organización)"
  prompt_var REPO  "GitHub REPO (nombre del repositorio)"

  local default_app="ems-${OWNER}-gha-oidc"
  prompt_var APP_NAME "Nombre de la App Registration (display-name)" "$default_app"

  resolve_app_by_name
  resolve_sp_by_appid

  list_plan_reset_destroy
  confirm_or_exit

  cleanup_federated_credentials_for_repo
  cleanup_role_assignments_under_scope

  echo ""
  log "RESET completado ✅ (App/SP mantenidos)"
}

do_destroy() {
  echo ""
  log "DESTROY: necesito los datos del repo GitHub y la App Registration a borrar."
  prompt_var OWNER "GitHub OWNER (tu usuario u organización)"
  prompt_var REPO  "GitHub REPO (nombre del repositorio)"

  local default_app="ems-${OWNER}-gha-oidc"
  prompt_var APP_NAME "Nombre de la App Registration (display-name)" "$default_app"

  resolve_app_by_name
  resolve_sp_by_appid

  list_plan_reset_destroy
  confirm_or_exit

  cleanup_federated_credentials_for_repo
  cleanup_role_assignments_under_scope

  # Intentar borrar SP primero (si existe), luego App
  if [[ -n "${SP_OBJECT_ID:-}" ]]; then
    log "Borrando Service Principal (si existe)..."
    az ad sp delete --id "$APP_ID" >/dev/null 2>&1 || true
  fi

  log "Borrando App Registration..."
  az ad app delete --id "$APP_ID" >/dev/null

  echo ""
  log "DESTROY completado ✅ (App/SP borrados)"
}

#############################################
# Funciones idempotentes (create)
#############################################
ensure_app() {
  log "Creando/obteniendo App Registration: $APP_NAME"

  local app_id
  app_id="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
  if [[ -z "${app_id:-}" ]]; then
    app_id="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
    if [[ -z "${app_id:-}" ]]; then
      app_id="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
    fi
  fi
  [[ -n "${app_id:-}" ]] || err "No se pudo obtener APP_ID para '$APP_NAME'."

  APP_ID="$app_id"
  log "APP_ID (client-id): $APP_ID"
}

ensure_sp() {
  log "Creando/obteniendo Service Principal de la app..."

  local sp_id
  sp_id="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)"

  if [[ -z "${sp_id:-}" ]]; then
    local backoff=3
    for i in {1..10}; do
      if sp_id="$(az ad sp create --id "$APP_ID" --query id -o tsv 2>/dev/null)"; then
        break
      fi
      warn "Esperando propagación en Entra ID... (intento $i/10). Reintentando en ${backoff}s"
      sleep "$backoff"
      backoff=$(( backoff < 30 ? backoff*2 : 30 ))
    done
  fi

  [[ -n "${sp_id:-}" ]] || err "No se pudo crear/obtener el Service Principal (APP_ID=$APP_ID)."

  SP_OBJECT_ID="$sp_id"
  log "SP_OBJECT_ID: $SP_OBJECT_ID"
}

ensure_fc() {
  local name="$1" subject="$2" description="$3"

  local exists
  exists="$(az ad app federated-credential list --id "$APP_ID" \
            --query "[?name=='${name}'] | length(@)" -o tsv)"
  if [[ "${exists:-0}" -gt 0 ]]; then
    log "Federated Credential ya existe: $name (omitido)"
    return 0
  fi

  log "Creando Federated Credential: $name"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
{
  "name": "${name}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "${subject}",
  "description": "${description}",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
  az ad app federated-credential create --id "$APP_ID" --parameters "$tmp" >/dev/null
  rm -f "$tmp"
}

ensure_role_assignment() {
  local role="$1" scope="$2"

  local count
  count="$(az role assignment list \
    --assignee-object-id "$SP_OBJECT_ID" \
    --scope "$scope" \
    --query "[?roleDefinitionName=='${role}'] | length(@)" -o tsv)"

  if [[ "${count:-0}" -gt 0 ]]; then
    log "Rol '${role}' ya asignado en scope ${scope} (omitido)"
    return 0
  fi

  log "Asignando rol '${role}' en scope: ${scope}"
  local backoff=3 ok=0
  for i in {1..10}; do
    if az role assignment create \
        --assignee-object-id "$SP_OBJECT_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "$role" \
        --scope "$scope" >/dev/null 2>&1; then
      ok=1; break
    fi
    warn "Reintentando role assignment... (intento $i/10). Espera ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff < 30 ? backoff*2 : 30 ))
  done
  [[ "$ok" -eq 1 ]] || err "No se pudo asignar el rol '${role}' en '${scope}'."
}

do_create() {
  echo ""
  log "CREATE (Paso 2 OIDC): necesito los datos del repo GitHub del alumno."
  prompt_var OWNER "GitHub OWNER (tu usuario u organización)"
  prompt_var REPO  "GitHub REPO (nombre del repositorio)"

  # APP_NAME por defecto si no viene por env
  APP_NAME="${APP_NAME:-ems-${OWNER}-gha-oidc}"

  log "Usando suscripción: $SUBSCRIPTION_ID"
  log "Tenant: $TENANT_ID"
  log "Scope del rol: $SCOPE"
  log "Repo GitHub: ${OWNER}/${REPO}"
  log "App Registration: $APP_NAME"

  ensure_app
  ensure_sp

  ensure_role_assignment "User Access Administrator" "$SCOPE"

  ensure_fc "github-${OWNER}-${REPO}-staging" \
    "repo:${OWNER}/${REPO}:environment:staging" \
    "OIDC GitHub Actions -> Azure para el environment staging"

  ensure_fc "github-${OWNER}-${REPO}-production" \
    "repo:${OWNER}/${REPO}:environment:production" \
    "OIDC GitHub Actions -> Azure para el environment production"

  ensure_fc "github-${OWNER}-${REPO}-main" \
    "repo:${OWNER}/${REPO}:ref:refs/heads/main" \
    "OIDC GitHub Actions -> Azure para pushes a main (sin environment)"

  ensure_role_assignment "$ROLE" "$SCOPE"

  echo ""
  echo "========================="
  echo "LISTO ✅"
  echo "Configura estas variables en GitHub (Settings -> Secrets and variables -> Actions -> Variables):"
  echo "AZURE_CLIENT_ID=$APP_ID"
  echo "AZURE_TENANT_ID=$TENANT_ID"
  echo "AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
  echo "========================="
  echo ""
  echo "IMPORTANTE:"
  echo "1) Crea los Environments en GitHub: staging y production."
  echo "2) En tu workflow usa: environment: staging / environment: production."
}

#############################################
# Main
#############################################
parse_args "$@"
require_cmd
require_login
resolve_context

case "$ACTION" in
  create)  do_create ;;
  reset)   do_reset ;;
  destroy) do_destroy ;;
  *) err "Acción no soportada: $ACTION" ;;
esac
