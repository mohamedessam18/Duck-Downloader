import {
  PROTOCOL_VERSION,
  type EngineRequest,
  type EngineResponse,
} from '../../contracts/duck-protocol.js';
import { JobStore } from './store.js';
import { Runner } from './runner.js';
import { EngineServer } from './server.js';
import { ensureDirs } from './paths.js';
import { getSettings, updateSettings } from './settings.js';

/**
 * Duck Engine.
 *
 * A long-running local process. It is deliberately *not* the native-messaging
 * host: Chrome kills a native-messaging host when the port closes or the
 * browser quits, which would end every download the moment the user closed a
 * window. The bridge is a separate, disposable process that forwards to this
 * one over the local socket.
 */

const VERSION = '0.1.0';

async function main(): Promise<void> {
  ensureDirs();

  const store = new JobStore();
  await store.load();

  let server: EngineServer;

  const runner = new Runner(store, (event) => server.broadcast(event));

  server = new EngineServer(async (request): Promise<EngineResponse> => {
    switch (request.type) {
      case 'hello': {
        const settings = await getSettings();
        return {
          type: 'hello',
          protocolVersion: PROTOCOL_VERSION,
          engineVersion: VERSION,
          downloadDir: settings.downloadDir,
        };
      }

      case 'submit': {
        const job = await runner.submit(request.recipe);
        return { type: 'accepted', jobId: job.id };
      }

      case 'submitBundle': {
        let first = '';
        for (const recipe of request.recipes) {
          const job = await runner.submit(recipe);
          first ||= job.id;
        }
        return { type: 'accepted', jobId: first };
      }

      case 'list':
        return { type: 'jobs', jobs: store.all() };

      case 'pause':
        await runner.pause(request.jobId);
        return { type: 'ok' };

      case 'resume':
      case 'retry':
        await runner.resume(request.jobId);
        return { type: 'ok' };

      case 'cancel':
        await runner.cancel(request.jobId);
        return { type: 'ok' };

      case 'remove':
        await runner.remove(request.jobId);
        return { type: 'ok' };

      case 'refreshedSource':
        await runner.refreshedSource(request.jobId, request.variant, request.capturedAt);
        return { type: 'ok' };

      case 'reveal': {
        const job = store.get(request.jobId);
        if (!job?.finalPath) return { type: 'error', message: 'That file is not on disk yet.' };
        await reveal(job.finalPath);
        return { type: 'ok' };
      }

      case 'settings':
        return { type: 'settings', settings: await getSettings() };

      case 'updateSettings':
        return { type: 'settings', settings: await updateSettings(request.patch) };

      default:
        return { type: 'error', message: `Unknown request: ${(request as { type: string }).type}` };
    }
  });

  const path = await server.listen();
  console.error(`[duck-engine] ${VERSION} listening on ${path}`);

  // Anything mid-flight when the process last died is stranded until this runs.
  await runner.recover();
  void runner.pump();

  const shutdown = async () => {
    console.error('[duck-engine] shutting down');
    await store.flush();
    await server.close();
    process.exit(0);
  };

  process.on('SIGINT', () => void shutdown());
  process.on('SIGTERM', () => void shutdown());
}

async function reveal(path: string): Promise<void> {
  const { spawn } = await import('node:child_process');
  const command =
    process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'explorer' : 'xdg-open';
  spawn(command, process.platform === 'darwin' ? ['-R', path] : [path], {
    detached: true,
    stdio: 'ignore',
  }).unref();
}

main().catch((error: unknown) => {
  console.error('[duck-engine] failed to start:', error);
  process.exit(1);
});
