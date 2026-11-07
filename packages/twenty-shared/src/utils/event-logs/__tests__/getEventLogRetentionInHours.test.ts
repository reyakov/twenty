import { EVENT_LOG_RETENTION } from '@/constants/EventLogRetention';
import { getEventLogRetentionInHours } from '@/utils/event-logs/getEventLogRetentionInHours';

describe('getEventLogRetentionInHours', () => {
  it('should use the workspace retention', () => {
    expect(
      getEventLogRetentionInHours({
        workspaceRetentionInDays: 365,
      }),
    ).toBe(365 * 24);
  });

  it('should cap the workspace retention at the maximum retention', () => {
    expect(
      getEventLogRetentionInHours({
        workspaceRetentionInDays: 5000,
      }),
    ).toBe(EVENT_LOG_RETENTION.maxInDays * 24);
  });
});
