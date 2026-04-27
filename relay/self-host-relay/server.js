#!/usr/bin/env node

const http = require("http");
const { randomUUID } = require("crypto");

const port = Number(process.env.PORT || 8787);
const events = [];
const responses = [];
const clients = new Set();

function sendJSON(res, status, value) {
  const body = JSON.stringify(value, null, 2);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(body);
}

function readJSON(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > 1024 * 1024) {
        reject(new Error("payload too large"));
        req.destroy();
      }
    });
    req.on("end", () => {
      if (!body.trim()) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(body));
      } catch (error) {
        reject(error);
      }
    });
    req.on("error", reject);
  });
}

function broadcast(event) {
  const payload = `event: island\nid: ${event.id}\ndata: ${JSON.stringify(event)}\n\n`;
  for (const client of clients) {
    client.write(payload);
  }
}

function handleEventsStream(req, res) {
  res.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
  });
  res.write(": ping-island relay connected\n\n");
  for (const event of events.slice(-50)) {
    res.write(`event: island\nid: ${event.id}\ndata: ${JSON.stringify(event)}\n\n`);
  }
  clients.add(res);
  req.on("close", () => clients.delete(res));
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || "127.0.0.1"}`);

    if (req.method === "GET" && url.pathname === "/v1/health") {
      sendJSON(res, 200, { ok: true, events: events.length, responses: responses.length });
      return;
    }

    if (req.method === "GET" && url.pathname === "/v1/events") {
      handleEventsStream(req, res);
      return;
    }

    if (req.method === "POST" && url.pathname === "/v1/events") {
      const input = await readJSON(req);
      const event = {
        id: input.id || randomUUID(),
        kind: input.kind || "session",
        sessionID: input.sessionID || input.sessionId || "",
        title: input.title || "",
        body: input.body || "",
        clientName: input.clientName || "",
        payload: input.payload || {},
        createdAt: input.createdAt || new Date().toISOString(),
      };
      events.push(event);
      while (events.length > 500) events.shift();
      broadcast(event);
      sendJSON(res, 202, { ok: true, id: event.id });
      return;
    }

    if (req.method === "POST" && url.pathname === "/v1/pair") {
      const input = await readJSON(req);
      sendJSON(res, 200, {
        ok: true,
        device: {
          id: randomUUID(),
          name: input.name || "Companion",
          platform: input.platform || "iOS",
          pairedAt: new Date().toISOString(),
        },
      });
      return;
    }

    if (req.method === "POST" && url.pathname === "/v1/responses") {
      const response = {
        id: randomUUID(),
        ...await readJSON(req),
        receivedAt: new Date().toISOString(),
      };
      responses.push(response);
      while (responses.length > 500) responses.shift();
      sendJSON(res, 202, { ok: true, id: response.id });
      return;
    }

    if (req.method === "GET" && url.pathname === "/v1/responses") {
      sendJSON(res, 200, { ok: true, responses: responses.slice(-100) });
      return;
    }

    sendJSON(res, 404, { ok: false, error: "not found" });
  } catch (error) {
    sendJSON(res, 400, { ok: false, error: error.message });
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`Ping Island self-host relay listening on http://127.0.0.1:${port}`);
});
