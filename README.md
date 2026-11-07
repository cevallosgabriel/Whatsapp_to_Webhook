# 🚀 Whatsapp_to_webhook | WhatsApp Webhook Gateway & Event Router

<p align="center">
  <img src="./public/hover-evolution.png" alt="Evolution API Gateway" width="300" />
</p>

<p align="center">
  <strong>Plataforma completa de mensajería para WhatsApp con Enrutador Inteligente y Filtro de Eventos Multi-Destino.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Docker-Ready-2496ED?logo=docker&logoColor=white" alt="Docker Ready" />
  <img src="https://img.shields.io/badge/Windows-1--Click%20Launchers-0078D6?logo=windows&logoColor=white" alt="Windows 1-Click" />
  <img src="https://img.shields.io/badge/Multi--Router-n8n%20%7C%20Discord%20%7C%20Telegram%20%7C%20REST-brightgreen" alt="Multi-Router" />
  <img src="https://img.shields.io/badge/Cloudflare%20Tunnel-Auto--Detect-F38020?logo=cloudflare&logoColor=white" alt="Cloudflare Tunnel" />
  <img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License: Apache 2.0" />
</p>

---

## 🌟 ¿Qué es este Proyecto?

Este repositorio combina el motor oficial de **Evolution API v2** con un **Gateway & Enrutador Inteligente de Webhooks** ligero (`webhook-filter`), listo para producción en entornos locales (Windows / Linux) o en la nube.

Resuelve el problema común de saturación de webhooks y agotamiento de límites en plataformas de automatización (**n8n**, **Make**, **Zapier**, **Discord**, **Telegram**, **APIs personalizadas**), filtrando en memoria el tráfico innecesario (mensajes privados, estados, reacciones, grupos no autorizados) y reenviando únicamente los eventos relevantes a **múltiples destinos en paralelo**.

---

## 🏗️ Arquitectura del Sistema

```text
               ┌────────────────────────────────────────────────────────┐
               │                  WhatsApp (Teléfono)                   │
               └───────────────────────────┬────────────────────────────┘
                                           │ (Baileys / WebSockets)
                                           ▼
               ┌────────────────────────────────────────────────────────┐
               │               Evolution API (Puerto 8080)               │
               │   • PostgreSQL (5432)   • Redis (6379)  • Manager Web  │
               └───────────────────────────┬────────────────────────────┘
                                           │ Webhook interno (MESSAGES_UPSERT)
                                           ▼
               ┌────────────────────────────────────────────────────────┐
               │    Webhook Gateway & Event Router (Puerto 3050)        │
               │   • Filtro por Lista Blanca (TARGET_GROUPS)            │
               │   • Soporte comodín (*) para todos los chats           │
               │   • Conversión automática Docker <-> Host              │
               │   • Enrutamiento concurrente Multi-Destino             │
               └───────┬───────────────────┬───────────────────┬────────┘
                       │                   │                   │
                       ▼                   ▼                   ▼
                 ┌───────────┐       ┌───────────┐       ┌───────────┐
                 │    n8n    │       │  Discord  │       │ Telegram  │
                 │(Test/Prod)│       │  Webhook  │       │  Bot API  │
                 └───────────┘       └───────────┘       └───────────┘
```

---

## ⚡ Inicio Rápido y Gestor Unificado (1 Solo Clic)

El repositorio incluye un **Gestor Unificado de Ciclo de Vida Multi-Entorno** que permite ejecutar, configurar y monitorear el sistema sin tocar una sola línea de código:

### 🪟 En Windows:
Haz doble clic en **`lanzador.bat`** (abre el panel interactivo con motor dual y asistente de credenciales).

### 🐧 En Linux / macOS / VPS:
Ejecuta en tu terminal:
```bash
chmod +x motor.sh && ./motor.sh
```

---

### 🎛️ Opciones del Panel Unificado

| Archivo / Componente | Funcionalidad y Auto-Detección |
|---|---|
| **`lanzador.bat` / `motor.ps1`** | **Panel Principal Interactivo (Windows)**. Permite arrancar en modo Contenedores (Docker) o Modo Nativo (Node.js ligero, ~20MB RAM), crear túneles públicos Cloudflare al instante, auditar tráfico y realizar diagnósticos en vivo. |
| **`motor.sh`** | **Panel Principal Interactivo (Linux / macOS / VPS)**. Equivalente universal en Bash POSIX para servidores y entornos Unix. |
| **Panel de Credenciales (.env Wizard)** | **Opción [5] del menú**: Visualiza y cambia `AUTHENTICATION_API_KEY`, `TARGET_GROUPS` y `WEBHOOK_DESTINATIONS` directamente en pantalla, o genera una nueva clave segura aleatoria con un solo clic. |
| **Túnel Público Cloudflare JIT** | **Opciones [2] y [4] del menú**: Expone cualquier puerto a HTTPS público (`trycloudflare.com`) sin abrir puertos en el router. Incluye descarga automática JIT de `cloudflared`. |
| **Auditor de Mensajes y Tráfico** | **Opción [7] del menú**: Monitorea en tiempo real los mensajes entrantes, filtrados y entregados, y permite enviar un mensaje de prueba simulado. |
| **Apagado Limpio y Seguro** | **Opción [8] del menú**: Detiene contenedores Docker, túneles y procesos en segundo plano de forma segura. |

