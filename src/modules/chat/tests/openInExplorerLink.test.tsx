import assert from 'node:assert/strict';

import { fireEvent, render, screen } from '@testing-library/react';
import { afterEach, test, vi } from 'vitest';

import { OPEN_IN_EXPLORER_STORAGE_KEY, buildOpenInExplorerUrl } from '@/shared/openInExplorer';

/**
 * The "Show in Explorer" button next to a file reference in chat: shown only
 * where the user switched it on (the handler is installed per machine), and
 * handing the reference over without its `:line` suffix.
 */

const openFileInEditor = vi.fn();
const openDirectory = vi.fn();
const openInExplorer = vi.fn();

vi.mock('@/modules/command-palette', () => ({
  usePaletteOps: () => ({ openFileInEditor, openDirectory, openInExplorer }),
}));

const { Markdown } = await import('@/modules/chat/transcript/Markdown');

afterEach(() => {
  localStorage.clear();
  openInExplorer.mockReset();
  openFileInEditor.mockReset();
});

test('no explorer button until the switch is on', () => {
  render(<Markdown>{'See [src/foo.ts](src/foo.ts).'}</Markdown>);
  assert.equal(screen.queryByRole('button', { name: 'Show in Explorer' }), null);
});

test('the button reveals the reference without its line suffix and leaves the editor alone', () => {
  localStorage.setItem(OPEN_IN_EXPLORER_STORAGE_KEY, 'true');
  render(<Markdown>{'See [src/foo.ts:130](src/foo.ts:130).'}</Markdown>);
  fireEvent.click(screen.getByRole('button', { name: 'Show in Explorer' }));
  assert.deepEqual(openInExplorer.mock.calls[0], ['src/foo.ts']);
  assert.equal(openFileInEditor.mock.calls.length, 0);
});

test('external links get no explorer button', () => {
  localStorage.setItem(OPEN_IN_EXPLORER_STORAGE_KEY, 'true');
  render(<Markdown>{'See [docs](https://example.com/a/b.html).'}</Markdown>);
  assert.equal(screen.queryByRole('button', { name: 'Show in Explorer' }), null);
});

test('the URL carries the whole path percent-encoded, so no space or quote reaches the handler command line', () => {
  const url = buildOpenInExplorerUrl('/home/ae00/work/мой "файл" (1).png');
  assert.equal(url.startsWith('cloudcli-open:%2Fhome%2Fae00%2Fwork%2F'), true);
  assert.equal(/[\s"]/.test(url), false);
  assert.equal(decodeURIComponent(url.slice('cloudcli-open:'.length)), '/home/ae00/work/мой "файл" (1).png');
});
