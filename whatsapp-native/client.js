const { default: makeWASocket, useMultiFileAuthState, DisconnectReason } = require('@whiskeysockets/baileys');
const qrcode = require('qrcode-terminal');
const pino = require('pino');
const path = require('path');
const fs = require('fs');
const http = require('http');

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

const GATEWAY_PORT = parseInt(process.env.PORT || '3050', 10);
const AUTH_DIR = path.resolve(__dirname, 'session_auth');

// ==============================================================================
// 2. REENVÍO DE EVENTO AL GATEWAY LOCAL
// ==============================================================================
function forwardEventToGateway(payload) {
  const data = JSON.stringify(payload);
  const req = http.request({
    hostname: '127.0.0.1',
    port: GATEWAY_PORT,
    path: '/',
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(data)
    },
    timeout: 3000
  }, (res) => {
    // Evento entregado exitosamente al Gateway
  });

  req.on('error', (err) => {
    // Si el gateway no está listo aún, no botar el conector
  });

  req.write(data);
  req.end();
}

// ==============================================================================
// 3. CONEXIÓN PRINCIPAL WHATSAPP (BAILEYS)
// ==============================================================================
async function connectToWhatsApp() {
  if (!fs.existsSync(AUTH_DIR)) {
    fs.mkdirSync(AUTH_DIR, { recursive: true });
  }

  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);

  console.log('==================================================================');
  console.log('       CONECTOR NATIVO DE WHATSAPP (SIN DOCKER - BAILEYS)        ');
  console.log('==================================================================');
  console.log(` 📁 Directorio de Sesión : ${AUTH_DIR}`);
  console.log(` 🌐 Gateway Destino     : http://127.0.0.1:${GATEWAY_PORT}`);
  console.log('==================================================================\n');

  const sock = makeWASocket({
    auth: state,
    printQRInTerminal: false,
    logger: pino({ level: 'silent' }),
    browser: ['Whatsapp_to_Webhook', 'Desktop', '1.0.0']
  });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      console.log('\n📱 ESCANEA ESTE CÓDIGO QR CON TU WHATSAPP:\n');
      qrcode.generate(qr, { small: true });
      console.log('Instrucciones: Abre WhatsApp > Dispositivos Vinculados > Vincular un dispositivo.\n');
    }

    if (connection === 'close') {
      const statusCode = (lastDisconnect?.error)?.output?.statusCode;
      const shouldReconnect = statusCode !== DisconnectReason.loggedOut;
      console.log(`⚠️ Conexión cerrada (Código: ${statusCode || 'desconocido'}). Reconectando: ${shouldReconnect}...`);
      if (shouldReconnect) {
        setTimeout(connectToWhatsApp, 3000);
      } else {
        console.log('❌ Sesión cerrada permanentemente en el teléfono. Elimina "session_auth" para escanear de nuevo.');
      }
    } else if (connection === 'open') {
      console.log('\n==================================================================');
      console.log('  ✅ [OK] ¡WHATSAPP VINCULADO Y EN LÍNEA EXITOSAMENTE!');
      console.log('  🚀 Todos los mensajes entrantes se reenviarán al Gateway (3050).');
      console.log('==================================================================\n');
    }
  });

  sock.ev.on('messages.upsert', async (m) => {
    const message = m.messages?.[0];
    if (!message) return;

    // Normalizar payload al esquema que el Gateway espera
    const formattedPayload = {
      event: 'messages.upsert',
      data: {
        key: {
          remoteJid: message.key?.remoteJid || '',
          fromMe: message.key?.fromMe || false,
          id: message.key?.id || ''
        },
        pushName: message.pushName || (message.key?.fromMe ? 'Yo' : 'Contacto'),
        message: message.message || {}
      }
    };

    forwardEventToGateway(formattedPayload);
  });
}

connectToWhatsApp().catch(err => {
  console.error('Error al inicializar conector WhatsApp:', err);
});
