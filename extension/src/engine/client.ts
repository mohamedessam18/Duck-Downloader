import type {
  EngineEvent,
  EngineRequest,
  EngineResponse,
  JobRecipe,
  JobRecord,
} from '../../../contracts/duck-protocol';
import { PROTOCOL_VERSION } from '../../../contracts/duck-protocol';
import type { MediaFormat } from '@/core/types';
import { log } from '@/core/logger';

/**
 * The extension's connection to Duck Engine.
 *
 * Every download lives in the engine, not here. The MV3 service worker is torn
 * down after about thirty seconds of inactivity, which makes it the worst
 * possible owner of a long transfer — so this class holds no download state at
 * all. It forwards intent one way and renders state the other.
 *
 * The port is long-lived: the engine pushes job updates as they happen, so
 * nothing polls.
 */

const HOST = 'com.duckdownloader.engine';

/** Waiting requests, keyed in arrival order per response kind. */
type Pending = {
  resolve: (response: EngineResponse) => void;
  reject: (error: Error) => void;
};

export type EngineStatus =
  | { connected: true; engineVersion: string; downloadDir: string }
  | { connected: false; reason: string };

class EngineClient {
  private port: chrome.runtime.Port | null = null;
  private queue: Pending[] = [];
  private connecting: Promise<void> | null = null;
  private status: EngineStatus = { connected: false, reason: 'Not connected yet.' };
  private listeners = new Set<(event: EngineEvent) => void>();
  private statusListeners = new Set<(status: EngineStatus) => void>();

  onEvent(listener: (event: EngineEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  onStatus(listener: (status: EngineStatus) => void): () => void {
    this.statusListeners.add(listener);
    listener(this.status);
    return () => this.statusListeners.delete(listener);
  }

  getStatus(): EngineStatus {
    return this.status;
  }

  private setStatus(status: EngineStatus): void {
    this.status = status;
    for (const listener of this.statusListeners) listener(status);
  }

  private async connect(): Promise<void> {
    if (this.port) return;
    if (this.connecting) return this.connecting;

    this.connecting = new Promise<void>((resolve, reject) => {
      let port: chrome.runtime.Port;
      try {
        port = chrome.runtime.connectNative(HOST);
      } catch (error) {
        const reason = 'Duck Engine is not installed on this computer.';
        this.setStatus({ connected: false, reason });
        reject(new Error(reason));
        return;
      }

      port.onMessage.addListener((message: EngineResponse | EngineEvent) => {
        // Events are pushed, not answers to anything — they must not consume a
        // waiting request, or every later reply would be off by one.
        if (isEvent(message)) {
          for (const listener of this.listeners) listener(message);
          return;
        }

        if (message.type === 'hello') {
          this.setStatus({
            connected: true,
            engineVersion: message.engineVersion,
            downloadDir: message.downloadDir,
          });
        }

        this.queue.shift()?.resolve(message);
      });

      port.onDisconnect.addListener(() => {
        const reason =
          chrome.runtime.lastError?.message ?? 'Duck Engine closed the connection.';
        this.port = null;
        this.setStatus({ connected: false, reason: friendly(reason) });

        for (const pending of this.queue.splice(0)) pending.reject(new Error(friendly(reason)));
        log.warn('engine port closed:', reason);
      });

      this.port = port;

      // The handshake doubles as the connectivity check: a native host that is
      // missing or misconfigured fails here rather than on the first download.
      this.request({ type: 'hello', protocolVersion: PROTOCOL_VERSION, client: 'extension' })
        .then(() => resolve())
        .catch(reject);
    }).finally(() => {
      this.connecting = null;
    });

    return this.connecting;
  }

  private request(request: EngineRequest): Promise<EngineResponse> {
    return new Promise((resolve, reject) => {
      if (!this.port) {
        reject(new Error('Not connected to Duck Engine.'));
        return;
      }
      this.queue.push({ resolve, reject });
      this.port.postMessage(request);
    });
  }

  private async send(request: EngineRequest): Promise<EngineResponse> {
    await this.connect();
    const response = await this.request(request);
    if (response.type === 'error') throw new Error(response.message);
    return response;
  }

  async submit(recipe: JobRecipe): Promise<string> {
    const response = await this.send({ type: 'submit', recipe });
    return response.type === 'accepted' ? response.jobId : '';
  }

  async submitBundle(recipes: JobRecipe[]): Promise<number> {
    await this.send({ type: 'submitBundle', recipes });
    return recipes.length;
  }

  async list(): Promise<JobRecord[]> {
    const response = await this.send({ type: 'list' });
    return response.type === 'jobs' ? response.jobs : [];
  }

  pause(jobId: string) { return this.send({ type: 'pause', jobId }); }
  resume(jobId: string) { return this.send({ type: 'resume', jobId }); }
  cancel(jobId: string) { return this.send({ type: 'cancel', jobId }); }
  remove(jobId: string) { return this.send({ type: 'remove', jobId }); }
  retry(jobId: string) { return this.send({ type: 'retry', jobId }); }
  reveal(jobId: string) { return this.send({ type: 'reveal', jobId }); }

  /**
   * Hands the engine a newly captured URL for a job whose link expired. The
   * engine keeps the bytes it already has and only changes where it reads from.
   */
  async refreshedSource(jobId: string, format: MediaFormat, capturedAt: number): Promise<void> {
    await this.send({
      type: 'refreshedSource',
      jobId,
      capturedAt,
      variant: {
        id: format.id,
        label: format.label,
        kind: format.kind,
        container: format.ext,
        url: format.url,
        audioUrl: format.audioUrl,
        width: format.width,
        height: format.height,
        bitrate: format.bitrate,
        size: format.filesize,
      },
    });
  }

  /** Probes the connection without changing anything. */
  async check(): Promise<EngineStatus> {
    try {
      await this.connect();
    } catch {
      /* status was already set by connect */
    }
    return this.status;
  }
}

function isEvent(message: EngineResponse | EngineEvent): message is EngineEvent {
  return (
    message.type === 'jobUpdated' ||
    message.type === 'jobRemoved' ||
    message.type === 'needSource'
  );
}

/**
 * Chrome's native-messaging errors are written for developers. These are the
 * two the user can actually act on, so they get a sentence that says what to do.
 */
function friendly(reason: string): string {
  if (/not found|no such native/i.test(reason)) {
    return 'Duck Engine is not installed. Install it to download outside the browser.';
  }
  if (/forbidden|access to the specified native/i.test(reason)) {
    return 'Duck Engine refused this extension. Reinstall the engine to reconnect it.';
  }
  return reason;
}

export const engine = new EngineClient();
