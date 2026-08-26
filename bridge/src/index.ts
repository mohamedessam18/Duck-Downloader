import { connect, type Socket } from 'node:net';
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PROTOCOL_VERSION } from '../../contracts/duck-protocol.js';
import { TOKEN_FILE, socketPath } from '../../engine/src/paths.js';

/**
 * The native-messaging bridge.
 *
 * Chrome starts this process when the extension opens a port and kills it the
 * moment that port closes or the browser quits. That lifetime is precisely why
 * the engine is a separate process: if downloading happened here, closing a
 * browser window would end every transfer in flight.
 *
 * So this does as little as possible — frame the protocol, forward bytes, start
 * the engine if it is not already up. It holds no state worth losing.
 */

const here = dirname(fileURLToPath(import.meta.url));

/** Chrome's framing: a 32-bit native-endian length, then UTF-8 JSON. */
const HEADER_BYTES = 4;

/** Chrome refuses anything larger coming from the extension. */
const MAX_MESSAGE_BYTES = 1024 * 1024;

/**
 * stdout is the protocol channel — anything written there that is not a framed
 * message corrupts the stream and Chrome drops the port. Diagnostics go to
 * stderr, which the browser captures.
 */
function log(message: string): void {
  process.stderr.write(`[duck-bridge] ${message}\n`);
}

/* --------------------------------- state --------------------------------- */

let engine: Socket | null = null;
let queued: string[] = [];
let connecting: Promise<void> | null = null;
let inbox = Buffer.alloc(0);

/* ------------------------------ Chrome side ------------------------------ */

process.stdin.on('data', (chunk: Buffer) => {
  inbox = Buffer.concat([inbox, chunk]);

  for (;;) {
    if (inbox.length < HEADER_BYTES) return;

    const length = inbox.readUInt32LE(0);
    if (length > MAX_MESSAGE_BYTES) {
      log(`refusing a ${length}-byte message`);
      process.exit(1);
    }
    if (inbox.length < HEADER_BYTES + length) return;

    const body = inbox.subarray(HEADER_BYTES, HEADER_BYTES + length).toString('utf8');
    inbox = inbox.subarray(HEADER_BYTES + length);
    void handleInbound(body);
  }
});

process.stdin.on('end', () => {
  // The extension went away. The engine keeps running — that is the whole point.
  engine?.destroy();
  process.exit(0);
});

function sendToChrome(payload: unknown): void {
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  const header = Buffer.alloc(HEADER_BYTES);
  header.writeUInt32LE(body.length, 0);
  process.stdout.write(Buffer.concat([header, body]));
}

/* ------------------------------ Engine side ------------------------------ */

/**
 * The engine wants a shared secret that lives in a user-only file the extension
 * cannot read. The bridge is the one component that can see both sides, so it
 * fills the token in as the handshake passes through.
 */
async function handleInbound(line: string): Promise<void> {
  let outgoing = line;

  try {
    const message = JSON.parse(line) as { type?: string };
    if (message.type === 'hello') {
      const token = (await readFile(TOKEN_FILE, 'utf8')).trim();
      outgoing = JSON.stringify({ ...message, token, protocolVersion: PROTOCOL_VERSION });
    }
  } catch {
    // Not JSON, or no token file yet. Forward it and let the engine object.
  }

  if (!engine) {
    // Queue rather than drop: the first message is the handshake, and losing it
    // leaves the extension waiting on a reply that never comes.
    queued.push(outgoing);
    await ensureEngine();
    return;
  }

  engine.write(`${outgoing}\n`);
}

async function ensureEngine(): Promise<void> {
  if (connecting) return connecting;

  connecting = (async () => {
    for (let attempt = 0; attempt < 20; attempt++) {
      const socket = await tryConnect();
      if (socket) {
        attach(socket);
        return;
      }
      // Only the first failure means "not running"; after that it is starting.
      if (attempt === 0) startEngine();
      await sleep(250);
    }

    sendToChrome({
      type: 'error',
      message: 'Duck Engine is not running and could not be started.',
    });
    process.exit(1);
  })().finally(() => {
    connecting = null;
  });

  return connecting;
}

function tryConnect(): Promise<Socket | null> {
  return new Promise((settle) => {
    const socket = connect(socketPath());
    const done = (result: Socket | null) => {
      socket.removeAllListeners('connect');
      socket.removeAllListeners('error');
      settle(result);
    };
    socket.once('connect', () => done(socket));
    socket.once('error', () => {
      socket.destroy();
      done(null);
    });
  });
}

function attach(socket: Socket): void {
  engine = socket;
  socket.setEncoding('utf8');

  let buffer = '';
  socket.on('data', (chunk: string) => {
    buffer += chunk;
    let newline: number;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      try {
        sendToChrome(JSON.parse(line));
      } catch {
        log('dropped a malformed line from the engine');
      }
    }
  });

  socket.on('close', () => {
    engine = null;
    sendToChrome({ type: 'error', message: 'Lost the connection to Duck Engine.' });
  });

  socket.on('error', (error) => log(`engine socket error: ${error.message}`));

  const backlog = queued;
  queued = [];
  for (const line of backlog) socket.write(`${line}\n`);
}

/**
 * Starts the engine fully detached.
 *
 * `detached` plus an unref'd handle is what lets it outlive this bridge. Without
 * both, Chrome killing the bridge takes the engine — and every running
 * download — with it.
 */
function startEngine(): void {
  const entry = findEngineEntry();
  if (!entry) {
    log('could not find the engine build; run `npm run build` in engine/');
    return;
  }

  log(`starting the engine: ${entry}`);
  const child = spawn(process.execPath, [entry], {
    detached: true,
    stdio: 'ignore',
    cwd: dirname(entry),
  });
  child.unref();
}

/**
 * Walks up looking for the engine build rather than counting `..` segments.
 *
 * The bridge's own depth changes between a source build and a packaged one, and
 * a hardcoded relative path fails silently — it spawns with a cwd that does not
 * exist and reports only ENOENT.
 */
function findEngineEntry(): string | null {
  const suffix = join('engine', 'dist', 'engine', 'src', 'index.js');

  let directory = here;
  for (let depth = 0; depth < 8; depth++) {
    const candidate = join(directory, suffix);
    if (existsSync(candidate)) return candidate;

    const parent = dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  return null;
}

const sleep = (ms: number) => new Promise((settle) => setTimeout(settle, ms));

log(`ready (protocol ${PROTOCOL_VERSION})`);
