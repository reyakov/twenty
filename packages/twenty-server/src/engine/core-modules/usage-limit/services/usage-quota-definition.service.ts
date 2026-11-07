import { Injectable } from '@nestjs/common';

import { type UsageQuotaDefinitionsDTO } from 'src/engine/core-modules/usage-limit/dtos/usage-quota-definitions.dto';
import { UsagePeriodService } from 'src/engine/core-modules/usage-limit/services/usage-period.service';
import { buildQuotaDefinitions } from 'src/engine/core-modules/usage-limit/utils/build-quota-definitions.util';

@Injectable()
export class UsageQuotaDefinitionService {
  constructor(private readonly usagePeriodService: UsagePeriodService) {}

  async findDefinitions(
    workspaceId: string,
  ): Promise<UsageQuotaDefinitionsDTO> {
    const hasAllowancePeriod =
      await this.usagePeriodService.hasAllowancePeriod(workspaceId);

    return {
      definitions: buildQuotaDefinitions(),
      hasAllowancePeriod,
    };
  }
}
