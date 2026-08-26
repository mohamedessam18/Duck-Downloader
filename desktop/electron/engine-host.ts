import { app } from 'electron';
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdir, writeFile, chmod, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

/**
 * Hosting Duck Engine inside the desktop app.
 *
 * The engine and the bridge are plain Node programs, and a packaged Electron app
 * already carries a Node runtime — so they ship inside it rather than asking the
 * user to install Node. `ELECTRON_RUN_AS_NODE` is what turns the app's own
 * binary back into a Node interpreter for those child processes.
 *
 * This module also registers the native-messaging host, because the manifest has
 * to name an absolute path and that path is only known once the app is
 * installed. Registering at build time would bake in whatever directory the
 * machine that built it happened to use.
 */

const HOST_NAME = 'com.duckdownloader.engine';

/**
 * Where the bundled programs live.
 *
 * `extraResources` puts them under `Contents/Resources/duck` in a packaged
 * build; in development they are still in the repository.
 */
function resourceRoot(): string {
  if (app.isPackaged) return path.join(process.resourcesPath, 'duck');
  return path.resolve(app.getAppPath(), '..');
}

function engineEntry(): string {
  return path.join(resourceRoot(), 'engine', 'dist', 'engine', 'src', 'index.js');
}

function bridgeEntry(): string {
  return path.join(resourceRoot(), 'bridge', 'dist', 'bridge', 'src', 'index.js');
}

/** Per-browser locations for native-messaging host manifests on this platform. */
function hostDirectories(): Record<string, string> {
  const home = homedir();

  if (process.platform === 'darwin') {
    const support = path.join(home, 'Library', 'Application Support');
    return {
      Chrome: path.join(support, 'Google', 'Chrome', 'NativeMessagingHosts'),
      Brave: path.join(support, 'BraveSoftware', 'Brave-Browser', 'NativeMessagingHosts'),
      Edge: path.join(support, 'Microsoft Edge', 'NativeMessagingHosts'),
      Chromium: path.join(support, 'Chromium', 'NativeMessagingHosts'),
    };
  }

  if (process.platform === 'linux') {
    const config = process.env.XDG_CONFIG_HOME ?? path.join(home, '.config');
    return {
      Chrome: path.join(config, 'google-chrome', 'NativeMessagingHosts'),
      Brave: path.join(config, 'BraveSoftware', 'Brave-Browser', 'NativeMessagingHosts'),
      Chromium: path.join(config, 'chromium', 'NativeMessagingHosts'),
    };
  }

  return {};
}

/**
 * Writes the launcher the browser will execute.
 *
 * The manifest must point at something the OS runs directly, and a `.js` file is
 * not that. The shim carries `ELECTRON_RUN_AS_NODE` so the app's own binary acts
 * as the interpreter — which is what removes any dependency on a Node install.
 *
 * It goes in the user's data directory rather than inside the app bundle: a
 * signed bundle is read-only, and on macOS writing into it breaks the signature.
 */
async function writeLauncher(): Promise<string> {
  const directory = path.join(app.getPath('userData'), 'bin');
  await mkdir(directory, { recursive: true });

  const target = path.join(directory, process.platform === 'win32' ? 'duck-bridge.cmd' : 'duck-bridge');

  if (process.platform === 'win32') {
    await writeFile(
      target,
      `@echo off\r\nset ELECTRON_RUN_AS_NODE=1\r\n"${process.execPath}" "${bridgeEntry()}" %*\r\n`,
      'utf8',
    );
    return target;
  }

  await writeFile(
    target,
    ['#!/bin/sh', 'export ELECTRON_RUN_AS_NODE=1', `exec "${process.execPath}" "${bridgeEntry()}" "$@"`, ''].join('\n'),
    'utf8',
  );
  await chmod(target, 0o755);
  return target;
}

/**
 * Registers the bridge with every Chromium browser on this machine.
 *
 * Rewritten on every launch on purpose: moving the app to a different folder
 * changes `process.execPath`, and a manifest pointing at the old location fails
 * with nothing but "native host has exited".
 */
export async function registerNativeHost(extensionId: string): Promise<string[]> {
  const launcher = await writeLauncher();

  const manifest = {
    name: HOST_NAME,
    description: 'Duck Engine bridge',
    path: launcher,
    type: 'stdio',
    allowed_origins: [`chrome-extension://${extensionId}/`],
  };

  const written: string[] = [];
  for (const directory of Object.values(hostDirectories())) {
    try {
      await mkdir(directory, { recursive: true });
      const target = path.join(directory, `${HOST_NAME}.json`);
      await writeFile(target, JSON.stringify(manifest, null, 2), 'utf8');
      written.push(target);
    } catch {
      // A browser that is not installed has no directory to write into, and
      // that is not a failure worth surfacing.
    }
  }
  return written;
}

/** Reads the id pinned into the extension's manifest key. */
export async function readExtensionId(): Promise<string> {
  const candidates = [
    path.join(resourceRoot(), 'extension-id.txt'),
    path.resolve(app.getAppPath(), '..', '..', 'extension', 'keys', 'id.txt'),
  ];

  for (const candidate of candidates) {
    if (!existsSync(candidate)) continue;
    const value = (await readFile(candidate, 'utf8')).trim();
    if (value) return value;
  }
  throw new Error('Could not find the extension id to authorise.');
}

let engine: ChildProcess | null = null;

/**
 * Starts the engine, detached.
 *
 * Detached because the engine is the download manager, not a window: quitting
 * the desktop UI should not abandon a transfer that is halfway through. It also
 * means the browser can keep using it after the app is closed.
 *
 * Starting it twice is harmless — the second instance finds the socket already
 * bound and exits.
 */
export function startEngine(): void {
  const entry = engineEntry();
  if (!existsSync(entry)) {
    console.error(`[duck] engine build missing at ${entry}`);
    return;
  }

  engine = spawn(process.execPath, [entry], {
    detached: true,
    stdio: 'ignore',
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
  });
  engine.unref();
  engine = null;
}

export function enginePaths() {
  return { engineEntry: engineEntry(), bridgeEntry: bridgeEntry(), root: resourceRoot() };
}
