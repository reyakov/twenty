/* @license Enterprise */

import { Test, type TestingModule } from '@nestjs/testing';

import { BillingEntitlementSyncService } from 'src/engine/core-modules/billing-webhook/services/billing-entitlement-sync.service';
import { BillingEntitlementEntity } from 'src/engine/core-modules/billing/entities/billing-entitlement.entity';
import { BillingEntitlementKey } from 'src/engine/core-modules/billing/enums/billing-entitlement-key.enum';
import { CacheLockService } from 'src/engine/core-modules/cache-lock/cache-lock.service';
import { UsageLimitQuotaService } from 'src/engine/core-modules/usage-limit/services/usage-limit-quota.service';
import { getWorkspaceScopedRepositoryToken } from 'src/engine/twenty-orm/workspace-scoped-repository/get-workspace-scoped-repository-token.util';

const WORKSPACE_ID = '20202020-1c25-4d02-bf25-6aeccf7ea419';
const STRIPE_CUSTOMER_ID = 'cus_test';

describe('BillingEntitlementSyncService', () => {
  let service: BillingEntitlementSyncService;

  const billingEntitlementRepository = {
    find: jest.fn(),
    upsert: jest.fn(),
  };

  const usageLimitQuotaService = {
    dropIntraWorkspaceLimitCounters: jest.fn(),
  };

  // A real single-holder lock rather than a pass-through, so a test that runs
  // two syncs concurrently exercises the serialization instead of asserting
  // that a stub was called. Queued rather than spin-waiting so ordering is
  // deterministic.
  const heldLockKeys = new Set<string>();
  const lockQueueByKey = new Map<string, Promise<unknown>>();
  const cacheLockService = {
    withLock: jest.fn(<TResult>(fn: () => Promise<TResult>, key: string) => {
      const runWhenFree = (lockQueueByKey.get(key) ?? Promise.resolve()).then(
        async () => {
          heldLockKeys.add(key);
          try {
            return await fn();
          } finally {
            heldLockKeys.delete(key);
          }
        },
      );

      lockQueueByKey.set(
        key,
        runWhenFree.catch(() => undefined),
      );

      return runWhenFree;
    }),
  };

  const givenStoredEntitlements = (
    entitlements: { key: BillingEntitlementKey; value: boolean }[],
  ) => billingEntitlementRepository.find.mockResolvedValue(entitlements);

  beforeEach(async () => {
    jest.clearAllMocks();
    heldLockKeys.clear();
    lockQueueByKey.clear();
    billingEntitlementRepository.upsert.mockResolvedValue(undefined);
    usageLimitQuotaService.dropIntraWorkspaceLimitCounters.mockResolvedValue(
      undefined,
    );

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        BillingEntitlementSyncService,
        {
          provide: getWorkspaceScopedRepositoryToken(BillingEntitlementEntity),
          useValue: billingEntitlementRepository,
        },
        {
          provide: UsageLimitQuotaService,
          useValue: usageLimitQuotaService,
        },
        {
          provide: CacheLockService,
          useValue: cacheLockService,
        },
      ],
    }).compile();

    service = module.get<BillingEntitlementSyncService>(
      BillingEntitlementSyncService,
    );
  });

  const syncEntitlements = (activeLookupKeys: string[]) =>
    service.syncEntitlements({
      workspaceId: WORKSPACE_ID,
      stripeCustomerId: STRIPE_CUSTOMER_ID,
      activeLookupKeys,
    });

  it('drops usage-limit counters once when two syncs observe the same grant', async () => {
    givenStoredEntitlements([
      { key: BillingEntitlementKey.USAGE_LIMIT, value: false },
    ]);

    // Once the first sync commits, the stored rows read as granted, so the
    // second sync sees no transition. Without the lock both would read the
    // pre-commit state and both would drop, and the later drop would discard
    // usage already recorded under enforcement.
    billingEntitlementRepository.upsert.mockImplementation(async () => {
      givenStoredEntitlements([
        { key: BillingEntitlementKey.USAGE_LIMIT, value: true },
      ]);
    });

    await Promise.all([
      syncEntitlements([BillingEntitlementKey.USAGE_LIMIT]),
      syncEntitlements([BillingEntitlementKey.USAGE_LIMIT]),
    ]);

    expect(
      usageLimitQuotaService.dropIntraWorkspaceLimitCounters,
    ).toHaveBeenCalledTimes(1);
  });

  it('locks on a key scoped to the workspace', async () => {
    givenStoredEntitlements([]);

    const otherWorkspaceId = '20202020-1c25-4d02-bf25-6aeccf7ea420';
    const heldKeysDuringOtherWorkspaceUpsert: string[] = [];

    billingEntitlementRepository.upsert.mockImplementation(async () => {
      heldKeysDuringOtherWorkspaceUpsert.push(...heldLockKeys);
    });

    await Promise.all([
      syncEntitlements([]),
      service.syncEntitlements({
        workspaceId: otherWorkspaceId,
        stripeCustomerId: STRIPE_CUSTOMER_ID,
        activeLookupKeys: [],
      }),
    ]);

    expect(cacheLockService.withLock.mock.calls.map((call) => call[1])).toEqual(
      [
        `billing-entitlement-state:${WORKSPACE_ID}`,
        `billing-entitlement-state:${otherWorkspaceId}`,
      ],
    );

    // Two workspaces hold their own keys at once. A constant key would
    // serialize them and never show both held together.
    expect(new Set(heldKeysDuringOtherWorkspaceUpsert).size).toBe(2);
  });

  it('holds the lock for the whole transition', async () => {
    givenStoredEntitlements([]);

    let lockHeldDuringUpsert = false;

    billingEntitlementRepository.upsert.mockImplementation(async () => {
      lockHeldDuringUpsert = heldLockKeys.size === 1;
    });

    await syncEntitlements([]);

    expect(lockHeldDuringUpsert).toBe(true);
    expect(heldLockKeys.size).toBe(0);
  });
});
