#!/usr/bin/env bash
# ==============================================================================
# GESTOR UNIFICADO DE CICLO DE VIDA LOCAL (MULTI-ENTORNO) - POSIX BASH
# Evolution API & Webhook Gateway (Linux / macOS / VPS)
# ==============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

ENV_PATH="$SCRIPT_DIR/.env"
ENV_EXAMPLE_PATH="$SCRIPT_DIR/.env.example"
TUNNEL_LOG="/tmp/cloudflared_evolution_tunnel.log"

# Colores ANSI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# ==============================================================================
# 1. UTILIDADES DE PERSISTENCIA Y VARIABLES (.ENV)
# ==============================================================================

ensure_env_file() {
    if [ ! -f "$ENV_PATH" ]; then
        if [ -f "$ENV_EXAMPLE_PATH" ]; then
            cp "$ENV_EXAMPLE_PATH" "$ENV_PATH"
            echo -e "${GREEN} [INFO] Archivo .env generado a partir de .env.example${NC}"
        else
            touch "$ENV_PATH"
            echo -e "${YELLOW} [AVISO] Se creo un archivo .env vacio${NC}"
        fi
    fi
}

get_env_var() {
    local key="$1"
    local default_val="$2"
    if [ ! -f "$ENV_PATH" ]; then
        echo "$default_val"
        return
    fi
    local val
    val=$(grep "^${key}=" "$ENV_PATH" | head -n 1 | cut -d'=' -f2-)
    val="${val%\"}"
    val="${val#\"}"
    val="${val%\'}"
    val="${val#\'}"
    if [ -z "$val" ]; then
        echo "$default_val"
    else
        echo "$val"
    fi
}

set_env_var() {
    local key="$1"
    local val="$2"
    ensure_env_file
    if grep -q "^${key}=" "$ENV_PATH"; then
        # Actualizar linea existente
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${key}=.*|${key}=${val}|" "$ENV_PATH"
        else
            sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_PATH"
        fi
    else
        echo "${key}=${val}" >> "$ENV_PATH"
    fi
}

generate_secure_api_key() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16 | tr '[:lower:]' '[:upper:]'
    else
        node -e "console.log(require('crypto').randomBytes(16).toString('hex').toUpperCase())"
    fi
}

# ==============================================================================
# 2. DIAGNOSTICO DE ENTORNO Y RED (<100ms)
# ==============================================================================

get_internet_status() {
    local online=0
    local latency=0
    local start
    start=$(date +%s%3N 2>/dev/null || date +%s)

    if nc -z -w 1 1.1.1.1 53 2>/dev/null || curl -s --connect-timeout 1 http://1.1.1.1 >/dev/null 2>&1; then
        online=1
        local end
        end=$(date +%s%3N 2>/dev/null || date +%s)
        latency=$((end - start))
        [ $latency -le 0 ] && latency=20
    fi
    echo "$online $latency"
}

test_port_listening() {
    local port="$1"
    if command -v nc >/dev/null 2>&1; then
        nc -z 127.0.0.1 "$port" 2>/dev/null
        return $?
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null 2>&1
        return $?
    else
        (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1
        return $?
    fi
}

get_docker_status() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "not_installed"
        return
    fi
    if docker info >/dev/null 2>&1; then
        echo "running"
    else
        echo "stopped"
    fi
}

get_node_status() {
    if ! command -v node >/dev/null 2>&1; then
        echo "not_installed"
    else
        node -v 2>/dev/null
    fi
}

# ==============================================================================
# 3. GESTION DE TUNELES SEGUROS (CLOUDFLARE JIT)
# ==============================================================================

get_cloudflared_binary() {
    if command -v cloudflared >/dev/null 2>&1; then
        command -v cloudflared
        return
    fi

    local target_dir="$HOME/.local/bin"
    local target_file="$target_dir/cloudflared"

    if [ -f "$target_file" ]; then
        echo "$target_file"
        return
    fi

    echo -e "\n${CYAN}==========================================================${NC}" >&2
    echo -e "${YELLOW}  DESCARGA AUTOMATICA: CLOUDFLARE TUNNEL (cloudflared)${NC}" >&2
    echo -e "${CYAN}==========================================================${NC}" >&2
    mkdir -p "$target_dir"

    local arch
    arch=$(uname -m)
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local download_url=""

    if [ "$os" = "linux" ]; then
        if [ "$arch" = "x86_64" ]; then
            download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
        elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
            download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
        fi
    elif [ "$os" = "darwin" ]; then
        download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64"
    fi

    if [ -n "$download_url" ]; then
        echo -e " Descargando binario de Cloudflare Tunnel..." >&2
        curl -fsSL "$download_url" -o "$target_file"
        chmod +x "$target_file"
        if [ -f "$target_file" ]; then
            echo -e "${GREEN} [OK] Cloudflare Tunnel descargado exitosamente.${NC}" >&2
            echo "$target_file"
            return
        fi
    fi
    echo ""
}

