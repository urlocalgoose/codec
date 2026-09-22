import { writable } from 'svelte/store';

export interface DownloadStatus {
  state: 'downloading' | 'done' | 'error';
  message: string;
  detail?: string;
  progress?: number;
  cancel?: () => void;
}

const status = writable<DownloadStatus | null>(null);
let dismissTimer: ReturnType<typeof setTimeout> | undefined;
export const downloadStatus = {
  subscribe: status.subscribe,
  set(value: DownloadStatus | null) {
    clearTimeout(dismissTimer);
    status.set(value);
    // Results clear themselves; failures remain available until dismissed.
    if (value?.state === 'done') dismissTimer = setTimeout(() => status.set(null), 5_000);
  }
};
