import { APPLICATION_MONITORING_RETENTION_IN_DAYS } from 'twenty-shared/constants';

export const getApplicationMonitoringLookbackInHours = (): number =>
  APPLICATION_MONITORING_RETENTION_IN_DAYS * 24;
