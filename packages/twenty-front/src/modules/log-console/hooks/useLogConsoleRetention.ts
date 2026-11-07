import { plural } from '@lingui/core/macro';
import { useLingui } from '@lingui/react/macro';
import { EVENT_LOG_RETENTION } from 'twenty-shared/constants';
import { getEventLogRetentionInHours } from 'twenty-shared/utils';

import { currentWorkspaceState } from '@/auth/states/currentWorkspaceState';
import { useAtomStateValue } from '@/ui/utilities/state/jotai/hooks/useAtomStateValue';

export const useLogConsoleRetention = () => {
  const { t } = useLingui();
  const currentWorkspace = useAtomStateValue(currentWorkspaceState);

  const retentionInHours = getEventLogRetentionInHours({
    workspaceRetentionInDays:
      currentWorkspace?.eventLogRetentionDays ??
      EVENT_LOG_RETENTION.defaultInDays,
  });

  const retentionInDays = retentionInHours / 24;

  const retentionLabel =
    retentionInHours < 24
      ? plural(retentionInHours, { one: '# hour', other: '# hours' })
      : plural(retentionInDays, { one: '# day', other: '# days' });

  return {
    retentionInHours,
    retentionLabel,
    retentionDescription: t`Logs are kept ${retentionLabel}.`,
  };
};
