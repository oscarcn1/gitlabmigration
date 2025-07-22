#!/bin/bash

# Script de migración completa de GitLab
# Migra usuarios, grupos, proyectos y repositorios entre servidores GitLab
# Autor: Sistema automatizado
# Fecha: 2025

set -euo pipefail

# Colores para salida
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # Sin color

# Variables globales
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_DIR="${SCRIPT_DIR}/gitlab_migration_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${EXPORT_DIR}/importacion-$(date +%Y%m%d_%H%M%S).log"
USERS_FILE="${EXPORT_DIR}/users.json"
GROUPS_FILE="${EXPORT_DIR}/groups.json"
PROJECTS_FILE="${EXPORT_DIR}/projects.json"

# Función para mostrar uso
usage() {
    cat << EOF
Uso: $0 -s IP_ORIGEN -t TOKEN_ORIGEN -d IP_DESTINO -T TOKEN_DESTINO [-h] [-v]

Opciones:
    -s  IP del servidor GitLab origen (ej: 10.0.0.1)
    -t  Token de API del servidor origen
    -d  IP del servidor GitLab destino (ej: 10.0.0.2)
    -T  Token de API del servidor destino
    -h  Mostrar esta ayuda
    -v  Modo verbose (mostrar más detalles)
    -p  Protocolo a usar (http/https, default: http)

Ejemplo:
    $0 -s 10.0.0.1 -t glpat-xxxxx -d 10.0.0.2 -T glpat-yyyyy

EOF
    exit 1
}

# Función para registrar mensajes
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
    
    case ${level} in
        ERROR)
            echo -e "${RED}[ERROR] ${message}${NC}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS] ${message}${NC}"
            ;;
        WARNING)
            echo -e "${YELLOW}[WARNING] ${message}${NC}"
            ;;
    esac
}

# Función para realizar llamadas a la API con reintentos
api_call() {
    local server=$1
    local token=$2
    local endpoint=$3
    local method=${4:-GET}
    local data=${5:-}
    local output_file=${6:-}
    local max_retries=${7:-3}
    
    local url="${PROTOCOL}://${server}/api/v4/${endpoint}"
    local curl_opts=(-s --header "PRIVATE-TOKEN: ${token}")
    
    if [[ ${method} != "GET" ]]; then
        curl_opts+=(--request "${method}")
    fi
    
    if [[ -n ${data} ]]; then
        curl_opts+=(--header "Content-Type: application/json" --data "${data}")
    fi
    
    if [[ -n ${output_file} ]]; then
        curl_opts+=(--output "${output_file}")
    fi
    
    local attempt=1
    local wait_time=1
    
    while [[ ${attempt} -le ${max_retries} ]]; do
        if [[ ${VERBOSE} -eq 1 ]]; then
            if [[ ${attempt} -eq 1 ]]; then
                log "DEBUG" "API Call: ${method} ${url}" >&2
            else
                log "DEBUG" "API Call (intento ${attempt}/${max_retries}): ${method} ${url}" >&2
            fi
        fi
        
        # Realizar llamada y capturar código HTTP
        local response
        local http_code
        
        if [[ -n ${output_file} ]]; then
            http_code=$(curl -w '%{http_code}' -o "${output_file}" "${curl_opts[@]}" "${url}")
            response="Saved to ${output_file}"
        else
            response=$(curl -w '\n__HTTP_CODE__:%{http_code}' "${curl_opts[@]}" "${url}")
            http_code=$(echo "${response}" | grep -o '__HTTP_CODE__:[0-9]*' | cut -d: -f2)
            response=$(echo "${response}" | sed '/__HTTP_CODE__:/d')
        fi
        
        # Verificar código HTTP
        if [[ ${http_code} -ge 200 ]] && [[ ${http_code} -lt 300 ]]; then
            if [[ -z ${output_file} ]]; then
                echo "${response}"
            fi
            return 0
        elif [[ ${http_code} -eq 429 ]]; then
            # Rate limiting - reintentar con backoff exponencial
            if [[ ${attempt} -lt ${max_retries} ]]; then
                log "WARNING" "Rate limit alcanzado (HTTP 429). Esperando ${wait_time}s antes del reintento ${attempt}/${max_retries}..." >&2
                sleep ${wait_time}
                wait_time=$((wait_time * 2))  # Backoff exponencial
                ((attempt++))
                continue
            else
                log "ERROR" "Rate limit alcanzado. Máximo de reintentos agotado para: ${method} ${url}" >&2
                if [[ ${VERBOSE} -eq 1 ]] && [[ -n ${response} ]]; then
                    log "DEBUG" "Respuesta: ${response}" >&2
                fi
                return 1
            fi
        elif [[ ${http_code} -eq 502 ]] || [[ ${http_code} -eq 503 ]] || [[ ${http_code} -eq 504 ]]; then
            # Errores de servidor - reintentar
            if [[ ${attempt} -lt ${max_retries} ]]; then
                log "WARNING" "Error de servidor (HTTP ${http_code}). Reintentando en ${wait_time}s (${attempt}/${max_retries})..." >&2
                sleep ${wait_time}
                wait_time=$((wait_time * 2))
                ((attempt++))
                continue
            else
                log "ERROR" "Error de servidor persistente (HTTP ${http_code}). Máximo de reintentos agotado para: ${method} ${url}" >&2
                return 1
            fi
        else
            # Otros errores - no reintentar
            log "ERROR" "API devolvió código HTTP ${http_code} para: ${method} ${url}" >&2
            if [[ ${VERBOSE} -eq 1 ]] && [[ -n ${response} ]]; then
                log "DEBUG" "Respuesta: ${response}" >&2
            fi
            return 1
        fi
    done
    
    return 1
}

# Función para obtener todos los elementos paginados
get_all_paginated() {
    local server=$1
    local token=$2
    local endpoint=$3
    local output_file=$4
    
    local page=1
    local per_page=100
    local all_items='[]'
    local temp_file="${output_file}.tmp"
    
    log "INFO" "Obteniendo datos paginados de ${endpoint}..."
    
    while true; do
        local response=$(api_call "${server}" "${token}" "${endpoint}?page=${page}&per_page=${per_page}")
        
        # Verificar si la respuesta está vacía o hay error
        if [[ -z ${response} ]]; then
            if [[ ${page} -eq 1 ]]; then
                log "ERROR" "No se pudo obtener datos de ${endpoint}"
                echo "[]" > "${output_file}"
                return 1
            fi
            break
        fi
        
        # Verificar si es JSON válido
        if ! echo "${response}" | jq empty 2>/dev/null; then
            log "ERROR" "Respuesta no es JSON válido para ${endpoint} página ${page}"
            if [[ ${VERBOSE} -eq 1 ]]; then
                log "DEBUG" "Respuesta recibida: ${response:0:200}..."
            fi
            if [[ ${page} -eq 1 ]]; then
                echo "[]" > "${output_file}"
                return 1
            fi
            break
        fi
        
        # Si es array vacío, terminar
        if [[ ${response} == "[]" ]]; then
            break
        fi
        
        # Guardar respuesta temporal
        echo "${response}" > "${temp_file}"
        
        # Combinar arrays usando jq
        if ! all_items=$(echo "${all_items}" | jq -s --slurpfile new "${temp_file}" '.[0] + $new[0]' 2>/dev/null); then
            log "ERROR" "Error al combinar resultados de página ${page}"
            rm -f "${temp_file}"
            echo "${all_items}" > "${output_file}"
            return 1
        fi
        
        if [[ ${VERBOSE} -eq 1 ]]; then
            log "DEBUG" "Procesada página ${page} de ${endpoint}"
        fi
        
        # Pequeña pausa entre páginas para evitar rate limiting
        if [[ ${page} -gt 1 ]]; then
            sleep 1
        fi
        
        ((page++))
    done
    
    rm -f "${temp_file}"
    echo "${all_items}" > "${output_file}"
    
    # Validar JSON final
    if ! jq empty "${output_file}" 2>/dev/null; then
        log "ERROR" "JSON final inválido en ${output_file}"
        return 1
    fi
    
    local count=$(jq 'length' "${output_file}")
    log "INFO" "Obtenidos ${count} elementos de ${endpoint}"
}

