# Script de Migración Completa de GitLab - Documentación Técnica

## Descripción General

El script `script-migracion.sh` es una herramienta automatizada de línea de comandos diseñada para realizar migraciones completas entre servidores GitLab. Implementa un proceso de migración integral que incluye usuarios, grupos, proyectos y repositorios, garantizando la preservación de la estructura organizacional y los permisos.

## Arquitectura del Sistema

### Flujo de Migración

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ Servidor Origen │ --> │ Script Migración │ --> │ Servidor Destino│
│   (GitLab API)  │     │   (Bash + jq)    │     │   (GitLab API)  │
└─────────────────┘     └──────────────────┘     └─────────────────┘
         |                       |                         |
         v                       v                         v
    [Exportación]          [Procesamiento]            [Importación]
    - Usuarios             - Validación              - Usuarios
    - Grupos               - Mapeo IDs               - Grupos
    - Proyectos            - Manejo errores          - Proyectos
    - Miembros             - Logging                 - Miembros
```

### Fases de Migración

1. **Fase 1: Migración de Usuarios**
   - Exportación de todos los usuarios del servidor origen
   - Importación con validación de duplicados
   - Generación automática de contraseñas temporales

2. **Fase 2: Migración de Grupos**
   - Exportación respetando jerarquía (grupos padre primero)
   - Recreación de estructura de grupos anidados
   - Preservación de configuraciones de visibilidad

3. **Fase 3: Migración de Miembros de Grupos**
   - Mapeo de IDs de usuarios entre servidores
   - Asignación de niveles de acceso correctos
   - Manejo de usuarios faltantes

4. **Fase 4: Migración de Namespaces**
   - Verificación de namespaces necesarios
   - Preparación para importación de proyectos
   - Validación de permisos

5. **Fase 5: Migración de Proyectos**
   - Exportación e importación secuencial
   - Limpieza automática de archivos temporales
   - Preservación de configuraciones y metadatos

6. **Fase 6: Verificación Final**
   - Validación de importaciones exitosas
   - Generación de reporte detallado
   - Limpieza de archivos temporales restantes

## Componentes Técnicos

### Variables Globales

```bash
SCRIPT_DIR          # Directorio del script
EXPORT_DIR          # Directorio temporal para exportaciones
LOG_FILE            # Archivo de log detallado
USERS_FILE          # JSON con usuarios exportados
GROUPS_FILE         # JSON con grupos exportados
PROJECTS_FILE       # JSON con lista de proyectos
```

### Funciones Principales

#### `api_call()`
Función central para todas las interacciones con la API de GitLab.

**Características:**
- Reintentos automáticos con backoff exponencial
- Manejo de rate limiting (HTTP 429)
- Soporte para errores de servidor (502, 503, 504)
- Logging detallado en modo verbose

**Parámetros:**
1. `server` - IP/hostname del servidor
2. `token` - Token de API privado
3. `endpoint` - Endpoint de la API (sin /api/v4/)
4. `method` - Método HTTP (GET, POST, DELETE)
5. `data` - Datos JSON para POST/PUT
6. `output_file` - Archivo para guardar respuesta
7. `max_retries` - Número máximo de reintentos

#### `get_all_paginated()`
Maneja la paginación automática de la API de GitLab.

**Proceso:**
1. Itera por todas las páginas disponibles
2. Combina resultados usando jq
3. Valida JSON en cada paso
4. Implementa pausas entre páginas

#### `migrate_single_project()`
Implementación de migración proyecto por proyecto.

**Flujo:**
1. Exportación del proyecto origen
2. Monitoreo del estado de exportación
3. Descarga del archivo exportado
4. Importación inmediata al destino
5. Limpieza de archivos temporales

### Manejo de Errores

#### Estrategia de Reintentos
```bash
# Backoff exponencial para rate limiting
wait_time=1
while [[ ${attempt} -le ${max_retries} ]]; do
    # Intento de llamada API
    if [[ ${http_code} -eq 429 ]]; then
        sleep ${wait_time}
        wait_time=$((wait_time * 2))
    fi
done
```

#### Validación de Permisos
- Verificación previa de permisos de creación
- Creación de proyecto temporal de prueba
- Validación de acceso a namespaces

### Optimizaciones de Rendimiento

1. **Procesamiento en Lotes**
   - Paginación eficiente (100 items por página)
   - Pausas inteligentes entre operaciones

2. **Gestión de Memoria**
   - Limpieza inmediata de archivos temporales
   - Procesamiento secuencial de proyectos grandes

3. **Concurrencia Controlada**
   - Pausas entre operaciones críticas
   - Prevención de sobrecarga del servidor

## Requisitos del Sistema

### Software Requerido
- **Bash 4.0+** - Shell script moderno
- **curl** - Cliente HTTP para API calls
- **jq** - Procesador JSON de línea de comandos

### Permisos Necesarios

#### Token del Servidor Origen
- Scope: `api`
- Permisos: Lectura completa
- Acceso a: usuarios, grupos, proyectos

#### Token del Servidor Destino
- Scope: `api`
- Permisos: Administrador o capacidad de crear proyectos
- Acceso a: creación de usuarios, grupos, proyectos

## Uso del Script

### Sintaxis Básica
```bash
./script-migracion.sh -s IP_ORIGEN -t TOKEN_ORIGEN -d IP_DESTINO -T TOKEN_DESTINO [-p PROTOCOL] [-v]
```

### Parámetros
- `-s` - IP/hostname del servidor GitLab origen
- `-t` - Token de API del servidor origen
- `-d` - IP/hostname del servidor GitLab destino
- `-T` - Token de API del servidor destino
- `-p` - Protocolo (http/https, default: http)
- `-v` - Modo verbose (muestra detalles adicionales)
- `-h` - Muestra ayuda

### Ejemplo de Uso
```bash
./script-migracion.sh \
    -s gitlab-old.example.com \
    -t glpat-xxxxxxxxxxxxx \
    -d gitlab-new.example.com \
    -T glpat-yyyyyyyyyyyyy \
    -p https \
    -v
