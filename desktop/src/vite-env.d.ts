/// <reference types="vite/client" />

export type DownloadType = 'video' | 'audio';

export type DownloadStatus =
  | 'queued'
  | 'downloading'
  | 'processing'
  | 'paused'
  | 'completed'
  | 'failed'
  | 'cancelled';

export type DownloadItem = {
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

type RemoteFilePayload = {
  url: string;
  filename: string;
  type: DownloadType;
};

declare global {
  interface Window {
    duckDesktop: {
      getApiBaseUrl(): Promise<string>;
      readClipboard(): Promise<string>;
      getDownloads(): Promise<DownloadItem[]>;
      saveDownload(item: DownloadItem): Promise<DownloadItem>;
      deleteDownload(id: string): Promise<boolean>;
      downloadRemoteFile(payload: RemoteFilePayload): Promise<string>;
      getMediaSource(filePath: string): Promise<string>;
      openFile(filePath: string): Promise<boolean>;
      revealFile(filePath: string): Promise<boolean>;
    };
  }
}