# Función para exportar usuarios
export_users() {
    log "INFO" "Exportando usuarios del servidor origen..."
    
    if ! get_all_paginated "${SOURCE_IP}" "${SOURCE_TOKEN}" "users" "${USERS_FILE}"; then
        log "ERROR" "Fallo al exportar usuarios"
        return 1
    fi
    
    local user_count=$(jq 'length' "${USERS_FILE}")
    log "SUCCESS" "Exportados ${user_count} usuarios"
    return 0
}

# Función para importar usuarios
import_users() {
    log "INFO" "Importando usuarios al servidor destino..."
    
    local imported=0
    local failed=0
    local skipped=0
    local total=0
    
    # Obtener usuarios existentes en destino
    local existing_users_file="${EXPORT_DIR}/existing_users.json"
    if ! get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "users" "${existing_users_file}"; then
        log "ERROR" "No se pudo obtener lista de usuarios existentes en destino"
        return 1
    fi
    
    # Obtener total de usuarios para mostrar progreso
    local total_users=$(jq 'length' "${USERS_FILE}")
    log "INFO" "Procesando ${total_users} usuarios del servidor origen..."
    
    # Procesar cada usuario del origen
    while IFS= read -r user; do
        ((total++))
        
        # Mostrar progreso cada 10 usuarios
        if [[ $((total % 10)) -eq 0 ]] || [[ ${total} -eq ${total_users} ]]; then
            log "INFO" "Progreso: ${total}/${total_users} usuarios procesados"
        fi
        
        # Validar que el JSON del usuario sea válido
        if ! echo "${user}" | jq empty 2>/dev/null; then
            log "WARNING" "Usuario ${total} tiene formato JSON inválido, saltando..."
            ((skipped++))
            continue
        fi
        
        local username=$(echo "${user}" | jq -r '.username // ""')
        local email=$(echo "${user}" | jq -r '.email // ""')
        local name=$(echo "${user}" | jq -r '.name // ""')
        local is_admin=$(echo "${user}" | jq -r '.is_admin // false')
        
        # Validar campos requeridos
        if [[ -z ${username} ]] || [[ ${username} == "null" ]]; then
            log "WARNING" "Usuario ${total} no tiene username válido, saltando..."
            ((skipped++))
            continue
        fi
        
        if [[ -z ${email} ]] || [[ ${email} == "null" ]]; then
            log "WARNING" "Usuario ${username} no tiene email válido, saltando..."
            ((skipped++))
            continue
        fi
        
        # Saltar usuarios del sistema
        if [[ ${username} == "root" ]] || [[ ${username} == "ghost" ]] || [[ ${username} == "support-bot" ]]; then
            if [[ ${VERBOSE} -eq 1 ]]; then
                log "INFO" "Saltando usuario del sistema: ${username}"
            fi
            ((skipped++))
            continue
        fi
        
        # Verificar si el usuario ya existe (por username O email)
        local exists_username=$(jq --arg username "${username}" 'any(.[]; .username == $username)' "${existing_users_file}")
        local exists_email=$(jq --arg email "${email}" 'any(.[]; .email == $email)' "${existing_users_file}")
        
        if [[ ${exists_username} == "true" ]]; then
            if [[ ${VERBOSE} -eq 1 ]]; then
                log "INFO" "Usuario ${username} ya existe (mismo username), saltando..."
            fi
            ((skipped++))
            continue
        fi
        
        if [[ ${exists_email} == "true" ]]; then
            if [[ ${VERBOSE} -eq 1 ]]; then
                log "INFO" "Usuario ${username} ya existe (mismo email: ${email}), saltando..."
            fi
            ((skipped++))
            continue
        fi
        
        # Preparar datos del usuario
        local user_data=$(jq -n \
            --arg email "${email}" \
            --arg username "${username}" \
            --arg name "${name}" \
            --arg password "TempPass123!" \
            --argjson admin "${is_admin}" \
            '{
                email: $email,
                username: $username,
                name: $name,
                password: $password,
                admin: $admin,
                skip_confirmation: true,
                force_random_password: false,
                reset_password: true
            }')
        
        # Intentar crear el usuario
        log "INFO" "Creando usuario: ${username} (${email})"
        # Pausa para evitar rate limiting en creación de usuarios
        sleep 1
        local create_response=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "users" "POST" "${user_data}" "" "" 4 2>&1)
        
        if [[ $? -eq 0 ]]; then
            ((imported++))
            log "SUCCESS" "Usuario ${username} importado correctamente"
            
            # Actualizar lista de usuarios existentes para futuras verificaciones
            get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "users" "${existing_users_file}" >/dev/null 2>&1
        else
            # Verificar si el error es porque el usuario ya existe
            if echo "${create_response}" | grep -qi "already.*taken\|already.*exists\|has already been taken"; then
                log "INFO" "Usuario ${username} ya existe en destino (detectado por API), saltando..."
                ((skipped++))
            else
                ((failed++))
                log "ERROR" "No se pudo importar usuario ${username}"
                
                # Mostrar detalles del error
                local error_msg=""
                if echo "${create_response}" | jq -r '.message // .error // empty' 2>/dev/null | grep -q .; then
                    error_msg=$(echo "${create_response}" | jq -r '.message // .error' 2>/dev/null)
                elif echo "${create_response}" | jq -r '.errors // empty' 2>/dev/null | grep -q .; then
                    error_msg=$(echo "${create_response}" | jq -r '.errors | to_entries | .[] | "\(.key): \(.value | join(", "))"' 2>/dev/null)
                else
                    error_msg="${create_response}"
                fi
                
                log "ERROR" "Detalle: ${error_msg}"
                
                # No detener el script, continuar con el siguiente usuario
                log "INFO" "Continuando con el siguiente usuario..."
            fi
        fi
        
    done < <(jq -c '.[]' "${USERS_FILE}" 2>/dev/null)
    
    log "INFO" "========== RESUMEN DE IMPORTACIÓN DE USUARIOS =========="
    log "INFO" "Total usuarios en origen: $(jq 'length' "${USERS_FILE}")"
    log "INFO" "Total usuarios procesados: ${total}"
    log "INFO" "Usuarios importados exitosamente: ${imported}"
    log "INFO" "Usuarios saltados (ya existían o del sistema): ${skipped}"
    log "INFO" "Usuarios fallidos: ${failed}"
    log "INFO" "Usuarios en destino antes: $(jq 'length' "${existing_users_file}")"
    
    # Verificar usuarios actuales en destino después de importación
    local final_users_file="${EXPORT_DIR}/final_users.json"
    get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "users" "${final_users_file}" >/dev/null 2>&1
    log "INFO" "Usuarios en destino después: $(jq 'length' "${final_users_file}")"
    log "INFO" "========================================================"
    
    if [[ ${failed} -gt 0 ]] && [[ ${imported} -eq 0 ]]; then
        log "WARNING" "No se pudo importar ningún usuario. Revise los permisos del token."
        return 1
    fi
    
    return 0
}

