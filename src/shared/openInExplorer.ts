/**
 * "Show in Explorer": reveals a server-side file in the file manager of the
 * machine the browser runs on.
 *
 * A page cannot open a local folder by itself — browsers refuse `file://`
 * navigation from an https page. So the link uses a custom URL scheme, and a
 * small handler registered on the user's machine (`public/open-in-explorer/`)
 * maps the server path onto a local folder (usually a synced Nextcloud folder)
 * and selects the file there. The handler only ever reveals, never runs files.
 *
 * The switch is per browser, not a synced preference: the handler is installed
 * per machine, and on a phone or another computer without it the link would do
 * nothing.
 */
import { useCallback, useEffect, useState } from 'react';

export const OPEN_IN_EXPLORER_SCHEME = 'cloudcli-open';

export const OPEN_IN_EXPLORER_STORAGE_KEY = 'openInExplorerEnabled';

/** Emitted on write, so every open consumer in this tab re-reads the switch. */
const SYNC_EVENT = 'open-in-explorer:sync';

/**
 * The whole path is percent-encoded, so the URL reaches the handler's command
 * line with no spaces or quotes left to split or escape it.
 */
export function buildOpenInExplorerUrl(serverPath: string): string {
  return `${OPEN_IN_EXPLORER_SCHEME}:${encodeURIComponent(serverPath)}`;
}

export function launchOpenInExplorer(serverPath: string): void {
  // Navigating to an unhandled scheme leaves the page as it is: the browser
  // either hands the URL to the registered handler or silently drops it.
  window.location.href = buildOpenInExplorerUrl(serverPath);
}

export function readOpenInExplorerEnabled(): boolean {
  try {
    return localStorage.getItem(OPEN_IN_EXPLORER_STORAGE_KEY) === 'true';
  } catch {
    return false;
  }
}

function writeOpenInExplorerEnabled(value: boolean): void {
  try {
    localStorage.setItem(OPEN_IN_EXPLORER_STORAGE_KEY, String(value));
  } catch {
    // Storage blocked: the switch just lasts for this page.
  }
  window.dispatchEvent(new Event(SYNC_EVENT));
}

export function useOpenInExplorerEnabled(): [boolean, (value: boolean) => void] {
  const [enabled, setEnabled] = useState(readOpenInExplorerEnabled);

  useEffect(() => {
    const sync = () => setEnabled(readOpenInExplorerEnabled());
    const onStorage = (event: StorageEvent) => {
      if (event.key === OPEN_IN_EXPLORER_STORAGE_KEY) sync();
    };
    window.addEventListener(SYNC_EVENT, sync);
    window.addEventListener('storage', onStorage);
    return () => {
      window.removeEventListener(SYNC_EVENT, sync);
      window.removeEventListener('storage', onStorage);
    };
  }, []);

  const update = useCallback((value: boolean) => {
    setEnabled(value);
    writeOpenInExplorerEnabled(value);
  }, []);

  return [enabled, update];
}
