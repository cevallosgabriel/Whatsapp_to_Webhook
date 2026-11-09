const {
  default: makeWASocket,
  useMultiFileAuthState,
  DisconnectReason,
  Browsers,
  fetchLatestBaileysVersion,
  normalizeMessageContent
} = require('@whiskeysockets/baileys');
const qrcode = require('qrcode-terminal');
const pino = require('pino');
const path = require('path');
const fs = require('fs');

// ==============================================================================
// 1. CARGA AUTOMÁTICA DE .ENV
// ==============================================================================
function loadEnv() {
  const possiblePaths = [
    path.resolve(__dirname, '../.env'),
    path.resolve(__dirname, '.env'),
    path.resolve(process.cwd(), '.env'),
    path.resolve(process.cwd(), '../.env')
  ];

  for (const envPath of possiblePaths) {
    if (fs.existsSync(envPath)) {
      try {
        const content = fs.readFileSync(envPath, 'utf8');
        content.split(/\r?\n/).forEach(line => {
          const trimmed = line.trim();
          if (trimmed && !trimmed.startsWith('#')) {
            const eqIndex = trimmed.indexOf('=');
            if (eqIndex > 0) {
              const key = trimmed.substring(0, eqIndex).trim();
              let val = trimmed.substring(eqIndex + 1).trim();
              if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
                val = val.substring(1, val.length - 1);
              }
              if (process.env[key] === undefined || process.env[key] === '') {
                process.env[key] = val;
              }
            }
          }
        });
        break;
      } catch (err) {}
    }
  }
}
loadEnv();

// ==============================================================================
// 2. CONFIGURACIÓN, PERSISTENCIA Y ALMACÉN EN MEMORIA (MSGSTORE)
// ==============================================================================
const AUTH_DIR = path.resolve(__dirname, 'session_auth');
const PROCESSED_IDS_FILE = path.resolve(__dirname, 'processed_ids.json');
const LOG_FILE = path.resolve(__dirname, '../.gateway.log');

const RAW_TARGET_GROUPS = process.env.TARGET_GROUPS || process.env.TARGET_GROUP || '';
const TARGET_GROUPS = RAW_TARGET_GROUPS.split(',').map(g => g.trim()).filter(Boolean);
const ALLOW_ALL_GROUPS = TARGET_GROUPS.includes('*');

const RAW_WEBHOOK_URLS = process.env.WEBHOOK_DESTINATIONS || process.env.N8N_WEBHOOK_URLS || process.env.N8N_WEBHOOK_URL || '';
const PARSED_URLS = RAW_WEBHOOK_URLS.split(',').map(u => u.trim()).filter(Boolean);

const DESTINATIONS = PARSED_URLS.map(origUrl => {
  let prodUrl = origUrl;
  let testUrl = origUrl;
  const isDual = origUrl.includes('/webhook-test/') || origUrl.includes('/webhook/');

  if (origUrl.includes('/webhook-test/')) {
    prodUrl = origUrl.replace('/webhook-test/', '/webhook/');
  } else if (origUrl.includes('/webhook/')) {
    testUrl = origUrl.replace('/webhook/', '/webhook-test/');
  }

  return { original: origUrl, prodUrl, testUrl, isDual };
});

// Almacén en memoria para citas y reintentos de descifrado
const msgStore = new Map();

function saveToMsgStore(id, message) {
  if (!id || !message) return;
  msgStore.set(id, message);
  if (msgStore.size > 2000) {
    const oldestKey = msgStore.keys().next().value;
    msgStore.delete(oldestKey);
  }
}

// Formato de hora local [HH:mm:ss] compatible con el Auditor de motor.ps1
function getLocalTimestamp() {
  return new Date().toLocaleTimeString('es-ES', { hour12: false });
}

function logEvent(msg) {
  const ts = getLocalTimestamp();
  const line = `[${ts}] ${msg}`;
  console.log(line);
  try {
    fs.appendFileSync(LOG_FILE, line + '\n');
  } catch (e) {}
}

// Control de IDs procesados para evitar reenvíos duplicados
let processedIds = new Set();
try {
  if (fs.existsSync(PROCESSED_IDS_FILE)) {
    const data = JSON.parse(fs.readFileSync(PROCESSED_IDS_FILE, 'utf8'));
    if (Array.isArray(data)) {
      processedIds = new Set(data.slice(-1000));
    }
  }
} catch (e) {}

