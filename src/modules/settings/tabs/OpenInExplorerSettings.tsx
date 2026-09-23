import { useTranslation } from 'react-i18next';

import { useOpenInExplorerEnabled } from '@/shared/openInExplorer';
import SettingsCard from '@/modules/settings/SettingsCard';
import SettingsRow from '@/modules/settings/SettingsRow';
import SettingsSection from '@/modules/settings/SettingsSection';
import SettingsToggle from '@/modules/settings/SettingsToggle';

// Served from public/, next to the app, so the link works on any deployment.
const INSTALLERS = [
  { key: 'windows', file: 'install-windows.ps1' },
  { key: 'linux', file: 'install-linux.sh' },
] as const;

/** Rendered by AppearanceSettingsTab: the per-browser "Show in Explorer" switch and the handler downloads it depends on. */
export default function OpenInExplorerSettings() {
  const { t } = useTranslation('settings');
  const [enabled, setEnabled] = useOpenInExplorerEnabled();
  const base = import.meta.env.BASE_URL || '/';

  return (
    <SettingsSection title={t('appearanceSettings.openInExplorer.title', 'Show in Explorer')}>
      <SettingsCard divided>
        <SettingsRow
          label={t('appearanceSettings.openInExplorer.label', 'Show files in this computer\'s file manager')}
          description={t(
            'appearanceSettings.openInExplorer.description',
            'Adds "Show in Explorer" to file links in chat and to the file tree menu. Needs the handler installed on this computer; the switch applies to this browser only.',
          )}
        >
          <SettingsToggle
            checked={enabled}
            onChange={setEnabled}
            ariaLabel={t('appearanceSettings.openInExplorer.label', 'Show files in this computer\'s file manager')}
          />
        </SettingsRow>
        <div className="flex flex-wrap gap-x-4 gap-y-1 px-4 py-3 text-sm">
          {INSTALLERS.map(({ key, file }) => (
            <a
              key={key}
              href={`${base}open-in-explorer/${file}`}
              download
              className="text-blue-600 hover:underline dark:text-blue-400"
            >
              {t(`appearanceSettings.openInExplorer.download.${key}`, `Handler for ${key}`)}
            </a>
          ))}
        </div>
      </SettingsCard>
    </SettingsSection>
  );
}
