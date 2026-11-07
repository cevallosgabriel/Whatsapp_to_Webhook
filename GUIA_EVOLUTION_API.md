# 📘 Guía Paso a Paso: Instalación y Configuración de Evolution API con Docker

Esta guía explica desde cero cómo clonar, configurar permisos y variables de entorno, y desplegar **Evolution API** en Windows usando Docker Desktop.

---

## 1. Requisitos Previos

1. **Docker Desktop:**
   * Descargar e instalar [Docker Desktop para Windows](https://www.docker.com/products/docker-desktop/).
   * Asegurarse de tener habilitado el soporte de **WSL 2** (Windows Subsystem for Linux).
   * Docker Desktop debe estar abierto y ejecutándose en segundo plano (icono de ballena verde en la barra de tareas).
2. **Git:**
   * Tener instalado Git para Windows para clonar el repositorio.

---

## 2. Descargar el Repositorio Oficial

Abre tu terminal (PowerShell, CMD o Git Bash) en la carpeta donde deseas alojar el proyecto:

```powershell
# Clonar el repositorio oficial de Evolution API
git clone https://github.com/EvolutionAPI/evolution-api.git

# Entrar en la carpeta del proyecto
cd evolution-api
```

---

## 3. Configuración del Entorno (`.env`)

Dentro de la carpeta `evolution-api`, el archivo `.env.example` contiene la plantilla con todas las variables necesarias.

1. **Crear el archivo `.env`:**
   ```powershell
   Copy-Item .env.example .env
   ```

2. **Variables Clave a Configurar en `.env`:**
   Abre `.env` con tu editor preferido (Bloc de notas, VS Code, etc.) y ajusta estos valores esenciales:

   ```env
   # 1. Servidor
   SERVER_NAME=evolution
   SERVER_TYPE=http
   SERVER_PORT=8080
   SERVER_URL=http://localhost:8080

   # 2. Clave Global de Seguridad (ApiKey)
   # Esta clave protege tu servidor de accesos no autorizados:
   AUTHENTICATION_API_KEY=MiClaveSuperSegura123
   AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true
   LANGUAGE=es

   # 3. Base de Datos PostgreSQL
   DATABASE_PROVIDER=postgresql
   POSTGRES_DATABASE=evolution_db
   POSTGRES_USERNAME=evolution
   POSTGRES_PASSWORD=evolution_pass
   DATABASE_CONNECTION_URI='postgresql://evolution:evolution_pass@evolution-postgres:5432/evolution_db?schema=evolution_api'
   DATABASE_CONNECTION_CLIENT_NAME=evolution_exchange

   # 4. Redis (Para sesiones y caché de WhatsApp)
   CACHE_REDIS_ENABLED=true
   CACHE_REDIS_URI=redis://evolution-redis:6379/6
   CACHE_REDIS_PREFIX_KEY=evolution
   ```

---

## 4. Configuración de Docker Compose (`docker-compose.yaml`)

El archivo `docker-compose.yaml` define cómo conviven los 4 contenedores oficiales de Evolution API:

```yaml
version: "3.8"

services:
  api:
    container_name: evolution_api
    image: evoapicloud/evolution-api:latest
    restart: always
    depends_on:
      - redis
      - evolution-postgres
    ports:
      - "8080:8080"
    volumes:
      - evolution_instances:/evolution/instances
      - ./manager/dist:/evolution/manager/dist:ro
    networks:
      - evolution-net
    env_file:
      - .env
    expose:
      - "8080"

  frontend:
    container_name: evolution_frontend
    image: evoapicloud/evolution-manager:latest
    restart: always
    ports:
      - "4433:80"
    volumes:
      - ./manager-nginx.conf:/etc/nginx/conf.d/nginx.conf:ro
      - ./manager/dist:/usr/share/nginx/html:ro
    networks:
      - evolution-net

  redis:
    container_name: evolution_redis
    image: redis:latest
    restart: always
    command: >
      redis-server --port 6379 --appendonly yes
    volumes:
      - evolution_redis:/data
    networks:
      evolution-net:
        aliases:
          - redis
          - evolution-redis
    expose:
      - "6379"

  evolution-postgres:
    container_name: evolution_postgres
    image: postgres:15
    restart: always
    env_file:
      - .env
    command:
      - postgres
      - -c
      - max_connections=1000
      - -c
      - listen_addresses=*
    environment:
      - POSTGRES_DB=${POSTGRES_DATABASE}
      - POSTGRES_USER=${POSTGRES_USERNAME}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      evolution-net:
        aliases:
          - postgres
          - evolution-postgres
    expose:
      - "5432"

  webhook-filter:
    container_name: webhook_filter
    image: node:alpine
    restart: always
    working_dir: /app
    volumes:
      - ./webhook-filter:/app
    environment:
      - PORT=3050
      - TARGET_GROUPS=${TARGET_GROUPS:-${TARGET_GROUP:-}}
      - WEBHOOK_DESTINATIONS=${WEBHOOK_DESTINATIONS:-${N8N_WEBHOOK_URL:-}}
    command: node server.js
    ports:
      - "3050:3050"
    networks:
      evolution-net:
        aliases:
          - webhook-filter
    expose:
      - "3050"

volumes:
  evolution_instances:
  evolution_redis:
  postgres_data:

networks:
  evolution-net:
    name: evolution-net
    driver: bridge
```

---

## 5. Encender los Servicios con Docker

Ejecuta el siguiente comando para construir, descargar imágenes e iniciar todo en segundo plano:

```powershell
docker compose up -d
```

### Verificar el estado:
```powershell
docker compose ps
```
Deberás ver los contenedores (`evolution_api`, `evolution_postgres`, `evolution_redis`) en estado `Up`.

### Ver los logs de la API en vivo:
```powershell
docker logs -f evolution_api
```

---

## 6. Acceder al Panel Visual (Manager) y Vincular WhatsApp

1. **Abrir el navegador:**
   Ingresa a: **[http://localhost:8080/manager](http://localhost:8080/manager)**
2. **Credenciales de acceso:**
   * **Server URL:** `http://localhost:8080`
   * **Global ApiKey:** `MiClaveSuperSegura123` *(o la que definiste en `.env`)*
3. **Crear una Instancia:**
   * Haz clic en **Create Instance**.
   * Escribe un nombre identificador (ejemplo: `Mi-Instancia`).
4. **Vincular WhatsApp (Código QR):**
   * Se generará un código QR en la pantalla.
   * En tu teléfono, abre WhatsApp > **Ajustes** (o 3 puntos arriba a la derecha) > **Dispositivos vinculados** > **Vincular un dispositivo**.
   * Escanea el código QR de la pantalla.
   * La instancia cambiará a estado **CONNECTED / OPEN**.

---

## 7. Configuración de Permisos y Webhooks

Para que la API envíe los mensajes que llegan a WhatsApp hacia tu webhook (filtro o n8n):

1. En el panel de **Evolution Manager**, haz clic sobre tu instancia.
2. Ve a la pestaña **Webhooks** en el menú de la instancia.
3. Configura:
   * **Enabled:** Activar el interruptor (ON).
   * **URL:** Coloca la URL de tu webhook (por ejemplo: `http://webhook-filter:3050/webhook` si usas el filtro Docker, o la URL de Cloudflare/n8n).
   * **Events (Eventos):** Marca indispensablemente **`MESSAGES_UPSERT`** (este es el evento que dispara cada mensaje nuevo recibido). Opcionalmente puedes marcar `MESSAGES_UPDATE` y `CONNECTION_UPDATE`.
   * **By Events / Base64:** Déjalos desactivados salvo que requieras descargar audios o imágenes pesadas directamente en base64.
4. Haz clic en **Save** / **Guardar**.

---

## 8. Comandos Útiles de Mantenimiento

* **Gestor unificado (1 Clic):** Doble clic en `lanzador.bat` (en Windows) o `./motor.sh` (en Linux).
* **Detener todos los servicios:** Opción `[8]` en `lanzador.bat` o:
  ```powershell
  docker compose stop
  ```
* **Reiniciar servicios:**
  ```powershell
  docker compose restart
  ```
* **Ver logs de la API:**
  ```powershell
  docker logs -f evolution_api
  ```