function markIdProcessed(id) {
  if (!id) return;
  processedIds.add(id);
  if (processedIds.size > 2000) {
    const trimmed = Array.from(processedIds).slice(-1000);
    processedIds = new Set(trimmed);
  }
  try {
    fs.writeFileSync(PROCESSED_IDS_FILE, JSON.stringify(Array.from(processedIds)), 'utf8');
  } catch (e) {}
}

// ==============================================================================
// 3. DESENVOLVER MENSAJES (normalizeMessageContent, EDITADOS, ENCUESTAS, REACCIONES)
// ==============================================================================
function unwrapMessage(rawMsg) {
  if (!rawMsg) return {};
  let msg = normalizeMessageContent(rawMsg) || rawMsg;

  // Desenvolver mensajes efímeros / temporales / viewOnce
  if (msg.ephemeralMessage?.message) {
    msg = normalizeMessageContent(msg.ephemeralMessage.message) || msg.ephemeralMessage.message;
  }
  if (msg.viewOnceMessage?.message) {
    msg = normalizeMessageContent(msg.viewOnceMessage.message) || msg.viewOnceMessage.message;
  }
  if (msg.viewOnceMessageV2?.message) {
    msg = normalizeMessageContent(msg.viewOnceMessageV2.message) || msg.viewOnceMessageV2.message;
  }
  if (msg.documentWithCaptionMessage?.message) {
    msg = normalizeMessageContent(msg.documentWithCaptionMessage.message) || msg.documentWithCaptionMessage.message;
  }

  // Soporte para mensajes editados
  if (msg.protocolMessage?.editedMessage) {
    msg = normalizeMessageContent(msg.protocolMessage.editedMessage) || msg.protocolMessage.editedMessage;
  }

  return msg;
}

function extractTextSnippet(msg) {
  const unwrapped = unwrapMessage(msg);

  if (unwrapped.conversation) return unwrapped.conversation;
  if (unwrapped.extendedTextMessage?.text) return unwrapped.extendedTextMessage.text;
  if (unwrapped.imageMessage) return '📷 [Imagen] ' + (unwrapped.imageMessage.caption || '');
  if (unwrapped.videoMessage) return '🎥 [Video] ' + (unwrapped.videoMessage.caption || '');
  if (unwrapped.stickerMessage) return '🎨 [Sticker]';
  if (unwrapped.audioMessage) return '🎤 [Audio / Nota de voz]';
  if (unwrapped.documentMessage) return '📄 [Documento: ' + (unwrapped.documentMessage.fileName || 'archivo') + ']';
  if (unwrapped.contactMessage) return '👤 [Contacto: ' + (unwrapped.contactMessage.displayName || '') + ']';
  if (unwrapped.locationMessage) return '📍 [Ubicación]';
  if (unwrapped.reactionMessage) return '👍 [Reacción: ' + (unwrapped.reactionMessage.text || '') + ']';
  if (unwrapped.pollCreationMessage) return '📊 [Encuesta: ' + (unwrapped.pollCreationMessage.name || '') + ']';
  if (unwrapped.pollUpdateMessage) return '📊 [Voto de Encuesta]';

  return '[Multimedia / Mensaje de Sistema]';
}

// ==============================================================================
// 4. DESPACHO DIRECTO A WEBHOOKS CON SOPORTE DUAL (TEST / PROD)
// ==============================================================================
async function dispatchToWebhook(url, payload) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 10000);

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': 'Whatsapp-Native-Baileys-Gateway/2.0'
      },
      body: JSON.stringify(payload),
      signal: controller.signal
    });
    clearTimeout(timeoutId);
    return { ok: res.ok, status: res.status };
  } catch (err) {
    clearTimeout(timeoutId);
    return { ok: false, error: err.name === 'AbortError' ? 'Timeout (10s)' : err.message };
  }
}

