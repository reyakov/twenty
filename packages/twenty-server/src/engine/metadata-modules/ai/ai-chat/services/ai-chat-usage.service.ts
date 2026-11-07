import { Injectable } from '@nestjs/common';

import { isDefined } from 'twenty-shared/utils';

import { type AiChatUsageDTO } from 'src/engine/metadata-modules/ai/ai-chat/dtos/ai-chat-usage.dto';
import { UsageLimitQuotaService } from 'src/engine/core-modules/usage-limit/services/usage-limit-quota.service';
import { WorkspaceCacheService } from 'src/engine/workspace-cache/services/workspace-cache.service';
import { findAiChatCreditLimits } from 'src/engine/metadata-modules/ai/ai-chat/utils/find-ai-chat-credit-limits.util';
import { selectAiChatUsage } from 'src/engine/metadata-modules/ai/ai-chat/utils/select-ai-chat-usage.util';

@Injectable()
export class AiChatUsageService {
  constructor(
    private readonly workspaceCacheService: WorkspaceCacheService,
    private readonly usageLimitQuotaService: UsageLimitQuotaService,
  ) {}

  async findUsage({
    workspaceId,
    userWorkspaceId,
  }: {
    workspaceId: string;
    userWorkspaceId: string;
  }): Promise<AiChatUsageDTO | null> {
    const { usageLimits } = await this.workspaceCacheService.getOrRecompute(
      workspaceId,
      ['usageLimits'],
    );

    const aiChatCreditLimits = findAiChatCreditLimits({
      usageLimits,
      userWorkspaceId,
    });

    if (aiChatCreditLimits.length === 0) {
      const workspaceAllowanceUsage =
        await this.usageLimitQuotaService.getWorkspaceAllowanceUsage(
          workspaceId,
        );

      return isDefined(workspaceAllowanceUsage)
        ? { ...workspaceAllowanceUsage, kind: 'workspaceAllowance' }
        : null;
    }

    const consumptionById =
      await this.usageLimitQuotaService.readLimitConsumptions({
        workspaceId,
        limits: aiChatCreditLimits,
      });

    return selectAiChatUsage({
      limits: aiChatCreditLimits,
      consumptionById,
    });
  }
}
