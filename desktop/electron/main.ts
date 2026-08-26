import { app, BrowserWindow, Menu, clipboard, ipcMain, shell } from 'electron';
import Store from 'electron-store';
import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { readExtensionId, registerNativeHost, startEngine } from './engine-host.js';

type DownloadType = 'video' | 'audio';
type DownloadStatus =
  | 'queued'
  | 'downloading'
  | 'processing'
  | 'paused'
  | 'completed'
  | 'failed'
  | 'cancelled';

type DownloadItem = {
  id: string;
  url: string;
  title: string;
  thumbnail?: string | null;
  platform: string;
  quality?: string | null;
  type: DownloadType;
  filePath?: string | null;
  createdAt: string;
  status: DownloadStatus;
  progress: number;
  favorite: boolean;
};

type FileDownloadPayload = {
  url: string;
  filename: string;
  type: DownloadType;
};

type StoreSchema = {
  downloads: DownloadItem[];
};

const currentFile = fileURLToPath(import.meta.url);
const currentDir = path.dirname(currentFile);
const apiBaseUrl =
  loadEnvValue('DUCK_API_BASE_URL') ||
  process.env.DUCK_API_BASE_URL ||
  process.env.VITE_DUCK_API_BASE_URL ||
  'http://localhost:8000';

let mainWindow: BrowserWindow | null = null;
let store: Store<StoreSchema> | null = null;

function getStore() {
  store ??= new Store<StoreSchema>({
    name: 'duck-downloads',
    defaults: {
      downloads: [],
    },
  });
  return store;
}

function loadEnvValue(key: string) {
  const candidates = [
    path.join(process.cwd(), '.env'),
    path.join(currentDir, '../.env'),
    path.join(currentDir, '../../.env'),
  ];
  for (const candidate of candidates) {
    if (!fsSync.existsSync(candidate)) continue;
    const lines = fsSync.readFileSync(candidate, 'utf8').split(/\r?\n/);
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const index = trimmed.indexOf('=');
      if (index <= 0) continue;
      const name = trimmed.slice(0, index).trim();
      if (name !== key) continue;
      return trimmed.slice(index + 1).trim().replace(/^["']|["']$/g, '');
    }
  }
  return null;
}

function userDownloadsPath() {
  return path.join(app.getPath('downloads'), 'Duck Downloader');
}

function sanitizeFilename(value: string) {
  return value.replace(/[<>:"/\\|?*\x00-\x1f]+/g, '_').trim() || 'duck-download';
}

function readDownloads(): DownloadItem[] {
  return getStore().get('downloads', []);
}

function writeDownloads(items: DownloadItem[]) {
  getStore().set('downloads', items);
}

async function upsertDownload(item: DownloadItem) {
  const items = readDownloads();
  const index = items.findIndex((existing) => existing.id === item.id);
  if (index >= 0) {
    items[index] = { ...items[index], ...item };
  } else {
    items.unshift(item);
  }
  writeDownloads(items);
  return item;
}

async function deleteDownload(id: string) {
  const items = readDownloads();
  const item = items.find((download) => download.id === id);
  if (item?.filePath) {
    await fs.rm(item.filePath, { force: true });
  }
  writeDownloads(items.filter((download) => download.id !== id));
  return true;
}

async function downloadRemoteFile(payload: FileDownloadPayload) {
  const response = await fetch(payload.url);
  if (!response.ok || !response.body) {
    throw new Error(`Download failed with status ${response.status}.`);
  }

  const folder = path.join(
    userDownloadsPath(),
    payload.type === 'audio' ? 'Audios' : 'Videos',
  );
  await fs.mkdir(folder, { recursive: true });
  const safeName = sanitizeFilename(payload.filename);
  const filePath = path.join(folder, safeName);
  const buffer = Buffer.from(await response.arrayBuffer());
  await fs.writeFile(filePath, buffer);
  return filePath;
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 430,
    height: 820,
    minWidth: 390,
    minHeight: 720,
    title: 'Duck Downloader',
    backgroundColor: '#101112',
    webPreferences: {
      preload: path.join(currentDir, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  if (process.env.VITE_DEV_SERVER_URL) {
    void mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL);
    mainWindow.webContents.openDevTools({ mode: 'detach' });
  } else {
    void mainWindow.loadFile(path.join(currentDir, '../dist/index.html'));
  }
}

app.whenReady().then(async () => {
  Menu.setApplicationMenu(null);

  // Duck Engine owns downloads. Starting it here means the queue is running
  // before any window appears, and it keeps running after the window closes.
  try {
    startEngine();
    const extensionId = await readExtensionId();
    const written = await registerNativeHost(extensionId);
    console.log(`[duck] engine started; native host registered for ${written.length} browser(s)`);
  } catch (error) {
    console.error('[duck] could not start the engine:', error);
  }

  ipcMain.handle('app:get-api-base-url', () => apiBaseUrl);
  ipcMain.handle('clipboard:read-text', () => clipboard.readText().trim());
  ipcMain.handle('downloads:list', () => readDownloads());
  ipcMain.handle('downloads:save', (_event, item: DownloadItem) => upsertDownload(item));
  ipcMain.handle('downloads:delete', (_event, id: string) => deleteDownload(id));
  ipcMain.handle('files:download-remote', (_event, payload: FileDownloadPayload) =>
    downloadRemoteFile(payload),
  );
  ipcMain.handle('files:open', async (_event, filePath: string) => {
    const result = await shell.openPath(filePath);
    if (result) throw new Error(result);
    return true;
  });
  ipcMain.handle('files:media-src', (_event, filePath: string) =>
    pathToFileURL(filePath).toString(),
  );
  ipcMain.handle('files:reveal', (_event, filePath: string) => {
    shell.showItemInFolder(filePath);
    return true;
  });

  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