async function dispatchAll(payload, snippet, pushName, remoteJid) {
  if (DESTINATIONS.length === 0) {
    logEvent(`⚠️ [SIN DESTINO] Mensaje recibido pero no hay WEBHOOK_DESTINATIONS en .env`);
    return;
  }

  for (const dest of DESTINATIONS) {
    if (dest.isDual) {
      const resTest = await dispatchToWebhook(dest.testUrl, payload);
      if (resTest.ok) {
        logEvent(`🚀 [ENVIADO - TEST] De: "${pushName}" | Chat: ${remoteJid} -> ${dest.testUrl} (HTTP ${resTest.status})`);
        continue;
      }

      const resProd = await dispatchToWebhook(dest.prodUrl, payload);
      if (resProd.ok) {
        logEvent(`🚀 [ENVIADO - PROD] De: "${pushName}" | Chat: ${remoteJid} -> ${dest.prodUrl} (HTTP ${resProd.status})`);
      } else {
        logEvent(`❌ [FALLO ENVÍO] -> ${dest.prodUrl} (Error: ${resProd.error || 'HTTP ' + resProd.status})`);
      }
    } else {
      const res = await dispatchToWebhook(dest.original, payload);
      if (res.ok) {
        logEvent(`🚀 [ENVIADO] De: "${pushName}" | Chat: ${remoteJid} -> ${dest.original} (HTTP ${res.status})`);
      } else {
        logEvent(`❌ [FALLO ENVÍO] -> ${dest.original} (Error: ${res.error || 'HTTP ' + res.status})`);
      }
    }
  }
}

// ==============================================================================
// 5. PROCESAMIENTO Y FILTRADO DE MENSAJES
// ==============================================================================
async function handleIncomingMessage(message) {
  if (!message || !message.key) return;

  const msgId = message.key.id;
  const rawMessage = message.message || {};
  saveToMsgStore(msgId, rawMessage);

  if (msgId && processedIds.has(msgId)) {
    return;
  }
  if (msgId) markIdProcessed(msgId);

  const remoteJid = message.key.remoteJid || '';

  // Descarte silencioso de eventos de sincronización interna del dispositivo y broadcasts
  if (remoteJid.endsWith('@lid') || remoteJid === 'status@broadcast' || remoteJid.endsWith('@newsletter')) {
    return;
  }

  const fromMe = message.key.fromMe || false;
  const pushName = message.pushName || (fromMe ? 'Yo (Mi Dispositivo)' : 'Contacto');

  const unwrapped = unwrapMessage(rawMessage);
  const snippet = extractTextSnippet(unwrapped);

  // Validación de lista blanca de grupos
  const isTarget = ALLOW_ALL_GROUPS || (remoteJid && TARGET_GROUPS.includes(remoteJid));

  if (!isTarget) {
    logEvent(`🛑 [FILTRADO] De: "${pushName}" | Chat: ${remoteJid || 'Privado'} | Motivo: No coincide con lista blanca | Contenido: "${snippet.substring(0, 45)}"`);
    return;
  }

  logEvent(`🎯 [ACEPTADO] De: "${pushName}" | Chat: ${remoteJid} | Contenido: "${snippet.substring(0, 45)}"`);

  // Construir payload estándar compatible con n8n / Evolution API
  const formattedPayload = {
    event: 'messages.upsert',
    instance: 'whatsapp-native',
    data: {
      key: {
        remoteJid,
        fromMe,
        id: msgId
      },
      pushName,
      messageTimestamp: message.messageTimestamp,
      message: unwrapped
    }
  };

  await dispatchAll(formattedPayload, snippet, pushName, remoteJid);
}

// ==============================================================================
// 6. CONEXIÓN PRINCIPAL WHATSAPP (BAILEYS)
// ==============================================================================
let currentSock = null;