# Función para exportar grupos
export_groups() {
    log "INFO" "Exportando grupos del servidor origen..."
    
    if ! get_all_paginated "${SOURCE_IP}" "${SOURCE_TOKEN}" "groups" "${GROUPS_FILE}"; then
        log "ERROR" "Fallo al exportar grupos"
        return 1
    fi
    
    local group_count=$(jq 'length' "${GROUPS_FILE}")
    log "SUCCESS" "Exportados ${group_count} grupos"
    return 0
}

# Función para importar grupos
import_groups() {
    log "INFO" "Importando grupos al servidor destino..."
    
    local imported=0
    local failed=0
    
    # Ordenar grupos por nivel de anidación (grupos padre primero)
    local sorted_groups=$(jq 'sort_by(.full_path | split("/") | length)' "${GROUPS_FILE}")
    
    # Obtener grupos existentes en destino
    local existing_groups_file="${EXPORT_DIR}/existing_groups.json"
    get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "groups" "${existing_groups_file}"
    
    echo "${sorted_groups}" | jq -c '.[]' | while IFS= read -r group; do
        local name=$(echo "${group}" | jq -r '.name')
        local path=$(echo "${group}" | jq -r '.path')
        local full_path=$(echo "${group}" | jq -r '.full_path')
        local description=$(echo "${group}" | jq -r '.description // ""')
        local visibility=$(echo "${group}" | jq -r '.visibility')
        local parent_id=$(echo "${group}" | jq -r '.parent_id // ""')
        
        # Verificar si el grupo ya existe
        local exists=$(jq --arg path "${full_path}" 'any(.[]; .full_path == $path)' "${existing_groups_file}")
        if [[ ${exists} == "true" ]]; then
            log "INFO" "Grupo ${full_path} ya existe, saltando..."
            continue
        fi
        
        # Validar campos requeridos
        if [[ -z ${name} ]] || [[ ${name} == "null" ]] || [[ -z ${path} ]] || [[ ${path} == "null" ]]; then
            log "WARNING" "Grupo con datos inválidos (name: '${name}', path: '${path}'), saltando..."
            continue
        fi
        
        # Si tiene grupo padre, buscar el ID del padre en el destino
        local dest_parent_id=""
        if [[ -n ${parent_id} ]] && [[ ${parent_id} != "null" ]]; then
            local parent_path=$(echo "${sorted_groups}" | jq -r --argjson id "${parent_id}" '.[] | select(.id == $id) | .full_path')
            dest_parent_id=$(jq -r --arg path "${parent_path}" '.[] | select(.full_path == $path) | .id // ""' "${existing_groups_file}")
        fi
        
        local group_data
        if [[ -n ${dest_parent_id} ]]; then
            group_data=$(jq -n \
                --arg name "${name}" \
                --arg path "${path}" \
                --arg description "${description}" \
                --arg visibility "${visibility}" \
                --argjson parent_id "${dest_parent_id}" \
                '{
                    name: $name,
                    path: $path,
                    description: $description,
                    visibility: $visibility,
                    parent_id: $parent_id
                }')
        else
            group_data=$(jq -n \
                --arg name "${name}" \
                --arg path "${path}" \
                --arg description "${description}" \
                --arg visibility "${visibility}" \
                '{
                    name: $name,
                    path: $path,
                    description: $description,
                    visibility: $visibility
                }')
        fi
        
        log "INFO" "Creando grupo: ${full_path}"
        # Pausa para evitar rate limiting en creación de grupos
        sleep 1
        local create_response=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "groups" "POST" "${group_data}" "" "" 4 2>&1)
        
        if [[ $? -eq 0 ]]; then
            ((imported++))
            log "SUCCESS" "Grupo ${full_path} importado"
            # Actualizar lista de grupos existentes
            get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "groups" "${existing_groups_file}" >/dev/null 2>&1
        else
            # Verificar si el error es porque el grupo ya existe
            if echo "${create_response}" | grep -qi "already.*taken\|already.*exists\|has already been taken"; then
                log "INFO" "Grupo ${full_path} ya existe en destino (detectado por API), continuando..."
                # Actualizar lista de grupos existentes
                get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "groups" "${existing_groups_file}" >/dev/null 2>&1
            else
                ((failed++))
                log "ERROR" "No se pudo importar grupo ${full_path}"
                
                # Mostrar detalles del error
                local error_msg=""
                if echo "${create_response}" | jq -r '.message // .error // empty' 2>/dev/null | grep -q .; then
                    error_msg=$(echo "${create_response}" | jq -r '.message // .error' 2>/dev/null)
                elif echo "${create_response}" | jq -r '.errors // empty' 2>/dev/null | grep -q .; then
                    error_msg=$(echo "${create_response}" | jq -r '.errors | to_entries | .[] | "\(.key): \(.value | join(", "))"' 2>/dev/null)
                else
                    error_msg="${create_response}"
                fi
                
                log "ERROR" "Detalle: ${error_msg}"
                log "INFO" "Continuando con el siguiente grupo..."
            fi
        fi
        
    done
    
    log "INFO" "Grupos importados: ${imported}, fallidos: ${failed}"
    return 0
}

