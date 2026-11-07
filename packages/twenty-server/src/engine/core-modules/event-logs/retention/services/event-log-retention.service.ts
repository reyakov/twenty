/* @license Enterprise */

import { Injectable } from '@nestjs/common';

import { getEventLogRetentionInHours } from 'twenty-shared/utils';

@Injectable()
export class EventLogRetentionService {
  getRetentionInHours({
    workspaceRetentionInDays,
  }: {
    workspaceRetentionInDays: number;
  }): number {
    return getEventLogRetentionInHours({ workspaceRetentionInDays });
  }

  getRetentionStartDate({
    workspaceRetentionInDays,
  }: {
    workspaceRetentionInDays: number;
  }): Date {
    const retentionInHours = this.getRetentionInHours({
      workspaceRetentionInDays,
    });

    return new Date(Date.now() - retentionInHours * 60 * 60 * 1000);
  }
}