start_cloudflare_tunnel() {
    local port="${1:-3050}"
    local bin
    bin=$(get_cloudflared_binary)

    if [ -z "$bin" ]; then
        echo -e "${RED} [CANCELADO] No se pudo localizar ni descargar cloudflared.${NC}"
        sleep 2
        return
    fi

    echo -e "\n${CYAN} Iniciando tunel temporal hacia http://127.0.0.1:${port} (enlace IPv4)...${NC}"
    rm -f "$TUNNEL_LOG"
    "$bin" tunnel --url "http://127.0.0.1:${port}" > "$TUNNEL_LOG" 2>&1 &
    local tunnel_pid=$!

    echo -n " Esperando asignacion de dominio seguro por Cloudflare..."
    local elapsed=0
    local detected_url=""
    while [ $elapsed -lt 15 ] && [ -z "$detected_url" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
        echo -n "."
        if [ -f "$TUNNEL_LOG" ]; then
            detected_url=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$TUNNEL_LOG" | head -n 1)
        fi
    done
    echo ""

    if [ -n "$detected_url" ]; then
        echo -e "\n${GREEN}==========================================================${NC}"
        echo -e "${GREEN}   TUNEL ACTIVO EN LINEA: ${detected_url}${NC}"
        echo -e "${GREEN}==========================================================${NC}"
    else
        echo -e "${YELLOW} [AVISO] El tunel esta conectando en segundo plano (PID: $tunnel_pid).${NC}"
    fi
}

# ==============================================================================
# 4. MOTOR DUAL ADAPTATIVO
# ==============================================================================

start_container_mode() {
    local with_tunnel="$1"
    ensure_env_file

    echo -e "\n${CYAN}==========================================================${NC}"
    echo -e "${CYAN}   INICIANDO MODO CONTENEDOR (DOCKER COMPOSE COMPLETO)${NC}"
    echo -e "${CYAN}==========================================================${NC}"

    local dstatus
    dstatus=$(get_docker_status)
    if [ "$dstatus" != "running" ]; then
        echo -e "${RED} [FALLO] Docker no esta corriendo en este sistema.${NC}"
        echo -n " Deseas iniciar en Modo Nativo (Ligero / Node.js) en su lugar? (s/n): "
        read -r alt
        if [[ "$alt" =~ ^[sSyY]$ ]]; then
            start_native_mode "$with_tunnel"
        fi
        return
    fi

    docker compose up -d
    echo -e "\n${GREEN} ¡Servicios en contenedores levantados!${NC}"
    docker compose ps

    local api_key
    api_key=$(get_env_var "AUTHENTICATION_API_KEY" "No configurada")
    echo -e "\n${GREEN}  * Panel Evolution Manager : http://localhost:8080/manager${NC}"
    echo -e "${GREEN}  * Gateway Webhook Router  : http://localhost:3050${NC}"
    echo -e "${YELLOW}  * ApiKey Global (.env)    : ${api_key}${NC}"

    if [ "$with_tunnel" = "true" ]; then
        start_cloudflare_tunnel 3050
    fi

    echo -e "\nPresiona [Enter] para volver al menu..."
    read -r
}

start_native_mode() {
    local with_tunnel="$1"
    ensure_env_file

    echo -e "\n${MAGENTA}==========================================================${NC}"
    echo -e "${MAGENTA}   INICIANDO MODO NATIVO (LIGERO / BAJO CONSUMO DE RAM)${NC}"
    echo -e "${MAGENTA}==========================================================${NC}"

    local nstatus
    nstatus=$(get_node_status)
    if [ "$nstatus" = "not_installed" ]; then
        echo -e "${RED} [ERROR] Node.js no esta instalado en este sistema.${NC}"
        sleep 2
        return
    fi

    local port
    port=$(get_env_var "PORT" "3050")
    if test_port_listening "$port"; then
        echo -e "${YELLOW} [AVISO] El puerto $port ya esta en uso por otro proceso.${NC}"
    else
        echo -e "${CYAN} Levantando Gateway Webhook con Node.js ($nstatus)...${NC}"
        nohup node "$SCRIPT_DIR/webhook-filter/server.js" > "/tmp/webhook_filter.log" 2>&1 &
        sleep 2
        if test_port_listening "$port"; then
            echo -e "${GREEN} [OK] Gateway Webhook escuchando en http://localhost:$port${NC}"
        fi
    fi

    if [ "$with_tunnel" = "true" ]; then
        start_cloudflare_tunnel "$port"
    fi

    echo -e "\nPresiona [Enter] para volver al menu..."
    read -r
}

# ==============================================================================
# 5. PANEL INTERACTIVO DE CONFIGURACION (.ENV WIZARD)
# ==============================================================================

show_config_wizard() {
    ensure_env_file
    while true; do
        clear
        local api_key
        api_key=$(get_env_var "AUTHENTICATION_API_KEY" "(No definida)")
        local groups
        groups=$(get_env_var "TARGET_GROUPS" "*")
        local dest
        dest=$(get_env_var "WEBHOOK_DESTINATIONS" "(Ninguno)")
        local srv_port
        srv_port=$(get_env_var "SERVER_PORT" "8080")
        local gate_port
        gate_port=$(get_env_var "PORT" "3050")

        echo -e "${CYAN}==========================================================${NC}"
        echo -e "${YELLOW}       PANEL DE CONFIGURACION Y CREDENCIALES (.env)       ${NC}"
        echo -e "${CYAN}==========================================================${NC}"
        echo -e " [1] Clave Global ApiKey (AUTHENTICATION_API_KEY):"
        echo -e "     -> ${GREEN}${api_key}${NC}"
        echo -e " [2] Grupos WhatsApp Autorizados (TARGET_GROUPS):"
        echo -e "     -> ${GREEN}${groups}${NC}"
        echo -e " [3] Destinos Webhook Multi-Plataforma (WEBHOOK_DESTINATIONS):"
        echo -e "     -> ${GREEN}${dest}${NC}"
        echo -e " [4] Puerto Evolution API (SERVER_PORT):"
        echo -e "     -> ${GRAY}${srv_port}${NC}"
        echo -e " [5] Puerto Gateway Webhook (PORT):"
        echo -e "     -> ${GRAY}${gate_port}${NC}"
        echo -e "${CYAN}----------------------------------------------------------${NC}"
        echo -e "${YELLOW} Acciones rapidas:${NC}"
        echo -e "  [G] Generar nueva ApiKey segura aleatoria (32 caracteres)"
        echo -e "  [A] Permitir TODOS los grupos de WhatsApp (*)"
        echo -e "  [0] Guardar y volver al menu principal"
        echo -e "${CYAN}==========================================================${NC}"
        echo -n " Elige una opcion [0-5, G, A]: "
        read -r opt
        opt=$(echo "$opt" | tr '[:lower:]' '[:upper:]')

        case "$opt" in
            1)
                echo -n " Ingrese nueva AUTHENTICATION_API_KEY: "
                read -r new_key
                [ -n "$new_key" ] && set_env_var "AUTHENTICATION_API_KEY" "$new_key"
                ;;
            2)
                echo -n " Ingrese IDs de grupos separados por coma o '*': "
                read -r new_groups
                [ -n "$new_groups" ] && set_env_var "TARGET_GROUPS" "$new_groups"
                ;;
            3)
                echo -n " Ingrese URLs de webhooks separadas por coma: "
                read -r new_dest
                [ -n "$new_dest" ] && set_env_var "WEBHOOK_DESTINATIONS" "$new_dest"
                ;;
            4)
                echo -n " Ingrese puerto Evolution API: "
                read -r new_sport
                [ -n "$new_sport" ] && set_env_var "SERVER_PORT" "$new_sport"
                ;;
            5)
                echo -n " Ingrese puerto Gateway Webhook: "
                read -r new_gport
                [ -n "$new_gport" ] && set_env_var "PORT" "$new_gport"
                ;;
            G)
                local gen
                gen=$(generate_secure_api_key)
                set_env_var "AUTHENTICATION_API_KEY" "$gen"
                echo -e "${GREEN} [OK] Clave generada: $gen${NC}"
                sleep 1
                ;;
            A)
                set_env_var "TARGET_GROUPS" "*"
                echo -e "${GREEN} [OK] Modo abierto activado (*)${NC}"
                sleep 1
                ;;
            0)
                return
                ;;
        esac
    done
}