# Función para migrar miembros de grupos
migrate_group_members() {
    log "INFO" "Migrando miembros de grupos..."
    
    local migrated=0
    local failed=0
    
    # Obtener mapeo de usuarios entre origen y destino
    local user_mapping="${EXPORT_DIR}/user_mapping.json"
    echo "{}" > "${user_mapping}"
    
    # Crear mapeo de usuarios
    jq -c '.[]' "${USERS_FILE}" | while IFS= read -r user; do
        local username=$(echo "${user}" | jq -r '.username')
        local source_id=$(echo "${user}" | jq -r '.id')
        
        # Obtener ID del usuario en destino
        local dest_user=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "users?username=${username}" | jq '.[0]')
        if [[ ${dest_user} != "null" ]]; then
            local dest_id=$(echo "${dest_user}" | jq -r '.id')
            jq --arg src "${source_id}" --arg dst "${dest_id}" \
                '. + {($src): $dst}' "${user_mapping}" > "${user_mapping}.tmp" && \
                mv "${user_mapping}.tmp" "${user_mapping}"
        fi
    done
    
    # Migrar miembros para cada grupo
    jq -c '.[]' "${GROUPS_FILE}" | while IFS= read -r group; do
        local source_group_id=$(echo "${group}" | jq -r '.id')
        local full_path=$(echo "${group}" | jq -r '.full_path')
        
        # Obtener ID del grupo en destino
        local dest_group=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "groups?search=${full_path}" | \
            jq --arg path "${full_path}" '.[] | select(.full_path == $path)')
        
        if [[ ${dest_group} == "null" ]] || [[ -z ${dest_group} ]]; then
            log "WARNING" "No se encontró grupo ${full_path} en destino"
            continue
        fi
        
        local dest_group_id=$(echo "${dest_group}" | jq -r '.id')
        
        # Obtener miembros del grupo en origen
        local members_file="${EXPORT_DIR}/group_${source_group_id}_members.json"
        get_all_paginated "${SOURCE_IP}" "${SOURCE_TOKEN}" "groups/${source_group_id}/members" "${members_file}"
        
        # Migrar cada miembro
        jq -c '.[]' "${members_file}" | while IFS= read -r member; do
            local user_id=$(echo "${member}" | jq -r '.id')
            local access_level=$(echo "${member}" | jq -r '.access_level')
            
            # Obtener ID del usuario en destino
            local dest_user_id=$(jq -r --arg id "${user_id}" '.[$id] // ""' "${user_mapping}")
            
            if [[ -n ${dest_user_id} ]]; then
                local member_data=$(jq -n \
                    --argjson user_id "${dest_user_id}" \
                    --argjson access_level "${access_level}" \
                    '{
                        user_id: $user_id,
                        access_level: $access_level
                    }')
                
                local member_response=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "groups/${dest_group_id}/members" "POST" "${member_data}" 2>&1)
                if [[ $? -eq 0 ]]; then
                    ((migrated++))
                    if [[ ${VERBOSE} -eq 1 ]]; then
                        log "SUCCESS" "Miembro añadido al grupo ${full_path}"
                    fi
                else
                    ((failed++))
                    log "WARNING" "No se pudo añadir miembro al grupo ${full_path}"
                    if [[ ${VERBOSE} -eq 1 ]]; then
                        log "DEBUG" "Error: ${member_response}"
                    fi
                fi
            fi
        done
    done
    
    log "INFO" "Miembros de grupos migrados: ${migrated}, fallidos: ${failed}"
    return 0
}

# Función para migrar namespaces
migrate_namespaces() {
    log "INFO" "Migrando namespaces al servidor destino..."
    
    local imported=0
    local failed=0
    local skipped=0
    
    # Obtener todos los namespaces del origen
    local namespaces_file="${EXPORT_DIR}/source_namespaces.json"
    if ! get_all_paginated "${SOURCE_IP}" "${SOURCE_TOKEN}" "namespaces" "${namespaces_file}"; then
        log "ERROR" "Fallo al obtener namespaces del origen"
        return 1
    fi
    
    local namespace_count=$(jq 'length' "${namespaces_file}")
    log "INFO" "Encontrados ${namespace_count} namespaces en origen"
    
    # Obtener namespaces existentes en destino
    local existing_namespaces_file="${EXPORT_DIR}/existing_namespaces.json"
    if ! get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "namespaces" "${existing_namespaces_file}"; then
        log "ERROR" "No se pudo obtener lista de namespaces existentes en destino"
        return 1
    fi
    
    # Ordenar namespaces por nivel de anidación (namespaces padre primero)
    local sorted_namespaces=$(jq 'sort_by(.full_path | split("/") | length)' "${namespaces_file}")
    
    echo "${sorted_namespaces}" | jq -c '.[]' | while IFS= read -r namespace; do
        local id=$(echo "${namespace}" | jq -r '.id')
        local name=$(echo "${namespace}" | jq -r '.name')
        local path=$(echo "${namespace}" | jq -r '.path')
        local kind=$(echo "${namespace}" | jq -r '.kind')
        local full_path=$(echo "${namespace}" | jq -r '.full_path')
        local parent_id=$(echo "${namespace}" | jq -r '.parent_id // ""')
        
        # Verificar si el namespace ya existe
        local exists=$(jq --arg path "${full_path}" 'any(.[]; .full_path == $path)' "${existing_namespaces_file}")
        if [[ ${exists} == "true" ]]; then
            if [[ ${VERBOSE} -eq 1 ]]; then
                log "INFO" "Namespace ${full_path} ya existe, saltando..."
            fi
            ((skipped++))
            continue
        fi
        
        # Los namespaces pueden ser de tipo 'user' o 'group'
        # Los namespaces de tipo 'user' se crean automáticamente con los usuarios
        if [[ ${kind} == "user" ]]; then
            if [[ ${VERBOSE} -eq 1 ]]; then
                log "INFO" "Namespace de usuario ${full_path} se creará automáticamente con el usuario"
            fi
            ((skipped++))
            continue
        fi
        
        # Para namespaces de tipo 'group', ya deberían estar creados por import_groups
        if [[ ${kind} == "group" ]]; then
            # Verificar si el grupo correspondiente existe
            local group_exists=$(jq --arg path "${full_path}" 'any(.[]; .full_path == $path)' "${existing_namespaces_file}")
            if [[ ${group_exists} == "true" ]]; then
                if [[ ${VERBOSE} -eq 1 ]]; then
                    log "INFO" "Namespace de grupo ${full_path} ya existe"
                fi
                ((skipped++))
            else
                log "WARNING" "Namespace de grupo ${full_path} no encontrado. Debería crearse con import_groups"
                ((failed++))
            fi
            continue
        fi
        
        # Para otros tipos de namespace (proyectos, etc.)
        if [[ ${VERBOSE} -eq 1 ]]; then
            log "INFO" "Namespace ${full_path} de tipo ${kind} será manejado por la importación de proyectos"
        fi
        ((skipped++))
    done
    
    log "INFO" "========== RESUMEN DE MIGRACIÓN DE NAMESPACES =========="
    log "INFO" "Total namespaces en origen: ${namespace_count}"
    log "INFO" "Namespaces procesados: ${namespace_count}"
    log "INFO" "Namespaces que requieren acción manual: ${failed}"
    log "INFO" "Namespaces manejados automáticamente: ${skipped}"
    log "INFO" "========================================================"
    
    # Actualizar la lista de namespaces en destino para las siguientes fases
    get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "namespaces" "${existing_namespaces_file}" >/dev/null 2>&1
    
    return 0
}