async function connectToWhatsApp() {
  if (!fs.existsSync(AUTH_DIR)) {
    fs.mkdirSync(AUTH_DIR, { recursive: true });
  }

  // Destruir socket anterior si existe para evitar duplicación y error 515
  if (currentSock) {
    try {
      currentSock.ev.removeAllListeners();
      currentSock.end(undefined);
    } catch (e) {}
    currentSock = null;
  }

  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);

  // Obtener versión dinámica más reciente de WhatsApp Web
  let version = [2, 3000, 1015901307];
  try {
    const versionInfo = await fetchLatestBaileysVersion();
    if (versionInfo && versionInfo.version) {
      version = versionInfo.version;
    }
  } catch (e) {}

  console.log('==================================================================');
  console.log('       CONECTOR NATIVO DE WHATSAPP (SIN DOCKER - DIRECTO)         ');
  console.log('==================================================================');
  console.log(` 📁 Directorio de Sesión : ${AUTH_DIR}`);
  console.log(` 🌐 Destinos Webhook (${DESTINATIONS.length}) : ${DESTINATIONS.map(d => d.original).join(', ')}`);
  console.log(` 🎯 Filtro de Grupos     : ${ALLOW_ALL_GROUPS ? '[TODOS (*)]' : TARGET_GROUPS.join(', ')}`);
  console.log(` 💻 Identidad Emulada    : Chrome en Windows (v${version.join('.')})`);
  console.log('==================================================================\n');

  const sock = makeWASocket({
    version,
    auth: state,
    printQRInTerminal: false,
    logger: pino({ level: 'silent' }),
    browser: Browsers.windows('Chrome'),
    syncFullHistory: false,
    defaultQueryTimeoutMs: 120000,
    connectTimeoutMs: 60000,
    keepAliveIntervalMs: 25000,
    generateHighQualityLinkPreview: false,
    getMessage: async (key) => {
      const stored = msgStore.get(key.id);
      if (stored) return stored;
      return { conversation: '' };
    }
  });

  currentSock = sock;

  sock.ev.process(async (events) => {
    if (events['creds.update']) {
      await saveCreds();
    }

    if (events['connection.update']) {
      const { connection, lastDisconnect, qr } = events['connection.update'];

      if (qr) {
        console.log('\n📱 ESCANEA ESTE CÓDIGO QR CON TU WHATSAPP:\n');
        qrcode.generate(qr, { small: true });
        console.log('Instrucciones: Abre WhatsApp > Dispositivos Vinculados > Vincular un dispositivo.\n');
        try {
          const QRCodeImg = require('qrcode');
          QRCodeImg.toFile(path.resolve(__dirname, 'qr_whatsapp.png'), qr, { width: 350 });
        } catch (e) {}
      }

      if (connection === 'close') {
        const statusCode = (lastDisconnect?.error)?.output?.statusCode;
        const isLoggedOut = statusCode === DisconnectReason.loggedOut;
        const isRestartRequired = statusCode === DisconnectReason.restartRequired || statusCode === 515;

        if (isRestartRequired) {
          logEvent(`🔄 Reinicio limpio requerido tras vincular QR (Código 515). Reconectando...`);
          setTimeout(connectToWhatsApp, 1500);
        } else if (!isLoggedOut) {
          logEvent(`⚠️ Conexión cerrada (Código: ${statusCode || 'desconocido'}). Reconectando en 3s...`);
          setTimeout(connectToWhatsApp, 3000);
        } else {
          logEvent('❌ Sesión cerrada permanentemente en el teléfono. Elimina "session_auth" para escanear de nuevo.');
        }
      } else if (connection === 'open') {
        logEvent('✅ [OK] ¡WHATSAPP VINCULADO Y EN LÍNEA EXITOSAMENTE!');
        logEvent('🚀 Conector activo: Despachando eventos directamente a tus Webhooks.');

        // Suscripción forzada de presencia a los grupos configurados para asegurar entrega inmediata de eventos
        if (!ALLOW_ALL_GROUPS && TARGET_GROUPS.length > 0) {
          for (const grp of TARGET_GROUPS) {
            try {
              await sock.presenceSubscribe(grp);
            } catch (e) {}
          }
        }
      }
    }

    if (events['messaging-history.set']) {
      const history = events['messaging-history.set'];
      if (Array.isArray(history.messages)) {
        for (const msg of history.messages) {
          await handleIncomingMessage(msg);
        }
      }
    }

    if (events['messages.upsert']) {
      const upsert = events['messages.upsert'];
      if (Array.isArray(upsert.messages)) {
        for (const message of upsert.messages) {
          await handleIncomingMessage(message);
        }
      }
    }
  });
}

connectToWhatsApp().catch(err => {
  console.error('Error al inicializar conector WhatsApp:', err);
});