# ==============================================================================
# 6. HEALTH CHECK Y AUDITORIA
# ==============================================================================

show_health_check() {
    clear
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${YELLOW}         DIAGNOSTICO Y SALUD DEL SISTEMA EN VIVO          ${NC}"
    echo -e "${CYAN}==========================================================${NC}"

    read -r is_online latency <<< "$(get_internet_status)"
    if [ "$is_online" -eq 1 ]; then
        echo -e " [1] Internet : ${GREEN}EN LINEA (${latency} ms)${NC}"
    else
        echo -e " [1] Internet : ${RED}DESCONECTADO${NC}"
    fi

    local dstatus
    dstatus=$(get_docker_status)
    local nstatus
    nstatus=$(get_node_status)
    echo -e " [2] Motores  : Docker [${dstatus}] | Node.js [${nstatus}]"

    echo -e "\n [3] Estado de Puertos:"
    local gw_port
    gw_port=$(get_env_var "PORT" "3050")
    local api_port
    api_port=$(get_env_var "SERVER_PORT" "8080")

    test_port_listening "$gw_port" && echo -e "     - Gateway Webhook (:$gw_port) : ${GREEN}[ACTIVO]${NC}" || echo -e "     - Gateway Webhook (:$gw_port) : ${GRAY}[DETENIDO]${NC}"
    test_port_listening "$api_port" && echo -e "     - Evolution API   (:$api_port) : ${GREEN}[ACTIVO]${NC}" || echo -e "     - Evolution API   (:$api_port) : ${GRAY}[DETENIDO]${NC}"
    test_port_listening 4433 && echo -e "     - Panel Manager   (:4433) : ${GREEN}[ACTIVO]${NC}" || echo -e "     - Panel Manager   (:4433) : ${GRAY}[DETENIDO]${NC}"

    if [ -f "$TUNNEL_LOG" ]; then
        local t_url
        t_url=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' "$TUNNEL_LOG" | head -n 1)
        if [ -n "$t_url" ]; then
            echo -e "\n [4] Tunel Cloudflare : ${GREEN}EN LINEA (${t_url})${NC}"
        fi
    fi

    echo -e "\nPresiona [Enter] para volver..."
    read -r
}

