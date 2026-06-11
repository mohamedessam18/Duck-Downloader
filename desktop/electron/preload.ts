import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('duckDesktop', {
  getApiBaseUrl: () => ipcRenderer.invoke('app:get-api-base-url'),
  readClipboard: () => ipcRenderer.invoke('clipboard:read-text'),
  getDownloads: () => ipcRenderer.invoke('downloads:list'),
  saveDownload: (item: unknown) => ipcRenderer.invoke('downloads:save', item),
  deleteDownload: (id: string) => ipcRenderer.invoke('downloads:delete', id),
  downloadRemoteFile: (payload: unknown) =>
    ipcRenderer.invoke('files:download-remote', payload),
  getMediaSource: (filePath: string) =>
    ipcRenderer.invoke('files:media-src', filePath),
  openFile: (filePath: string) => ipcRenderer.invoke('files:open', filePath),
  revealFile: (filePath: string) => ipcRenderer.invoke('files:reveal', filePath),
});
