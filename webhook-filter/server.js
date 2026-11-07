const http = require('http');

const PORT = parseInt(process.env.PORT || '3050', 10);

// Grupos permitidos: lista separada por comas de IDs (@g.us), o '*' para permitir todos
const RAW_TARGET_GROUPS = process.env.TARGET_GROUPS || process.env.TARGET_GROUP || '';
const TARGET_GROUPS = RAW_TARGET_GROUPS
  .split(',')
  .map(g => g.trim())
  .filter(Boolean);
const ALLOW_ALL_GROUPS = TARGET_GROUPS.includes('*');

// Destinos de webhook: lista separada por comas de URLs (n8n, Telegram, Discord, APIs)
const RAW_WEBHOOK_URLS = process.env.WEBHOOK_DESTINATIONS || process.env.N8N_WEBHOOK_URLS || process.env.N8N_WEBHOOK_URL || '';
const PARSED_URLS = RAW_WEBHOOK_URLS
  .split(',')
  .map(u => u.trim())
  .filter(Boolean);

// Mapear localhost/127.0.0.1 a host.docker.internal cuando corre dentro de Docker
function normalizeForDocker(url) {
  return url.replace(/\b(localhost|127\.0\.0\.1)\b/g, 'host.docker.internal');
}

// Configurar destinos con soporte dual para plataformas con test/prod (como n8n) y llamadas directas
const DESTINATIONS = PARSED_URLS.map(origUrl => {
  const normalized = normalizeForDocker(origUrl);
  let prodUrl = normalized;
  let testUrl = normalized;
  const isDual = normalized.includes('/webhook-test/') || normalized.includes('/webhook/');

  if (normalized.includes('/webhook-test/')) {
    prodUrl = normalized.replace('/webhook-test/', '/webhook/');
  } else if (normalized.includes('/webhook/')) {
    testUrl = normalized.replace('/webhook/', '/webhook-test/');
  }

  return {
    original: origUrl,
    normalized,
    prodUrl,
    testUrl,
    isDual
  };
});

console.log('==================================================================');
console.log('        WHATSAPP WEBHOOK GATEWAY & EVENT ROUTER (OPEN SOURCE)     ');
console.log('==================================================================');
console.log(` 🌐 Puerto de Escucha          : ${PORT}`);
if (ALLOW_ALL_GROUPS) {
  console.log(' 🎯 Filtro de Grupos           : [MODO ABIERTO] Permitiendo TODOS los grupos (*)');
} else if (TARGET_GROUPS.length > 0) {
  console.log(` 🎯 Grupos Autorizados (${TARGET_GROUPS.length})   : ${TARGET_GROUPS.join(', ')}`);
} else {
  console.log(' ⚠️  Filtro de Grupos           : [NINGUNO CONFIGURADO] Configura TARGET_GROUPS en .env');
}

console.log(` 🚀 Destinos Webhook (${DESTINATIONS.length})   :`);
if (DESTINATIONS.length === 0) {
  console.log('    (Sin destinos configurados. Configura WEBHOOK_DESTINATIONS en .env)');
} else {
  DESTINATIONS.forEach((d, i) => {
    console.log(`    [${i + 1}] ${d.original} ${d.original !== d.normalized ? '-> (' + d.normalized + ')' : ''}`);
  });
}
console.log('==================================================================');