---

## ⚙️ Configuración (`.env`)

Copia la plantilla `.env.example` a `.env` (se realiza automáticamente la primera vez que ejecutas `lanzador.bat` o `motor.sh`):

```bash
cp .env.example .env
```

### 1. Filtrado de Grupos o Chats
Define qué grupos o contactos tienen autorización para disparar tus flujos:

```env
# Permite un solo grupo:
TARGET_GROUPS=000000000000000000@g.us

# O varios grupos separados por comas:
# TARGET_GROUPS=000000000000000000@g.us,000000000000000001@g.us

# O usa '*' para recibir y reenviar TODOS los grupos:
# TARGET_GROUPS=*
```

### 2. Destinos Webhook Multi-Plataforma
Configura una o múltiples URLs separadas por comas. El enrutador enviará el payload a todos en paralelo:

```env
# Enrutamiento a n8n local y un canal de Discord:
WEBHOOK_DESTINATIONS=http://localhost:5678/webhook-test/whatsapp,https://discord.com/api/webhooks/TU_ID/TU_TOKEN

# O agrega también un Bot de Telegram o tu propia API REST:
# WEBHOOK_DESTINATIONS=http://localhost:5678/webhook/whatsapp,https://api.telegram.org/botTU_TOKEN/sendMessage?chat_id=TU_CHAT,https://api.tuempresa.com/v1/whatsapp
```

> **Nota:** Puedes usar `http://localhost:...` sin preocuparte; el Gateway traduce automáticamente `localhost` a `host.docker.internal` dentro del contenedor Docker para comunicarse fluidamente con servicios corriendo en tu PC.

---

## 🌐 Conexión con Cloudflare Tunnel

Si necesitas recibir webhooks desde internet o conectar n8n en la nube con tu API local sin abrir puertos en tu módem:

1. Ejecuta **`lanzador.bat`** (o `./motor.sh`) y selecciona la opción **`[2]`** (Contenedor + Túnel) o **`[4]`** (Nativo + Túnel).
2. Si es tu primera vez, el sistema detectará si falta `cloudflared` y lo descargará automáticamente.
3. El script te entregará una URL segura HTTPS instantánea del tipo:
   ```text
   https://random-words.trycloudflare.com
   ```

---

## 🔍 Diagnóstico y Estado en Vivo

Puedes verificar el estado del Gateway visitando en tu navegador o mediante curl:

```bash
curl http://localhost:3050/health
```

Respuesta JSON:
```json
{
  "status": "ok",
  "service": "whatsapp-webhook-gateway",
  "allowAllGroups": false,
  "targetGroupsCount": 1,
  "targetGroups": ["000000000000000000@g.us"],
  "destinationsCount": 2,
  "destinations": [
    "http://localhost:5678/webhook-test/whatsapp",
    "https://discord.com/api/webhooks/TU_ID/TU_TOKEN"
  ]
}
```

Para ver la actividad y diagnóstico en tiempo real, ejecuta **`lanzador.bat`** y selecciona la opción **`[6]`** (Diagnóstico / Health Check) o **`[7]`** (Auditor de mensajes).

---

## ☁️ Alternativa 100% Serverless: Cloudflare Workers

Si prefieres filtrar el tráfico directamente en la nube de Cloudflare sin consumir memoria RAM de tu máquina, revisa nuestra guía paso a paso:
👉 **[GUIA_CLOUDFLARE_WORKERS.md](./GUIA_CLOUDFLARE_WORKERS.md)**

Para desplegar y configurar Evolution API en profundidad (bases de datos, variables y endpoints):
👉 **[GUIA_EVOLUTION_API.md](./GUIA_EVOLUTION_API.md)**

---

## 🐳 Despliegue Manual con Docker (Linux / Mac / VPS)

Si estás en un servidor Linux o prefieres la terminal:

```bash
# 1. Clonar el repositorio
git clone <URL_DE_TU_REPOSITORIO>
cd evolution-api

# 2. Configurar entorno
cp .env.example .env
nano .env

# 3. Levantar los 5 servicios (API, Frontend, PostgreSQL, Redis, Gateway)
docker compose up -d

# 4. Ver registros
docker compose logs -f
```

---

## 🛡️ Seguridad y Privacidad

- El archivo `.env` está estrictamente excluido en `.gitignore`.
- Ningún ID de grupo privado, token de bot ni credencial está hardcodeado en el código fuente.
- Evolution API cuenta con autenticación por `AUTHENTICATION_API_KEY` configurable en `.env`.

---

## 📄 Licencia

Este proyecto está distribuido bajo la licencia **Apache 2.0**. Consulta [LICENSE](./LICENSE) para más detalles.
Evolution API es una marca registrada de Evolution Foundation.
