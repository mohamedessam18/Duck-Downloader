import { createServer, type Server, type Socket } from 'node:net';
import { randomBytes } from 'node:crypto';
import { readFile, writeFile, chmod, unlink } from 'node:fs/promises';
import {
  PROTOCOL_VERSION,
  type EngineEvent,
  type EngineRequest,
  type EngineResponse,
} from '../../contracts/duck-protocol.js';
import { TOKEN_FILE, socketPath } from './paths.js';

/**
 * The local control socket.
 *
 * A Unix socket or a Windows named pipe, never a TCP port — a listening port is
 * reachable by every process on the machine and, behind a careless firewall
 * rule, from the network. Nothing about a download engine should be reachable
 * from the network.
 *
 * On Unix the socket file's own permissions already restrict it to this user.
 * Windows named pipes have no equivalent, so a shared secret is required from
 * every client and checked on the first message. Requiring it on both platforms
 * keeps one code path instead of two.
 *
 * Messages are newline-delimited JSON. Every connection may receive pushed
 * events, so no client ever has to poll.
 */

export type RequestHandler = (
  request: EngineRequest,
  client: ClientHandle,
) => Promise<EngineResponse>;

export interface ClientHandle {
  id: string;
  authenticated: boolean;
  send(event: EngineEvent): void;
}

export class EngineServer {
  private server: Server | null = null;
  private clients = new Set<ClientConnection>();

  constructor(private readonly handle: RequestHandler) {}

  async listen(): Promise<string> {
    const token = await ensureToken();
    const path = socketPath();

    // A socket file left behind by a crash would block binding.
    if (process.platform !== 'win32') await unlink(path).catch(() => undefined);

    this.server = createServer((socket) => this.accept(socket, token));

    await new Promise<void>((resolve, reject) => {
      this.server!.once('error', reject);
      this.server!.listen(path, () => resolve());
    });

    if (process.platform !== 'win32') await chmod(path, 0o600).catch(() => undefined);
    return path;
  }

  private accept(socket: Socket, token: string): void {
    const connection = new ClientConnection(socket, token, this.handle, () =>
      this.clients.delete(connection),
    );
    this.clients.add(connection);
  }

  /** Pushes to every authenticated client — the extension and the desktop UI. */
  broadcast(event: EngineEvent): void {
    for (const client of this.clients) client.send(event);
  }

  async close(): Promise<void> {
    for (const client of this.clients) client.destroy();
    this.clients.clear();
    await new Promise<void>((resolve) => this.server?.close(() => resolve()) ?? resolve());
    if (process.platform !== 'win32') await unlink(socketPath()).catch(() => undefined);
  }
}

class ClientConnection implements ClientHandle {
  readonly id = randomBytes(6).toString('hex');
  authenticated = false;
  private buffer = '';

  constructor(
    private readonly socket: Socket,
    private readonly token: string,
    private readonly handle: RequestHandler,
    private readonly onClose: () => void,
  ) {
    socket.setNoDelay(true);
    socket.setEncoding('utf8');
    socket.on('data', (chunk: string) => this.onData(chunk));
    socket.on('error', () => this.destroy());
    socket.on('close', () => this.onClose());
  }

  private onData(chunk: string): void {
    this.buffer += chunk;

    // A single message must never be able to exhaust memory.
    if (this.buffer.length > 8 * 1024 * 1024) {
      this.destroy();
      return;
    }

    let newline: number;
    while ((newline = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (line) void this.dispatch(line);
    }
  }

  private async dispatch(line: string): Promise<void> {
    let message: EngineRequest & { token?: string };
    try {
      message = JSON.parse(line);
    } catch {
      this.reply({ type: 'error', message: 'Malformed message.' });
      return;
    }

    if (!this.authenticated) {
      // The first message must be a hello carrying the shared secret.
      if (message.type !== 'hello' || message.token !== this.token) {
        this.reply({ type: 'error', message: 'Not authorised.' });
        this.destroy();
        return;
      }
      if (message.protocolVersion !== PROTOCOL_VERSION) {
        this.reply({
          type: 'error',
          message: `Duck Engine speaks protocol ${PROTOCOL_VERSION}, this client speaks ${message.protocolVersion}. Update both to the same version.`,
        });
        this.destroy();
        return;
      }
      this.authenticated = true;
    }

    try {
      this.reply(await this.handle(message, this));
    } catch (error) {
      this.reply({
        type: 'error',
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private reply(response: EngineResponse): void {
    this.write(response);
  }

  send(event: EngineEvent): void {
    if (!this.authenticated) return;
    this.write(event);
  }

  private write(payload: unknown): void {
    if (this.socket.destroyed) return;
    this.socket.write(`${JSON.stringify(payload)}\n`);
  }

  destroy(): void {
    this.socket.destroy();
    this.onClose();
  }
}

/** Created once, readable only by this user, and reused across restarts. */
async function ensureToken(): Promise<string> {
  try {
    const existing = (await readFile(TOKEN_FILE, 'utf8')).trim();
    if (existing.length >= 32) return existing;
  } catch {
    /* first run */
  }

  const token = randomBytes(32).toString('hex');
  await writeFile(TOKEN_FILE, token, { mode: 0o600 });
  return token;
}

export async function readToken(): Promise<string> {
  return (await readFile(TOKEN_FILE, 'utf8')).trim();
}