# ==============================================================================
# 7. APAGADO LIMPIO
# ==============================================================================

stop_all_services() {
    clear
    echo -e "${RED}==========================================================${NC}"
    echo -e "${YELLOW}             DETENIENDO TODOS LOS SERVICIOS               ${NC}"
    echo -e "${RED}==========================================================${NC}"

    if command -v docker >/dev/null 2>&1; then
        echo -e " Deteniendo contenedores Docker Compose..."
        docker compose stop
    fi

    echo -e " Deteniendo tuneles de Cloudflare..."
    pkill -f "cloudflared tunnel" 2>/dev/null || true
    rm -f "$TUNNEL_LOG"

    echo -e " Deteniendo procesos nativos..."
    pkill -f "webhook-filter/server.js" 2>/dev/null || true

    echo -e "${GREEN} [OK] Todos los servicios detenidos correctamente.${NC}"
    sleep 2
}

# ==============================================================================
# 8. BUCLE PRINCIPAL
# ==============================================================================

main_menu() {
    ensure_env_file
    while true; do
        clear
        local dstatus
        dstatus=$(get_docker_status)
        local nstatus
        nstatus=$(get_node_status)
        read -r is_online latency <<< "$(get_internet_status)"

        local net_str="${RED}DESCONECTADO${NC}"
        [ "$is_online" -eq 1 ] && net_str="${GREEN}EN LINEA (${latency} ms)${NC}"

        echo -e "${CYAN}==========================================================${NC}"
        echo -e "${YELLOW}       GESTOR DEL SISTEMA: EVOLUTION API & GATEWAY        ${NC}"
        echo -e "${CYAN}==========================================================${NC}"
        echo -e " Entorno detectado:"
        echo -e "   * Motor Contenedores (Docker) : ${dstatus}"
        echo -e "   * Motor Nativo (Node.js)      : ${nstatus}"
        echo -e "   * Conectividad a Internet     : ${net_str}"
        echo -e "${CYAN}----------------------------------------------------------${NC}"
        echo -e "${YELLOW} Opciones de Ejecucion:${NC}"
        echo -e "   [1] Iniciar con Contenedores (Docker Compose - Stack Completo)"
        echo -e "   [2] Iniciar con Contenedores + Tunel Publico Cloudflare"
        echo -e "   [3] Iniciar Modo Nativo (Gateway Ligero / Bajo Consumo)"
        echo -e "   [4] Iniciar Modo Nativo + Tunel Publico Cloudflare"
        echo -e "${CYAN}----------------------------------------------------------${NC}"
        echo -e "${YELLOW} Administracion y Control:${NC}"
        echo -e "   [5] Panel de Configuracion y Credenciales (.env Wizard)"
        echo -e "   [6] Diagnostico y Salud en Tiempo Real (Health Check)"
        echo -e "   [7] Detener todos los servicios"
        echo -e "   [0] Salir"
        echo -e "${CYAN}==========================================================${NC}"
        echo -n " Elige una opcion [0-7]: "
        read -r choice

        case "$choice" in
            1) start_container_mode "false" ;;
            2) start_container_mode "true" ;;
            3) start_native_mode "false" ;;
            4) start_native_mode "true" ;;
            5) show_config_wizard ;;
            6) show_health_check ;;
            7) stop_all_services ;;
            0) exit 0 ;;
            *) echo "Opcion no valida"; sleep 1 ;;
        esac
    done
}

main_menu