# Función para migrar un proyecto individual (exportar e importar inmediatamente)
migrate_single_project() {
    local project="$1"
    local id=$(echo "${project}" | jq -r '.id')
    local name=$(echo "${project}" | jq -r '.name')
    local path=$(echo "${project}" | jq -r '.path')
    local path_with_namespace=$(echo "${project}" | jq -r '.path_with_namespace')
    local namespace_full_path=$(echo "${project}" | jq -r '.namespace.full_path // ""')
    local namespace_kind=$(echo "${project}" | jq -r '.namespace.kind // ""')
    
    log "INFO" "=== Migrando proyecto: ${name} (ID: ${id}) ==="
    
    # Archivo de exportación temporal
    local export_file="${EXPORT_DIR}/temp_${id}_${path_with_namespace//\//_}.tar.gz"
    local metadata_file="${EXPORT_DIR}/temp_${id}_metadata.json"
    
    # PASO 1: Exportar proyecto
    log "INFO" "Exportando proyecto: ${name}"
    sleep 2  # Pausa para evitar rate limiting
    
    if api_call "${SOURCE_IP}" "${SOURCE_TOKEN}" "projects/${id}/export" "POST" "" "" 5 > /dev/null; then
        # Esperar a que la exportación esté lista
        local max_attempts=60
        local attempt=0
        local export_status=""
        
        while [[ ${attempt} -lt ${max_attempts} ]]; do
            sleep 10
            export_status=$(api_call "${SOURCE_IP}" "${SOURCE_TOKEN}" "projects/${id}/export" "" "" "" 5 | jq -r '.export_status // "none"')
            
            if [[ ${export_status} == "finished" ]]; then
                # Descargar archivo exportado
                if api_call "${SOURCE_IP}" "${SOURCE_TOKEN}" "projects/${id}/export/download" "GET" "" "${export_file}" 5; then
                    log "SUCCESS" "Proyecto ${name} exportado correctamente"
                    
                    # Guardar metadatos temporales
                    echo "${project}" | jq --arg file "${export_file}" '. + {export_file: $file}' > "${metadata_file}"
                    
                    # PASO 2: Importar inmediatamente
                    if import_single_project "${metadata_file}"; then
                        log "SUCCESS" "Proyecto ${name} migrado exitosamente"
                        
                        # PASO 3: Limpiar archivos temporales
                        log "INFO" "Limpiando archivos temporales de ${name}"
                        rm -f "${export_file}" "${metadata_file}"
                        log "INFO" "Archivos temporales eliminados para ${name}"
                        
                        return 0
                    else
                        log "ERROR" "Falló la importación del proyecto ${name}"
                        rm -f "${export_file}" "${metadata_file}"
                        return 1
                    fi
                else
                    log "ERROR" "No se pudo descargar el proyecto ${name}"
                    return 1
                fi
                break
            elif [[ ${export_status} == "failed" ]]; then
                log "ERROR" "Exportación fallida para proyecto ${name}"
                return 1
            fi
            
            ((attempt++))
        done
        
        if [[ ${attempt} -ge ${max_attempts} ]]; then
            log "ERROR" "Timeout esperando exportación del proyecto ${name}"
            return 1
        fi
    else
        log "ERROR" "No se pudo iniciar exportación del proyecto ${name}"
        return 1
    fi
}

# Función para exportar y migrar proyectos uno por uno
export_and_migrate_projects() {
    log "INFO" "Obteniendo lista de proyectos..."
    
    if ! get_all_paginated "${SOURCE_IP}" "${SOURCE_TOKEN}" "projects" "${PROJECTS_FILE}"; then
        log "ERROR" "Fallo al obtener lista de proyectos"
        return 1
    fi
    
    local project_count=$(jq 'length' "${PROJECTS_FILE}")
    log "INFO" "Encontrados ${project_count} proyectos para migrar"
    
    # Validar permisos de importación antes de comenzar
    if ! validate_import_permissions; then
        log "ERROR" "Faltan permisos para importar proyectos. Abortando migración de proyectos."
        return 1
    fi
    
    # Obtener namespaces del destino una sola vez
    local namespaces_file="${EXPORT_DIR}/dest_namespaces.json"
    get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "namespaces" "${namespaces_file}"
    
    local migrated=0
    local failed=0
    local current=0
    
    while IFS= read -r project; do
        ((current++))
        log "INFO" "Progreso: ${current}/${project_count} proyectos"
        
        if migrate_single_project "${project}"; then
            ((migrated++))
        else
            ((failed++))
        fi
        
        # Pausa entre proyectos para dar respiro al sistema
        if [[ ${current} -lt ${project_count} ]]; then
            log "INFO" "Pausa de 5 segundos antes del siguiente proyecto..."
            sleep 5
        fi
        
    done < <(jq -c '.[]' "${PROJECTS_FILE}")
    
    log "INFO" "========== RESUMEN DE MIGRACIÓN DE PROYECTOS =========="
    log "INFO" "Total proyectos: ${project_count}"
    log "INFO" "Proyectos migrados exitosamente: ${migrated}"
    log "INFO" "Proyectos fallidos: ${failed}"
    log "INFO" "======================================================="
    
    return 0
}

# Función para validar permisos de importación
validate_import_permissions() {
    log "INFO" "Validando permisos de importación en servidor destino..."
    
    # Verificar si el usuario actual puede crear proyectos
    local current_user=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "user" 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z ${current_user} ]]; then
        log "ERROR" "No se puede obtener información del usuario actual"
        return 1
    fi
    
    local username=$(echo "${current_user}" | jq -r '.username // "unknown"')
    local is_admin=$(echo "${current_user}" | jq -r '.is_admin // false')
    local can_create_projects=$(echo "${current_user}" | jq -r '.can_create_project // false')
    
    log "INFO" "Usuario actual: ${username}"
    log "INFO" "Es administrador: ${is_admin}"
    log "INFO" "Puede crear proyectos: ${can_create_projects}"
    
    if [[ ${can_create_projects} != "true" ]] && [[ ${is_admin} != "true" ]]; then
        log "ERROR" "El usuario ${username} no tiene permisos para crear proyectos"
        log "ERROR" "Asegúrese de que el token tenga permisos de administrador o que el usuario pueda crear proyectos"
        return 1
    fi
    
    # Probar creación de un proyecto temporal para verificar permisos
    local test_project_name="test-import-permissions-$(date +%s)"
    local test_data=$(jq -n --arg name "${test_project_name}" --arg path "${test_project_name}" \
        '{name: $name, path: $path, visibility: "private", description: "Test project for import permissions"}')
    
    log "INFO" "Probando creación de proyecto temporal..."
    local test_response=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "projects" "POST" "${test_data}" "" "" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        # Eliminar el proyecto temporal
        local test_project_id=$(echo "${test_response}" | jq -r '.id // empty')
        if [[ -n ${test_project_id} ]]; then
            api_call "${DEST_IP}" "${DEST_TOKEN}" "projects/${test_project_id}" "DELETE" "" "" "" >/dev/null 2>&1
            log "SUCCESS" "Permisos de creación de proyectos verificados"
        fi
        return 0
    else
        log "ERROR" "No se puede crear proyectos en el servidor destino"
        log "ERROR" "Respuesta del servidor: ${test_response}"
        return 1
    fi
}

