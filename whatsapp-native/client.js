const { default: makeWASocket, useMultiFileAuthState, DisconnectReason, Browsers } = require('@whiskeysockets/baileys');
const qrcode = require('qrcode-terminal');
const pino = require('pino');
const path = require('path');
const fs = require('fs');
const http = require('http');

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
    timeout: 5000
  }, () => {});

  req.on('error', () => {});
  req.write(data);
  req.end();
}

function processMessage(message) {
  if (!message || !message.key) return;

  const formattedPayload = {
    event: 'messages.upsert',
    data: {
      key: {
        remoteJid: message.key.remoteJid || '',
        fromMe: message.key.fromMe || false,
        id: message.key.id || ''
      },
      pushName: message.pushName || (message.key.fromMe ? 'Yo (Mi Dispositivo)' : 'Contacto'),
      message: message.message || {}
    }
  };

  forwardEventToGateway(formattedPayload);
}

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
    logger: pino({ level: 'error' }),
    browser: Browsers.windows('Desktop'),
    syncFullHistory: false,
    defaultQueryTimeoutMs: 120000,
    connectTimeoutMs: 60000,
    keepAliveIntervalMs: 25000,
    generateHighQualityLinkPreview: false,
    getMessage: async (key) => ({ conversation: '' })
  });

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
        const shouldReconnect = statusCode !== DisconnectReason.loggedOut;
        console.log(`⚠️ Conexión cerrada (Código: ${statusCode || 'desconocido'}). Reconectando: ${shouldReconnect}...`);
        if (shouldReconnect) {
          setTimeout(connectToWhatsApp, 3000);
        } else {
          console.log('❌ Sesión cerrada en el teléfono. Elimina "session_auth" para escanear de nuevo.');
        }
      } else if (connection === 'open') {
        console.log('\n==================================================================');
        console.log('  ✅ [OK] ¡WHATSAPP VINCULADO Y EN LÍNEA EXITOSAMENTE!');
        console.log('  🚀 Todos los mensajes entrantes se reenviarán al Gateway (3050).');
        console.log('==================================================================\n');
      }
    }

    if (events['messaging-history.set']) {
      const history = events['messaging-history.set'];
      if (Array.isArray(history.messages)) {
        for (const msg of history.messages) {
          processMessage(msg);
        }
      }
    }

    if (events['messages.upsert']) {
      const upsert = events['messages.upsert'];
      if (Array.isArray(upsert.messages)) {
        for (const message of upsert.messages) {
          processMessage(message);
        }
      }
    }
  });
}

connectToWhatsApp().catch(err => {
  console.error('Error al inicializar conector WhatsApp:', err);
});
