import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { mkdirSync } from 'node:fs';

/**
 * Where Duck keeps its state.
 *
 * Config, job records and partial downloads are separated on purpose: partials
 * can be large and are safe to delete, while the job database is small and must
 * survive. Keeping them apart means "clear space" never means "lose the queue".
 */

const APP = 'DuckDownloader';

function base(): string {
  if (process.platform === 'darwin') {
    return join(homedir(), 'Library', 'Application Support', APP);
  }
  if (process.platform === 'win32') {
    return join(process.env.APPDATA ?? join(homedir(), 'AppData', 'Roaming'), APP);
  }
  return join(process.env.XDG_DATA_HOME ?? join(homedir(), '.local', 'share'), APP);
}

export const DATA_DIR = base();
export const JOBS_FILE = join(DATA_DIR, 'jobs.json');
export const SETTINGS_FILE = join(DATA_DIR, 'settings.json');
export const TOKEN_FILE = join(DATA_DIR, 'engine.token');
export const PARTS_DIR = join(DATA_DIR, 'partials');

/**
 * The socket the extension and desktop UI connect to.
 *
 * A named pipe on Windows and a Unix socket elsewhere — never a TCP port. A
 * listening port is reachable by anything on the machine and, misconfigured, by
 * the network; neither of those should ever be true of a download engine.
 */
export function socketPath(): string {
  if (process.platform === 'win32') return '\\\\.\\pipe\\duck-engine';
  // Not in DATA_DIR: macOS caps socket paths at ~104 bytes and
  // "Library/Application Support/..." eats most of that.
  return join(tmpdir(), `duck-engine-${process.getuid?.() ?? 0}.sock`);
}

export function defaultDownloadDir(): string {
  return join(homedir(), 'Downloads', 'Duck Downloader');
}

export function ensureDirs(): void {
  for (const dir of [DATA_DIR, PARTS_DIR]) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
}