# Función para importar un proyecto individual
import_single_project() {
    local metadata_file="$1"
    
    if [[ ! -f ${metadata_file} ]]; then
        log "ERROR" "Archivo de metadatos no encontrado: ${metadata_file}"
        return 1
    fi
    
    local project_data=$(cat "${metadata_file}")
    local export_file=$(echo "${project_data}" | jq -r '.export_file')
    local name=$(echo "${project_data}" | jq -r '.name')
    local path=$(echo "${project_data}" | jq -r '.path')
    local namespace_full_path=$(echo "${project_data}" | jq -r '.namespace.full_path // ""')
    local namespace_kind=$(echo "${project_data}" | jq -r '.namespace.kind // ""')
    
    if [[ ! -f ${export_file} ]]; then
        log "ERROR" "Archivo de exportación no encontrado: ${export_file}"
        return 1
    fi
    
    # Verificar tamaño del archivo
    local file_size=$(stat -f%z "${export_file}" 2>/dev/null || stat -c%s "${export_file}" 2>/dev/null)
    log "INFO" "Importando proyecto: ${name} (tamaño: ${file_size} bytes)"
    
    # Obtener namespaces en destino
    local namespaces_file="${EXPORT_DIR}/dest_namespaces.json"
    
    # Buscar namespace en destino por full_path
    local namespace_id=""
    if [[ -n ${namespace_full_path} ]]; then
        namespace_id=$(jq -r --arg path "${namespace_full_path}" \
            '.[] | select(.full_path == $path) | .id // empty' "${namespaces_file}" 2>/dev/null)
        
        # Si no se encuentra por full_path, intentar por path
        if [[ -z ${namespace_id} ]]; then
            namespace_id=$(jq -r --arg path "${namespace_full_path}" \
                '.[] | select(.path == $path) | .id // empty' "${namespaces_file}" 2>/dev/null)
        fi
        
        if [[ -n ${namespace_id} ]]; then
            log "INFO" "Usando namespace: ${namespace_full_path} (ID: ${namespace_id})"
        fi
    fi
    
    # Si aún no se encuentra namespace, obtener el namespace del usuario actual
    if [[ -z ${namespace_id} ]]; then
        log "WARNING" "No se encontró namespace ${namespace_full_path}, obteniendo namespace del usuario actual"
        local current_user=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "user" 2>/dev/null)
        if [[ $? -eq 0 ]] && [[ -n ${current_user} ]]; then
            namespace_id=$(echo "${current_user}" | jq -r '.namespace_id // .id // empty')
            local username=$(echo "${current_user}" | jq -r '.username // "unknown"')
            if [[ -n ${namespace_id} ]] && [[ ${namespace_id} != "null" ]]; then
                log "INFO" "Usando namespace del usuario ${username} (ID: ${namespace_id})"
            else
                log "ERROR" "No se pudo obtener namespace válido para importación"
                return 1
            fi
        else
            log "ERROR" "No se pudo obtener información del usuario actual"
            return 1
        fi
    fi
    
    # Verificar si el proyecto ya existe
    local existing_project=""
    if [[ -n ${namespace_full_path} ]]; then
        existing_project=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "projects?search=${path}" 2>/dev/null | \
            jq --arg path "${path}" --arg ns "${namespace_full_path}" \
            '.[] | select(.path == $path and (.namespace.full_path == $ns or .namespace.path == $ns)) | .id // empty' 2>/dev/null)
    else
        existing_project=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "projects?search=${path}" 2>/dev/null | \
            jq --arg path "${path}" \
            '.[] | select(.path == $path) | .id // empty' 2>/dev/null)
    fi
    
    if [[ -n ${existing_project} ]] && [[ ${existing_project} != "null" ]]; then
        log "INFO" "Proyecto ${namespace_full_path}/${path} ya existe, saltando..."
        return 0
    fi
    
    # Verificar permisos en el namespace antes de importar
    log "INFO" "Verificando permisos en namespace ${namespace_id}..."
    local namespace_info=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "namespaces/${namespace_id}" 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z ${namespace_info} ]]; then
        log "ERROR" "No se puede acceder al namespace ${namespace_id} o no existe"
        return 1
    fi
    
    # Verificar si el usuario tiene permisos para crear proyectos en este namespace
    local namespace_kind=$(echo "${namespace_info}" | jq -r '.kind // "user"')
    log "INFO" "Tipo de namespace: ${namespace_kind}"
    
    # Pequeña pausa para evitar rate limiting en importación
    sleep 3
    
    # Preparar importación con mejor manejo de errores
    local import_response
    local curl_exit_code
    
    if [[ ${VERBOSE} -eq 1 ]]; then
        log "DEBUG" "Iniciando importación con curl..."
        if [[ -n ${namespace_id} ]]; then
            log "DEBUG" "curl -s --max-time 300 --request POST --header 'PRIVATE-TOKEN: [HIDDEN]' --form 'file=@${export_file}' --form 'path=${path}' --form 'namespace=${namespace_id}' '${PROTOCOL}://${DEST_IP}/api/v4/projects/import'"
        else
            log "DEBUG" "curl -s --max-time 300 --request POST --header 'PRIVATE-TOKEN: [HIDDEN]' --form 'file=@${export_file}' --form 'path=${path}' '${PROTOCOL}://${DEST_IP}/api/v4/projects/import'"
        fi
    fi
    
    # Validar que namespace_id sea válido antes de usarlo
    if [[ -n ${namespace_id} ]] && [[ ${namespace_id} != "null" ]] && [[ ${namespace_id} =~ ^[0-9]+$ ]]; then
        import_response=$(curl -s --max-time 300 -w '\n__CURL_EXIT_CODE__:%{http_code}' --request POST \
            --header "PRIVATE-TOKEN: ${DEST_TOKEN}" \
            --form "file=@${export_file}" \
            --form "path=${path}" \
            --form "namespace=${namespace_id}" \
            "${PROTOCOL}://${DEST_IP}/api/v4/projects/import")
    else
        log "ERROR" "Namespace ID inválido (${namespace_id}), no se puede proceder con la importación"
        return 1
    fi
    
    curl_exit_code=$?
    local http_code=$(echo "${import_response}" | grep -o '__CURL_EXIT_CODE__:[0-9]*' | cut -d: -f2)
    import_response=$(echo "${import_response}" | sed '/__CURL_EXIT_CODE__:/d')
    
    if [[ ${VERBOSE} -eq 1 ]]; then
        log "DEBUG" "Curl exit code: ${curl_exit_code}, HTTP code: ${http_code}"
        log "DEBUG" "Respuesta: ${import_response:0:500}"
    fi
    
    if [[ ${curl_exit_code} -eq 0 ]] && [[ -n ${import_response} ]]; then
        # Verificar código HTTP
        if [[ ${http_code} -eq 403 ]]; then
            log "ERROR" "Error 403 Forbidden al importar proyecto ${name}"
            log "ERROR" "Posibles causas:"
            log "ERROR" "  1. El token no tiene permisos para crear proyectos"
            log "ERROR" "  2. El namespace de destino no existe o no tienes acceso"
            log "ERROR" "  3. Ya existe un proyecto con el mismo nombre en otro namespace"
            log "ERROR" "  4. El servidor destino tiene restricciones de importación"
            
            # Intentar obtener más detalles del error
            if echo "${import_response}" | jq empty 2>/dev/null; then
                local error_msg=$(echo "${import_response}" | jq -r '.message // .error // "Sin mensaje de error específico"')
                log "ERROR" "Mensaje del servidor: ${error_msg}"
            else
                log "ERROR" "Respuesta del servidor: ${import_response:0:200}"
            fi
            return 1
        elif [[ ${http_code} -ge 200 ]] && [[ ${http_code} -lt 300 ]]; then
            # Éxito
            local import_status=$(echo "${import_response}" | jq -r '.import_status // "scheduled"')
            log "SUCCESS" "Proyecto ${name} importado (estado: ${import_status})"
            return 0
        else
            # Otros errores HTTP
            log "ERROR" "Error HTTP ${http_code} al importar proyecto ${name}"
            if echo "${import_response}" | jq empty 2>/dev/null; then
                local error_msg=$(echo "${import_response}" | jq -r '.message // .error // "Error desconocido"')
                log "ERROR" "Mensaje: ${error_msg}"
            else
                log "ERROR" "Respuesta: ${import_response:0:200}"
            fi
            return 1
        fi
    else
        log "ERROR" "Fallo en la llamada curl para importar proyecto ${name} (exit code: ${curl_exit_code})"
        return 1
    fi
}

