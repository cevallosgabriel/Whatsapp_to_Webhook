# 🌐 Guía Paso a Paso: Filtro de WhatsApp con Cloudflare Workers

Esta guía detalla cómo crear y desplegar un **Cloudflare Worker** gratuito para filtrar el tráfico masivo de WhatsApp desde Evolution API y enviar únicamente los mensajes de tu grupo autorizado a **n8n / Discord**.

---

## 1. ¿Por qué usar un Cloudflare Worker?

WhatsApp envía cientos o miles de eventos diarios (estados, reacciones, mensajes privados, grupos no deseados). Si envías todo ese tráfico directamente a **n8n Cloud**, consumirás tu límite mensual de ejecuciones en cuestión de días.

**Ventajas del Worker de Cloudflare:**
* **100,000 peticiones gratis al día.**
* Descarta los mensajes no deseados en menos de **5 milisegundos**.
* Responde `200 OK` de inmediato a Evolution API, evitando saturar tu servidor local.
* Solo despierta a n8n cuando alguien escribe en tu grupo autorizado.

---

## 2. Paso 1: Crear una Cuenta en Cloudflare (Gratis)

1. Ingresa a: **[https://dashboard.cloudflare.com/](https://dashboard.cloudflare.com/)**
2. Haz clic en **Sign Up** y crea una cuenta gratuita con tu correo electrónico.
3. **No** necesitas agregar tarjetas de crédito, ni comprar un dominio, ni cambiar DNS.

---

## 3. Paso 2: Crear el Worker

1. En el menú lateral izquierdo del panel de Cloudflare, haz clic en **Workers & Pages**.
2. Haz clic en el botón azul **Create application** (o *Crear aplicación*).
3. Selecciona la pestaña **Workers** y pulsa en **Create Worker**.
4. Asigna un nombre a tu Worker (por ejemplo: `whatsapp-filter-proxy`).
5. Haz clic en **Deploy** (Desplegar) abajo a la derecha. (No te preocupes por el código de prueba que trae por defecto, lo cambiaremos ahora).

---

## 4. Paso 3: Pegar el Código de Filtrado

1. Una vez desplegado, haz clic en el botón **Edit code** (Editar código).
2. Borra todo el código que aparece en el editor de Cloudflare.
3. Copia y pega el siguiente script completo:

```javascript
export default {
  async fetch(request, env, ctx) {
    // 1. Solo permitimos peticiones POST (que son las que manda Evolution API)
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      const rawBody = await request.text();
      let body;
      try {
        body = JSON.parse(rawBody);
      } catch (e) {
        return new Response(JSON.stringify({ error: "Invalid JSON" }), { status: 400 });
      }

      // 2. Extraer el remoteJid del payload de Evolution API
      const remoteJid = body?.data?.key?.remoteJid || body?.data?.remoteJid || "";

      // ========================================================
      // CONFIGURACIÓN DE FILTRADO Y DESTINOS
      // ========================================================
      // Grupos permitidos (usa '*' para permitir todos, o lista de IDs @g.us)
      const GRUPOS_PERMITIDOS = [
        "000000000000000000@g.us" // Reemplaza con tu ID de grupo de WhatsApp
      ];
      const PERMITIR_TODOS = GRUPOS_PERMITIDOS.includes("*");

      // Destinos webhook (n8n, Discord, Telegram, Make o API REST)
      const DESTINOS = [
        "https://tu-instancia.n8n.cloud/webhook/whatsapp",
        // "https://discord.com/api/webhooks/TU_ID/TU_TOKEN",
        // "https://api.telegram.org/botTU_TOKEN/sendMessage?chat_id=TU_CHAT"
      ];

      // 3. Filtrar: Si NO es del grupo autorizado, respondemos 200 y terminamos aquí
      const esPermitido = PERMITIR_TODOS || GRUPOS_PERMITIDOS.includes(remoteJid);
      if (!esPermitido) {
        return new Response(
          JSON.stringify({
            status: "Ignored by proxy",
            reason: "Message not from target group",
            remoteJid: remoteJid || "Unknown"
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        );
      }

      // 4. Si SÍ es el grupo deseado, reenviamos a todos los destinos configurados
      const envios = DESTINOS.map(async (url) => {
        // Si es una URL de n8n, enviamos tanto al modo prueba como producción
        if (url.includes("/webhook/")) {
          const testUrl = url.replace("/webhook/", "/webhook-test/");
          return Promise.allSettled([
            fetch(testUrl, { method: "POST", headers: { "Content-Type": "application/json" }, body: rawBody }),
            fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: rawBody })
          ]);
        }
        return fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: rawBody
        });
      });

      await Promise.allSettled(envios);

      return new Response(
        JSON.stringify({
          status: "Forwarded successfully",
          remoteJid,
          destinos: DESTINOS.length
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      );

    } catch (err) {
      return new Response(
        JSON.stringify({ error: err.message }),
        {
          status: 500,
          headers: { "Content-Type": "application/json" }
        }
      );
    }
  },
};
```

4. Haz clic en el botón superior derecho **Save and deploy** (Guardar y desplegar).

---

## 5. Paso 4: Obtener la URL Pública del Worker

1. Tras hacer clic en *Save and deploy*, regresa a la página principal de tu Worker.
2. En la parte superior verás tu enlace público con el siguiente formato:
   ```text
   https://whatsapp-filter-proxy.tu-usuario.workers.dev
   ```
3. Copia ese enlace.

---

## 6. Paso 5: Apuntar Evolution API a Cloudflare

1. Entra a tu panel de **Evolution Manager**:
   [http://localhost:8080/manager](http://localhost:8080/manager)
2. Selecciona tu instancia (ejemplo: `Mi-Instancia`) y ve a la pestaña **Webhooks**.
3. En el campo **URL**, borra la URL anterior y pega la URL de tu Cloudflare Worker:
   `https://whatsapp-filter-proxy.tu-usuario.workers.dev`
4. Asegúrate de tener seleccionado el evento **`MESSAGES_UPSERT`**.
5. Haz clic en **Save** / **Guardar**.

---

## 7. Despliegue Opcional por Consola (CLI Wrangler)

Si en lugar del panel web prefieres desplegarlo por terminal con Node.js y npm:

```powershell
# 1. Instalar Wrangler (herramienta de Cloudflare)
npm install -g wrangler

# 2. Iniciar sesión en Cloudflare
wrangler login

# 3. Iniciar un proyecto de Worker
wrangler init whatsapp-filter-proxy

# 4. Pegar el código en src/index.js

# 5. Publicar el Worker
wrangler deploy
```

---

## 8. ¿Cloudflare Worker o Filtro Local en Docker?

| Característica | Cloudflare Worker | Filtro Local en Docker (`webhook-filter`) |
|---|---|---|
| **Consumo en la PC** | 0% (Corre en la nube de Cloudflare) | ~20 MB de memoria RAM |
| **Requiere cuenta externa** | Sí (Cuenta gratuita en Cloudflare) | No (100% local en tu propia máquina) |
| **Peticiones gratis** | 100,000 peticiones / día | Ilimitadas |
| **Facilidad de inicio** | Requiere configurar navegador/Wrangler | Viene incluido y arranca con `lanzador.bat` (o `./motor.sh`) |

Ambas opciones cumplen exactamente el mismo objetivo: filtrar los mensajes de WhatsApp para no agotar tu plan de n8n.
