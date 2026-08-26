import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { DEFAULT_SETTINGS, type EngineSettings } from '../../contracts/duck-protocol.js';
import { SETTINGS_FILE, defaultDownloadDir } from './paths.js';

let cache: EngineSettings | null = null;

export async function getSettings(): Promise<EngineSettings> {
  if (cache) return cache;
  try {
    const raw = await readFile(SETTINGS_FILE, 'utf8');
    cache = { ...DEFAULT_SETTINGS, ...(JSON.parse(raw) as Partial<EngineSettings>) };
  } catch {
    cache = { ...DEFAULT_SETTINGS };
  }
  if (!cache.downloadDir) cache.downloadDir = defaultDownloadDir();
  return cache;
}

export async function updateSettings(patch: Partial<EngineSettings>): Promise<EngineSettings> {
  const next = { ...(await getSettings()), ...patch };
  cache = next;
  await mkdir(dirname(SETTINGS_FILE), { recursive: true });
  await writeFile(SETTINGS_FILE, JSON.stringify(next, null, 2), { mode: 0o600 });
  return next;
}