# Función legacy para importar proyectos (mantenida para compatibilidad)
import_projects() {
    log "INFO" "Importando proyectos al servidor destino..."
    
    local imported=0
    local failed=0
    
    # Obtener todos los namespaces en destino (usuarios y grupos)
    local namespaces_file="${EXPORT_DIR}/dest_namespaces.json"
    get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "namespaces" "${namespaces_file}"
    
    for metadata_file in "${EXPORT_DIR}"/projects/*_metadata.json; do
        [[ -f ${metadata_file} ]] || continue
        
        if import_single_project "${metadata_file}"; then
            ((imported++))
        else
            ((failed++))
        fi
    done
    
    log "INFO" "Proyectos importados: ${imported}, fallidos: ${failed}"
    return 0
}

# Función para verificar estado de importación de proyectos
check_import_status() {
    log "INFO" "Verificando estado de proyectos importados..."
    
    # Esperar un poco para que las importaciones se procesen
    sleep 10
    
    local completed=0
    local pending=0
    local failed=0
    
    # Obtener todos los proyectos en el servidor destino
    local dest_projects_file="${EXPORT_DIR}/dest_projects_status.json"
    get_all_paginated "${DEST_IP}" "${DEST_TOKEN}" "projects" "${dest_projects_file}"
    
    # Verificar proyectos que fueron intentados importar
    # Buscar tanto archivos temporales como archivos permanentes
    for metadata_file in "${EXPORT_DIR}"/projects/*_metadata.json "${EXPORT_DIR}"/temp_*_metadata.json; do
        [[ -f ${metadata_file} ]] || continue
        
        local project_data=$(cat "${metadata_file}")
        local expected_name=$(echo "${project_data}" | jq -r '.name')
        local expected_path=$(echo "${project_data}" | jq -r '.path')
        local namespace_path=$(echo "${project_data}" | jq -r '.namespace.full_path // ""')
        
        # Buscar el proyecto en destino
        local found_project=$(jq --arg path "${expected_path}" --arg ns "${namespace_path}" \
            '.[] | select(.path == $path and (.namespace.full_path == $ns or .namespace.path == $ns))' \
            "${dest_projects_file}")
        
        if [[ -n ${found_project} ]] && [[ ${found_project} != "null" ]]; then
            local import_status=$(echo "${found_project}" | jq -r '.import_status // "finished"')
            case ${import_status} in
                "finished"|"none")
                    ((completed++))
                    log "SUCCESS" "Proyecto ${expected_name} importado correctamente"
                    ;;
                "started"|"scheduled")
                    ((pending++))
                    log "INFO" "Proyecto ${expected_name} aún en proceso de importación"
                    ;;
                "failed")
                    ((failed++))
                    log "ERROR" "Falló la importación del proyecto ${expected_name}"
                    ;;
            esac
        else
            ((failed++))
            log "WARNING" "Proyecto ${expected_name} no encontrado en destino"
        fi
    done
    
    log "INFO" "Estado final: ${completed} completados, ${pending} pendientes, ${failed} fallidos"
    
    if [[ ${pending} -gt 0 ]]; then
        log "INFO" "Algunos proyectos aún están procesándose. Puede tomar varios minutos."
        log "INFO" "Monitoree el progreso en la interfaz web de GitLab destino."
    fi
    return 0
}

# Función para limpiar archivos temporales restantes
cleanup_temp_files() {
    log "INFO" "Limpiando archivos temporales restantes..."
    
    local temp_files_found=0
    
    # Limpiar archivos .tar.gz temporales
    for temp_file in "${EXPORT_DIR}"/temp_*.tar.gz; do
        if [[ -f ${temp_file} ]]; then
            ((temp_files_found++))
            rm -f "${temp_file}"
            log "WARNING" "Eliminado archivo temporal restante: $(basename "${temp_file}")"
        fi
    done
    
    # Limpiar archivos de metadatos temporales
    for temp_file in "${EXPORT_DIR}"/temp_*_metadata.json; do
        if [[ -f ${temp_file} ]]; then
            ((temp_files_found++))
            rm -f "${temp_file}"
            log "WARNING" "Eliminado metadata temporal restante: $(basename "${temp_file}")"
        fi
    done
    
    if [[ ${temp_files_found} -eq 0 ]]; then
        log "SUCCESS" "No se encontraron archivos temporales para limpiar"
    else
        log "INFO" "Se eliminaron ${temp_files_found} archivos temporales restantes"
    fi
}

# Función para generar reporte
generate_report() {
    local report_file="${EXPORT_DIR}/migration_report.txt"
    
    cat > "${report_file}" << EOF
=================================================================
                    REPORTE DE MIGRACIÓN GITLAB
=================================================================
Fecha: $(date)
Servidor Origen: ${SOURCE_IP}
Servidor Destino: ${DEST_IP}
Directorio de exportación: ${EXPORT_DIR}

RESUMEN DE MIGRACIÓN:
-----------------------------------------------------------------
EOF
    
    if [[ -f ${USERS_FILE} ]]; then
        echo "Usuarios exportados: $(jq 'length' "${USERS_FILE}")" >> "${report_file}"
    fi
    
    if [[ -f ${GROUPS_FILE} ]]; then
        echo "Grupos exportados: $(jq 'length' "${GROUPS_FILE}")" >> "${report_file}"
    fi
    
    if [[ -f ${PROJECTS_FILE} ]]; then
        echo "Proyectos encontrados: $(jq 'length' "${PROJECTS_FILE}")" >> "${report_file}"
        # Contar proyectos migrados (archivos temporales ya eliminados)
        echo "Proyectos migrados con éxito: Los archivos temporales se eliminan tras importación exitosa" >> "${report_file}"
        echo "Archivos restantes (fallos): $(ls -1 "${EXPORT_DIR}"/temp_*.tar.gz 2>/dev/null | wc -l)" >> "${report_file}"
    fi
    
    echo -e "\nPara más detalles, revisar: ${LOG_FILE}" >> "${report_file}"
    
    log "INFO" "Reporte generado en: ${report_file}"
}

# Función principal
main() {
    # Crear directorio de exportación
    mkdir -p "${EXPORT_DIR}"
    
    # Crear archivo de log inicial
    touch "${LOG_FILE}"
    
    log "INFO" "Iniciando migración de GitLab"
    log "INFO" "Servidor origen: ${SOURCE_IP}"
    log "INFO" "Servidor destino: ${DEST_IP}"
    log "INFO" "Directorio de trabajo: ${EXPORT_DIR}"
    log "INFO" "Archivo de log: ${LOG_FILE}"
    
    # Verificar conectividad
    log "INFO" "Verificando conectividad con servidores..."
    
    # Probar servidor origen
    log "INFO" "Probando conexión con servidor origen ${SOURCE_IP}..."
    local version_response=$(api_call "${SOURCE_IP}" "${SOURCE_TOKEN}" "version")
    if [[ $? -ne 0 ]]; then
        log "ERROR" "No se puede conectar al servidor origen"
        log "ERROR" "Verifique: 1) La IP es correcta, 2) El token es válido, 3) El servidor está accesible"
        exit 1
    fi
    
    # Verificar que la respuesta sea JSON válido
    if ! echo "${version_response}" | jq empty 2>/dev/null; then
        log "ERROR" "El servidor origen no devuelve JSON válido"
        log "ERROR" "Respuesta recibida: ${version_response:0:200}"
        log "ERROR" "Posibles causas: 1) URL incorrecta, 2) No es un servidor GitLab, 3) Problema de autenticación"
        exit 1
    fi
    
    log "SUCCESS" "Servidor origen verificado"
    
    # Probar servidor destino
    log "INFO" "Probando conexión con servidor destino ${DEST_IP}..."
    version_response=$(api_call "${DEST_IP}" "${DEST_TOKEN}" "version")
    if [[ $? -ne 0 ]]; then
        log "ERROR" "No se puede conectar al servidor destino"
        log "ERROR" "Verifique: 1) La IP es correcta, 2) El token es válido, 3) El servidor está accesible"
        exit 1
    fi
    
    # Verificar que la respuesta sea JSON válido
    if ! echo "${version_response}" | jq empty 2>/dev/null; then
        log "ERROR" "El servidor destino no devuelve JSON válido"
        log "ERROR" "Respuesta recibida: ${version_response:0:200}"
        log "ERROR" "Posibles causas: 1) URL incorrecta, 2) No es un servidor GitLab, 3) Problema de autenticación"
        exit 1
    fi
    
    log "SUCCESS" "Servidor destino verificado"
    
    # Probar endpoint de usuarios para verificar permisos
    log "INFO" "Verificando permisos de API..."
    local test_users=$(api_call "${SOURCE_IP}" "${SOURCE_TOKEN}" "users?per_page=1")
    if [[ $? -ne 0 ]] || ! echo "${test_users}" | jq empty 2>/dev/null; then
        log "ERROR" "No se pueden obtener usuarios del servidor origen"
        log "ERROR" "Verifique que el token tenga permisos de administrador"
        exit 1
    fi
    
    log "SUCCESS" "Conectividad y permisos verificados"
    
    # Ejecutar pasos de migración con manejo de errores
    log "INFO" "=================================================="
    log "INFO" "INICIANDO FASE 1: MIGRACIÓN DE USUARIOS"
    log "INFO" "=================================================="
    
    if export_users; then
        log "SUCCESS" "Exportación de usuarios completada"
    else
        log "ERROR" "Falló la exportación de usuarios, pero continuando..."
    fi
    
    if import_users; then
        log "SUCCESS" "Importación de usuarios completada"
    else
        log "ERROR" "Falló la importación de usuarios, pero continuando..."
    fi
    
    log "INFO" "=================================================="
    log "INFO" "INICIANDO FASE 2: MIGRACIÓN DE GRUPOS"
    log "INFO" "=================================================="
    
    if export_groups; then
        log "SUCCESS" "Exportación de grupos completada"
    else
        log "ERROR" "Falló la exportación de grupos, pero continuando..."
    fi
    
    if import_groups; then
        log "SUCCESS" "Importación de grupos completada"
    else
        log "ERROR" "Falló la importación de grupos, pero continuando..."
    fi
    
    log "INFO" "=================================================="
    log "INFO" "INICIANDO FASE 3: MIGRACIÓN DE MIEMBROS DE GRUPOS"
    log "INFO" "=================================================="
    
    if migrate_group_members; then
        log "SUCCESS" "Migración de miembros completada"
    else
        log "ERROR" "Falló la migración de miembros, pero continuando..."
    fi
    
    log "INFO" "=================================================="
    log "INFO" "INICIANDO FASE 4: MIGRACIÓN DE NAMESPACES"
    log "INFO" "=================================================="
    
    if migrate_namespaces; then
        log "SUCCESS" "Migración de namespaces completada"
    else
        log "ERROR" "Falló la migración de namespaces, pero continuando..."
    fi
    
    log "INFO" "=================================================="
    log "INFO" "INICIANDO FASE 5: MIGRACIÓN DE PROYECTOS"
    log "INFO" "(Exportación e importación secuencial con limpieza automática)"
    log "INFO" "=================================================="
    
    if export_and_migrate_projects; then
        log "SUCCESS" "Migración de proyectos completada"
    else
        log "ERROR" "Falló la migración de proyectos, pero continuando..."
    fi
    
    log "INFO" "=================================================="
    log "INFO" "INICIANDO FASE 6: VERIFICACIÓN FINAL"
    log "INFO" "=================================================="
    
    if check_import_status; then
        log "SUCCESS" "Verificación de estado completada"
    else
        log "WARNING" "No se pudo verificar el estado final"
    fi
    
    # Limpiar archivos temporales restantes
    cleanup_temp_files
    
    # Generar reporte final
    generate_report
    
    log "SUCCESS" "Migración completada. Revisar el reporte en ${EXPORT_DIR}/migration_report.txt"
    log "INFO" "Log detallado guardado en: ${LOG_FILE}"
    log "INFO" "NOTA: Los archivos de exportación se eliminan automáticamente tras importación exitosa para ahorrar espacio"
}

# Procesar argumentos
VERBOSE=0
PROTOCOL="http"

while getopts "s:t:d:T:p:hv" opt; do
    case ${opt} in
        s)
            SOURCE_IP="${OPTARG}"
            ;;
        t)
            SOURCE_TOKEN="${OPTARG}"
            ;;
        d)
            DEST_IP="${OPTARG}"
            ;;
        T)
            DEST_TOKEN="${OPTARG}"
            ;;
        p)
            PROTOCOL="${OPTARG}"
            ;;
        h)
            usage
            ;;
        v)
            VERBOSE=1
            ;;
        \?)
            echo "Opción inválida: -${OPTARG}" >&2
            usage
            ;;
    esac
done

# Validar argumentos requeridos
if [[ -z ${SOURCE_IP:-} ]] || [[ -z ${SOURCE_TOKEN:-} ]] || [[ -z ${DEST_IP:-} ]] || [[ -z ${DEST_TOKEN:-} ]]; then
    echo "Error: Todos los parámetros son requeridos" >&2
    usage
fi

# Verificar dependencias
for cmd in curl jq; do
    if ! command -v ${cmd} &> /dev/null; then
        echo "Error: ${cmd} no está instalado. Por favor instálelo primero." >&2
        exit 1
    fi
done

# Ejecutar migración
main