const server = http.createServer(async (req, res) => {
  // Endpoint de salud y diagnóstico
  if (req.method === 'GET' && (req.url === '/' || req.url === '/health')) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({
      status: 'ok',
      service: 'whatsapp-webhook-gateway',
      allowAllGroups: ALLOW_ALL_GROUPS,
      targetGroupsCount: TARGET_GROUPS.length,
      targetGroups: TARGET_GROUPS,
      destinationsCount: DESTINATIONS.length,
      destinations: DESTINATIONS.map(d => d.original)
    }));
  }

  // Solo procesar peticiones POST de Evolution API
  if (req.method !== 'POST') {
    res.writeHead(405, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Method not allowed' }));
  }

  let rawBody = '';
  req.on('data', chunk => {
    rawBody += chunk;
  });

  req.on('end', async () => {
    let body;
    try {
      body = JSON.parse(rawBody);
    } catch (err) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'Invalid JSON body' }));
    }

    const data = body?.data || {};
    const key = data?.key || {};
    const remoteJid = key?.remoteJid || data?.remoteJid || '';
    const fromMe = key?.fromMe || false;
    const pushName = data?.pushName || (fromMe ? 'Yo (Mi Dispositivo)' : 'Desconocido');
    const event = body?.event || 'evento';
    const timestamp = new Date().toLocaleTimeString('es-ES', { hour12: false });

    // Extraer texto o tipo de contenido para el registro de auditoría
    let texto = '';
    if (data?.message?.conversation) {
      texto = data.message.conversation;
    } else if (data?.message?.extendedTextMessage?.text) {
      texto = data.message.extendedTextMessage.text;
    } else if (data?.message?.imageMessage) {
      texto = '📷 [Imagen] ' + (data.message.imageMessage.caption || '');
    } else if (data?.message?.stickerMessage) {
      texto = '🎨 [Sticker]';
    } else if (data?.message?.audioMessage) {
      texto = '🎤 [Audio / Nota de voz]';
    } else if (data?.message?.videoMessage) {
      texto = '🎥 [Video] ' + (data.message.videoMessage.caption || '');
    } else if (data?.message?.documentMessage) {
      texto = '📄 [Documento: ' + (data.message.documentMessage.fileName || 'archivo') + ']';
    } else if (event !== 'messages.upsert') {
      texto = `[Evento interno: ${event}]`;
    } else {
      texto = '[Multimedia / Sin texto]';
    }

    const snippet = texto.length > 50 ? texto.substring(0, 47) + '...' : texto;

    // 1. Filtrar si NO coincide con los grupos permitidos
    const isTargetGroup = ALLOW_ALL_GROUPS || (remoteJid && TARGET_GROUPS.includes(remoteJid));

    if (!isTargetGroup) {
      console.log(`[${timestamp}] 🛑 [FILTRADO] De: "${pushName}" | Chat: ${remoteJid || 'Privado'} | Motivo: No coincide con lista blanca | Contenido: "${snippet}"`);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({
        status: 'ignored',
        reason: 'Message not from target group',
        remoteJid,
        pushName
      }));
    }

    // 2. Mensaje PERMITIDO
    console.log(`[${timestamp}] 🎯 [ACEPTADO] De: "${pushName}" | Chat: ${remoteJid} | Contenido: "${snippet}"`);

    if (DESTINATIONS.length === 0) {
      console.log(`[${timestamp}] ⚠️ [SIN DESTINOS] No hay webhooks configurados para recibir el mensaje.`);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ status: 'accepted_no_destinations' }));
    }

    console.log(`[${timestamp}] ⏳ [DESPACHANDO] Reenviando a ${DESTINATIONS.length} webhook(s)...`);

    const results = [];

    for (let i = 0; i < DESTINATIONS.length; i++) {
      const dest = DESTINATIONS[i];
      try {
        if (dest.isDual) {
          // Destino con soporte test y producción (ej. n8n)
          const [testRes, prodRes] = await Promise.allSettled([
            fetch(dest.testUrl, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: rawBody
            }),
            fetch(dest.prodUrl, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: rawBody
            })
          ]);

          const testStatus = testRes.status === 'fulfilled' ? testRes.value.status : 'ERR_RED';
          const prodStatus = prodRes.status === 'fulfilled' ? prodRes.value.status : 'ERR_RED';
          const ok = prodStatus === 200 || testStatus === 200;

          if (ok) {
            console.log(`[${timestamp}] ✅ [ENTREGADO] Destino #${i + 1} (${dest.original}): Prod: HTTP ${prodStatus} | Test: HTTP ${testStatus}`);
          } else {
            console.log(`[${timestamp}] ⚠️ [NO ENTREGADO] Destino #${i + 1} (${dest.original}): Prod: HTTP ${prodStatus} | Test: HTTP ${testStatus}`);
          }

          results.push({
            url: dest.original,
            success: ok,
            testStatus,
            prodStatus
          });
        } else {
          // Destino webhook estándar directo (Telegram Bot, Discord Webhook, API REST)
          const directRes = await fetch(dest.normalized, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: rawBody
          });
          const ok = directRes.status >= 200 && directRes.status < 300;
          console.log(`[${timestamp}] ${ok ? '✅ [ENTREGADO]' : '⚠️ [FALLO]'} Destino #${i + 1} (${dest.original}): HTTP ${directRes.status}`);
          results.push({
            url: dest.original,
            success: ok,
            status: directRes.status
          });
        }
      } catch (err) {
        console.error(`[${timestamp}] ❌ [ERROR CONEXION] Destino #${i + 1} (${dest.original}):`, err.message);
        results.push({
          url: dest.original,
          success: false,
          error: err.message
        });
      }
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'forwarded', results }));
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Gateway de eventos WhatsApp activo y listo en el puerto ${PORT}...`);
});
