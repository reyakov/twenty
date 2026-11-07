import { APPLICATION_MONITORING_RETENTION_IN_DAYS } from 'twenty-shared/constants';

import { getApplicationMonitoringLookbackInHours } from 'src/engine/core-modules/application/application-monitoring/utils/get-application-monitoring-lookback-in-hours.util';

describe('getApplicationMonitoringLookbackInHours', () => {
  it('returns the full monitoring retention', () => {
    expect(getApplicationMonitoringLookbackInHours()).toBe(
      APPLICATION_MONITORING_RETENTION_IN_DAYS * 24,
    );
  });
});
