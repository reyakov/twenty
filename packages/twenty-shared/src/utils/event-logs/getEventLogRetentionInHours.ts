import { EVENT_LOG_RETENTION } from '@/constants/EventLogRetention';

export const getEventLogRetentionInHours = ({
  workspaceRetentionInDays,
}: {
  workspaceRetentionInDays: number;
}): number => {
  return Math.min(workspaceRetentionInDays, EVENT_LOG_RETENTION.maxInDays) * 24;
};