```

## Estructura de Archivos Generados

```
gitlab_migration_YYYYMMDD_HHMMSS/
├── importacion-YYYYMMDD_HHMMSS.log    # Log detallado
├── users.json                          # Usuarios exportados
├── groups.json                         # Grupos exportados
├── projects.json                       # Lista de proyectos
├── existing_users.json                 # Usuarios en destino
├── existing_groups.json                # Grupos en destino
├── source_namespaces.json              # Namespaces origen
├── dest_namespaces.json                # Namespaces destino
├── user_mapping.json                   # Mapeo IDs usuarios
├── namespace_mapping.json              # Mapeo namespaces
├── migration_report.txt                # Reporte final
└── temp_*                              # Archivos temporales (auto-eliminados)
```

## Manejo de Casos Especiales

### Usuarios del Sistema
El script omite automáticamente:
- `root`
- `ghost`
- `support-bot`

### Validación de Duplicados
- Verificación por username Y email
- Detección de entidades pre-existentes
- Logging de elementos omitidos

### Proyectos con Namespaces Faltantes
- Intento de mapeo automático
- Fallback al namespace del usuario actual
- Logging detallado de decisiones

## Seguridad

### Manejo de Tokens
- No se registran en logs
- Se ocultan en salidas debug
- Transmisión segura vía HTTPS

### Contraseñas de Usuario
- Generación de contraseñas temporales
- Flag `reset_password` activado
- Notificación requerida post-migración

### Validación de Datos
- Sanitización de entradas JSON
- Validación de campos requeridos
- Manejo seguro de caracteres especiales

## Troubleshooting

### Errores Comunes

#### HTTP 403 Forbidden
**Causas:**
- Token sin permisos suficientes
- Namespace destino inaccesible
- Restricciones del servidor

**Solución:**
- Verificar permisos del token
- Confirmar acceso a namespaces
- Revisar configuración del servidor

#### Rate Limiting (HTTP 429)
**Síntomas:**
- Múltiples reintentos automáticos
- Pausas incrementales

**Solución:**
- El script maneja automáticamente
- Considerar ejecutar en horarios de baja carga

#### Timeout en Exportación
**Causas:**
- Proyectos muy grandes
- Servidor sobrecargado

**Solución:**
- Aumentar timeout en código
- Dividir migración en lotes

### Logs y Debugging

#### Modo Verbose
```bash
./script-migracion.sh ... -v
```
Proporciona:
- Detalles de cada API call
- Respuestas completas de errores
- Progreso detallado

#### Análisis de Logs
```bash
# Ver solo errores
grep "ERROR" importacion-*.log

# Ver resumen de operaciones
grep -E "SUCCESS|ERROR|WARNING" importacion-*.log

# Seguimiento en tiempo real
tail -f gitlab_migration_*/importacion-*.log
```

## Limitaciones Conocidas

1. **Sin Migración de:**
   - Configuraciones del servidor
   - Runners de CI/CD
   - Hooks del sistema
   - Páginas de GitLab

2. **Dependencias de Red:**
   - Requiere conectividad estable
   - Sensible a latencia alta

3. **Recursos del Sistema:**
   - Uso intensivo de disco para proyectos grandes
   - Consumo de memoria proporcional a usuarios/grupos

## Mejores Prácticas

### Antes de la Migración
1. Realizar backup completo de ambos servidores
2. Verificar espacio en disco disponible
3. Notificar a usuarios sobre la migración
4. Ejecutar en horario de baja actividad

### Durante la Migración
1. Monitorear logs en tiempo real
2. Verificar espacio en disco periódicamente
3. No interrumpir el proceso una vez iniciado

### Después de la Migración
1. Verificar integridad de datos migrados
2. Actualizar configuraciones de CI/CD
3. Notificar a usuarios sobre nuevas contraseñas
4. Eliminar directorio de exportación si no es necesario

## Mantenimiento del Script

### Actualizaciones de API
- Verificar cambios en endpoints de GitLab
- Actualizar manejo de nuevos campos
- Mantener compatibilidad hacia atrás

### Optimizaciones Futuras
- Implementar migración paralela de proyectos
- Añadir soporte para webhooks
- Incluir migración de CI/CD pipelines

## Conclusión

Este script proporciona una solución robusta y automatizada para migraciones completas de GitLab, con énfasis en la integridad de datos, manejo de errores y trazabilidad completa del proceso. Su diseño modular permite extensiones y adaptaciones según necesidades específicas.