# Plan: un-gate row-level permissions and add "creator-only" record visibility

## Goals

1. Remove the Enterprise license gate from row-level permissions (RLS) so the feature
   (record-level permission predicates/groups) works on every plan.
2. Make it possible to restrict a member to only the records they created ("own records
   only"), instead of all records.

## Status

- Phase 1 (server gate removal): implemented. Includes the billing-sync cleanup removal found during
  implementation (see below). Not yet verified by typecheck/tests - the workspace has no
  `node_modules` installed and the sandbox blocks the network.
- Phase 2 (front-end gate removal): implemented. Same verification caveat: no `node_modules`,
  and no front-end test/snapshot referenced the removed "Upgrade" card (only Lingui catalogs did,
  which are intentionally left untouched).
- Phase 3 (creator-only visibility): implemented through the existing RLS pipeline, no new backend
  concept and no backend code change. Two product decisions were defaulted rather than answered (see
  "Decisions taken" below): the filter-builder route only (no one-click preset), and records with no
  user creator are hidden. Same verification caveat: no `node_modules`.
- Phases 4-5: not started.

## What exists today

The runtime enforcement is **not** license-gated today. Any predicate rows that exist in
metadata are compiled into SQL and applied on reads/writes via:

- `packages/twenty-server/src/engine/twenty-orm/repository/workspace-repository.ts`
  -> `applyRowLevelPermissionPredicates()` / `onBeforeExecute()`
- `packages/twenty-server/src/engine/twenty-orm/utils/build-row-level-permission-record-filter.util.ts`
- `packages/twenty-server/src/engine/twenty-orm/utils/build-row-access-policy.util.ts`
- Predicates are loaded into the per-user permission map unconditionally in
  `packages/twenty-server/src/engine/metadata-modules/role/services/workspace-roles-permissions-cache.service.ts` (approx. line 208).

The gate exists only at two boundaries:

| Boundary | Location | Behavior when not entitled |
|---|---|---|
| Server metadata API (read) | `RowLevelPermissionPredicateService.findByWorkspaceId/findByRoleAndObject/findById`, `RowLevelPermissionPredicateGroupService.*` | returns `[]` / `null` |
| Server metadata API (write) | `RowLevelPermissionPredicateService.upsertRowLevelPermissionPredicates` -> `hasRowLevelPermissionFeatureOrThrow` | throws `ROW_LEVEL_PERMISSION_FEATURE_DISABLED` |
| Front-end UI | `SettingsRolePermissionsObjectLevelObjectForm.tsx` (approx. line 61) computes `isRLSBillingEntitlementEnabled`; `SettingsRolePermissionsObjectLevelRecordLevelSection.tsx` renders an "Upgrade" card when false | no editor |

The server check is
`enterprisePlanService.isValid() && billingService.hasEntitlement(workspaceId, BillingEntitlementKey.RLS)`
and is duplicated in both RLS services
(`row-level-permission-predicate.service.ts`,
`row-level-permission-predicate-group.service.ts`).

A third server-side gate exists outside the metadata API:
`packages/twenty-server/src/engine/core-modules/billing-webhook/services/billing-entitlement-sync.service.ts`
deletes every predicate group for a workspace whenever the RLS entitlement is not granted
(`deleteAllRowLevelPermissionPredicateGroups`), on every billing sync pass. Left in place, it
would silently wipe predicates created by a now-un-entitled workspace. It must be removed
together with the two service checks.

The front-end read path is `role.resolver.ts` -> `getRowLevelPermissionPredicatesForRole`
-> `findByWorkspaceId`, which returns `[]` when not entitled. This is why removing the
front-end gate alone is insufficient.

### Gap for "creator-only" visibility

The model already supports "field *is* current workspace member" through
`RowLevelPermissionPredicate.workspaceMemberFieldMetadataId` + `subFieldName`, and the
backend resolves it:

- `packages/twenty-server/src/engine/twenty-orm/utils/resolve-row-level-permission-record-filter.util.ts`
- `packages/twenty-server/src/engine/twenty-orm/utils/resolve-workspace-member-predicate-value.util.ts`

However, the RLS filter builder only accepts field types listed in
`packages/twenty-front/src/modules/settings/roles/role-permissions/object-level-permissions/record-level-permissions/constants/RecordLevelPermissionPredicateFieldTypes.ts`,
which **excludes `ACTOR`**. As a result, `createdBy is Me` cannot be authored through the
UI, even though normal view filters support `ACTOR` / `workspaceMemberId`
(`ObjectFilterDropdownActorSelect.tsx`, `isFilterOnActorWorkspaceMemberSubField.ts`).

Everything downstream of authoring already works for `ACTOR` and needed no change. Verified by
reading the code rather than running it:

- `getFilterTypeFromFieldType(ACTOR)` returns `'ACTOR'` and `getRecordFilterOperands` returns
  `IS / IS_NOT / IS_EMPTY / IS_NOT_EMPTY` for the `workspaceMemberId` sub-field.
- `createdBy` is not a hidden system field, so it is already in
  `availableFieldMetadataItemsForFilter`; only the RLS allow-list excluded it.
- Composite sub-field navigation already lists `workspaceMemberId` (label "Workspace Member").
- `validateRowLevelPermissionRuleOwnershipOrThrow` only checks that
  `workspaceMemberFieldMetadataId` belongs to the WorkspaceMember object; it does not restrict the
  target field type, so `ACTOR` targets pass.
- `validatePredicateValueCompatibility` returns `true` for a `UUID` WorkspaceMember field against an
  `ACTOR` target (neither the relation-not-target nor the enum-value check applies).
- `turnRecordFilterIntoGqlOperationFilter` compiles `ACTOR` + `workspaceMemberId` + operand `IS` to
  `{ createdBy: { workspaceMemberId: { in: [<uuid>] } } }`. The RLS resolver emits a bare UUID for a
  WorkspaceMember `id` binding, which the schema's `.catch` path coerces into a one-element array.

## Action plan

### Phase 1 - Remove the server-side entitlement gate

1. `packages/twenty-server/src/engine/metadata-modules/row-level-permission-predicate/services/row-level-permission-predicate.service.ts`
   - Delete `hasRowLevelPermissionFeature()` / `hasRowLevelPermissionFeatureOrThrow()`.
   - Remove the early-return checks in `findByWorkspaceId`, `findByRoleAndObject`,
     `findById`; remove the throw in `upsertRowLevelPermissionPredicates`.
   - Drop `BillingService` + `EnterprisePlanService` constructor deps and unused imports.
2. `packages/twenty-server/src/engine/metadata-modules/row-level-permission-predicate/services/row-level-permission-predicate-group.service.ts`
   - Same removal.
3. `packages/twenty-server/src/engine/metadata-modules/row-level-permission-predicate/row-level-permission.module.ts`
   - Drop `BillingModule` and `EnterpriseModule` imports if no longer needed.
4. Remove the dead `ROW_LEVEL_PERMISSION_FEATURE_DISABLED` code from both exception enums,
   their user-friendly messages, and
   `row-level-permission-predicate-graphql-api-exception-handler.util.ts`
   (+ its spec). The `switch`es use `assertUnreachable`, so leaving the codes would keep
   dead branches compiling.
5. Drop the entitlement-triggered predicate cleanup in
   `packages/twenty-server/src/engine/core-modules/billing-webhook/services/billing-entitlement-sync.service.ts`
   (the `if (!isGranted(BillingEntitlementKey.RLS)) { ... }` block), its
   `RowLevelPermissionPredicateGroupService` dependency, and the `RowLevelPermissionModule`
   import in `billing-webhook.module.ts`. This also makes
   `deleteAllRowLevelPermissionPredicateGroups` dead; remove it and its now-unused repository
   injection from the group service, and update the billing-sync spec accordingly.
6. `packages/twenty-docs/developers/extend/apps/config/roles.mdx`
   - Drop the "without the entitlement ... rejected with `ROW_LEVEL_PERMISSION_FEATURE_DISABLED`" note,
     and the claim that row-level security is only enforced on the Organization plan or above.

### Phase 2 - Remove the front-end gate

1. `packages/twenty-front/src/modules/settings/roles/role-permissions/object-level-permissions/object-form/components/SettingsRolePermissionsObjectLevelObjectForm.tsx`
   - Delete `isRLSBillingEntitlementEnabled`, the `BillingEntitlement` / `BillingEntitlementKey`
     imports, and the `hasOrganizationPlan` prop passed to the record-level section.
2. `packages/twenty-front/src/modules/settings/roles/role-permissions/object-level-permissions/record-level-permissions/components/SettingsRolePermissionsObjectLevelRecordLevelSection.tsx`
   - Delete the `hasOrganizationPlan` branch and now-unused imports (`Card`,
     `SettingsOptionCardContentButton`, `OrganizationAdornment`, `Button`, `IconArrowUp`,
     `IconLock`, `billingState`, `useAtomStateValue`, `useNavigateSettings`, `SettingsPath`).
3. Check for snapshots/tests asserting the "Upgrade to access" card.

### Phase 3 - Deliver "only the creator sees their record"

Implemented by reusing the existing RLS pipeline (no new backend concept, **no server change at
all**). What actually landed:

1. `.../record-level-permissions/constants/RecordLevelPermissionPredicateFieldTypes.ts`
   - Added `FieldMetadataType.ACTOR`. This alone makes `createdBy` / `updatedBy` selectable in the
     role record-level field menu. It does **not** change the default filter field: `ACTOR` is
     composite, and defaults skip composites.
2. `.../components/SettingsRolePermissionsObjectLevelRecordLevelPermissionMeValueSelect.tsx`
   - `"Me (User ID)"` is now offered when the selected field is `ACTOR` **and** its sub-field is
     `workspaceMemberId`, not only for relations to `WorkspaceMember`. The binding is identical:
     `workspaceMemberFieldMetadataId` = the WorkspaceMember `id` field, `workspaceMemberSubFieldName`
     = `null`. Reused `isFilterOnActorWorkspaceMemberSubField` rather than re-deriving the sub-field
     name.
3. `.../hooks/useBuildRecordInputFromRLSPredicates.ts`
   - Predicates on `isSystem` fields are dropped before they can be turned into create defaults.
     **This is the trap the original plan missed**: a `createdBy` predicate would otherwise be
     merged into the record input as `createdBy: { workspaceMemberId: <id> }`, which the create
     input rejects or would let a client overwrite the actor the server computed. The server always
     writes `createdBy` itself, so no creator-only rule needs a prefill. This also fixes the same
     latent problem for `createdAt` / `updatedAt` predicates.

Steps from the original plan that turned out to be unnecessary: extending the allow-list in
`useRecordLevelPermissionFilterActions.ts` (covered by the constant), teaching
`getComparableWorkspaceMemberRelationFields` about `ACTOR` (the `ACTOR` path binds the WorkspaceMember
`id` directly, so the relation-compatibility search is not involved), and any change to
`recordLevelPermissionPredicateConversion.ts`, the backend compatibility validator, or
`useFilteredSelectOptionsFromRLSPredicates.ts` (select-only).

Admin flow to author a creator-only rule: *Add filter* -> field *Created by* -> sub-field
*Workspace Member* -> variable picker (*Me*) -> **Me (User ID)**.

Optional and **not implemented** (still a product decision): a one-click preset, e.g. "Only records
they created", that seeds the same predicate.

### Phase 4 - Tests

- Server unit: done in Phase 1 - the feature-disabled assertion in
  `row-level-permission-predicate-graphql-api-exception-handler.util.spec.ts` is gone, and the
  billing-sync spec no longer stubs the removed group service.
- Server integration: keep the existing suites
  (`test/integration/metadata/suites/row-level-permission-predicate/*`,
  `.../object-records-permissions/record-level-permissions-on-relation.integration-spec.ts`);
  add a case that upsert succeeds with `EnterprisePlanService.isValid` mocked false and the
  RLS entitlement absent.
- Front-end: add a test asserting the record-level editor renders (no "Upgrade" card); a conversion
  test for an `ACTOR` field + `workspaceMemberId` + "Me" round-tripping through
  `recordLevelPermissionPredicateConversion`; and a test that
  `useBuildRecordInputFromRLSPredicates` ignores a predicate on a system field.
- Backend compilation: assert that an `ACTOR` / `workspaceMemberId` predicate bound to the current
  member compiles to `{ <actorField>: { workspaceMemberId: { in: [<memberId>] } } }` in
  `build-row-level-permission-record-filter.util`'s output.
- End-to-end: create records as two members, confirm each sees only their own.

### Phase 5 - Cleanup

- Keep `BillingEntitlementKey.RLS` (still referenced by billing catalog / plan definitions).
- Decide on the `/* @license Enterprise */` headers across the RLS files: they are legal
  markers, not a runtime gate. Removing them is a licensing/legal call, not a technical one.
  Phase 3 added no new `@license` headers, but the files it touched already carry them
  (`...RecordLevelPermissionMeValueSelect.tsx`, `useBuildRecordInputFromRLSPredicates.ts`).
- Do **not** commit regenerated Lingui catalogs unless translation is part of the task
  (house rule).

## Risks / open questions

- **Intent check:** removing the gate makes RLS free for every workspace. That is a
  pricing/legal decision, not just a code change.
- **`createdBy` semantics:** records created by API keys/automation may have
  `source != MANUAL` or no `workspaceMemberId`. A creator-only rule hides those rows; that is the
  default taken (see "Decisions taken"). Revisit if integration-created data must stay visible.
- **Lockout risk:** an over-broad predicate can hide everything for a role. The engine
  already defends against unsatisfiable member-bound predicates, but UX warnings may be
  worth adding.
- **Unused-import fallout** in the two services and the module; run typecheck/lint after edits.

## Verification commands

```bash
npx tsgo -p packages/twenty-server/tsconfig.json --noEmit
npx tsgo -p packages/twenty-front/tsconfig.json --noEmit
npx jest packages/twenty-server/src/engine/metadata-modules/row-level-permission-predicate \
  --config=packages/twenty-server/jest.config.mjs
npx nx run twenty-server:test:integration:with-db-reset   # scoped to RLS suites
npx nx lint:diff-with-main twenty-server
npx nx lint:diff-with-main twenty-front
```

All of Phase 1-3 is still unverified: the workspace has no `node_modules` and no Yarn cache, so
nothing above has been run.

## Decisions taken, and what is still open

Both pending questions were defaulted so Phase 3 could land. Change either and Phase 3 needs a
follow-up, not a rewrite:

1. **Filter-builder route, not a one-click preset.** The rule is authored as an ordinary predicate
   (`createdBy` -> `Workspace Member` -> `Me`). A one-click preset is still available as a follow-up
   and would store the same predicate, so no schema change.
2. **Records with no user creator are hidden.** A creator-only rule compiles to
   `createdBy.workspaceMemberId in [<current member>]`. Records created by API keys, workflows, or
   imports carry `createdBy.source != MANUAL` and a null `workspaceMemberId`, so they match nothing
   and become invisible to the restricted role. That follows the literal ask ("only the records they
   created") but can hide a lot of integration-created data. Keeping them visible would require an
   `OR` branch, which the current RLS builder cannot author (it only renders root-level `AND` rules),
   so it needs a scope decision before any work.

---

# Plan: backup, patch in place, and validate a live Docker Compose instance

## Goal

Get the working tree (un-gated row-level permissions + creator-only visibility) onto the live
`docker compose` deployment **without removing the stack**: no `docker compose down`, no volume
removal, no re-initialisation. The database and uploaded files must survive, and there must be a
restorable backup and a rollback path.

Implemented as `packages/twenty-docker/scripts/patch-instance.sh`, with the commands
`backup`, `patch`, `validate`, `rollback` and `all` (the three requested steps in order).

## Why an in-place patch is possible

The deployment pins the Twenty image through `TAG` in `.env` (`image: twentycrm/twenty:${TAG}`), which
is the same knob `install.sh` uses. So patching is: build an image, point `TAG` at it, then
`docker compose up -d server worker`. Compose recreates only containers whose configuration changed,
so `db` and `redis` keep running and their volumes are never remounted. The `db`/`redis` services are
never named on the command line, which is what makes the "no remove and re-deploy" requirement hold.

## Step 1 - Backup (current database and data)

Written to `<compose-dir>/backups/<timestamp>/`:

| Artifact | How |
|---|---|
| `database.dump` | `pg_dump --format=custom --no-owner --no-privileges` inside the `db` container, then `docker cp` out |
| `globals.sql` | `pg_dumpall --globals-only` (roles) |
| `dump-contents.txt` | `pg_restore --list` of the dump: proves the archive is readable |
| `server-local-data.tar.gz` | `tar` over the `server-local-data` volume (uploaded files), skipped for S3 storage |
| `config/` | `docker-compose.yml`, `.env` (holds `ENCRYPTION_KEY`), overrides |
| `manifest.txt` | timestamp, git commit, previous `TAG`, previous image refs and image ids, storage mount, db size |
| `counts-before.txt` | row counts for `core.workspace`, `core.user` and both `rowLevelPermission*` tables |
| `counts-restored*.txt` | the same counts read back from the restored copy, plus psql's stderr when they cannot be read |

Then the dump is **restored into a throwaway Postgres container** before anything is patched, and the
row counts are compared. That follows the docs' "test restores regularly" advice and makes an unusable
backup stop the run while the old version is still live.

Two things about that drill are easy to get wrong. The scratch container is reached over **TCP with a
password**, never through the unix socket: the postgres entrypoint runs a temporary server on the socket
while it initialises the cluster and then restarts the real one, so a socket-based readiness check
passes during that window and `pg_restore` lands in the gap, restoring nothing. And the database size is
recorded but never compared, because a fresh restore is normally smaller than a live database and would
always look like a mismatch.

When the drill cannot read its row counts back it retries once, then reports why: psql's own error, the
scratch container's status and OOM/exit code, and its last log lines. A drill that cannot confirm the
restore is reported as *verified only as a readable archive*, which is a weaker statement than "verified"
and deliberately does not block the patch.

## Step 2 - Patch (instance)

1. Record what to roll back to in `backups/last-patch.txt` **before** touching anything.
2. Build the image (`--mode=build`, default):
   `docker build --target twenty -f packages/twenty-docker/twenty/Dockerfile --platform <host arch> --build-arg APP_VERSION=<tag> -t twentycrm/twenty:<tag> <repo>`.
   `--target twenty` is the server + frontend image the compose file expects. `PATCH_IMAGE_REPO` defaults
to the repository the running server container already uses, so switching `TAG` alone resolves it.
3. Set `TAG=<patched tag>` in `.env`, rewritten through the same inode so the file keeps its mode
   (`ENCRYPTION_KEY` lives there).
4. `docker compose up -d server worker`, then wait for the container's own healthcheck to report
   `healthy`. The server runs `database:init:prod` / `upgrade` itself through its entrypoint, exactly as
   on a normal restart. `--mode=pull` instead switches to a published release tag, which replaces the
   locally built image and therefore drops local changes: that is the "upgrade Twenty" path, not the
   patch path.

## Step 3 - Validate

1. `curl /healthz` against the published port (falls back to the container address).
2. The running container's image id equals the image just built.
3. Inside the shipped `dist/`: `upsertRowLevelPermissionPredicates` present as a positive control, and
   `ROW_LEVEL_PERMISSION_FEATURE_DISABLED`, `hasRowLevelPermissionFeature`,
   `deleteAllRowLevelPermissionPredicateGroups` all gone. The positive control is what stops a mistyped
   grep from reading as a pass.
4. `dist/front/index.html` present, and the removed "Upgrade to access" card's lingui id (`ggd+Ee`) gone
   from the front bundle. Soft check.
5. `/client-config` reports `appVersion` equal to the patch tag (when the image was built with one).
6. Row counts unchanged against `counts-before.txt`, with the RLS tables called out: a drop there is
   exactly the billing-sync wipe this patch removes.
7. Prints the remaining by-hand UI checklist (editor renders without the Upgrade card, author
   `Created by` -> `Workspace Member` -> `Me (User ID)`, two members see only their own records).

## Rollback

`rollback` reads `backups/last-patch.txt`, restores the previous `TAG`, pulls the old image when it is
not on the host, recreates `server` + `worker`, and prints the dump-restore procedure. The database is
not touched by a patch, so no data rollback is normally needed.

## Prerequisites and limits

- **`--mode=build` needs network egress from the build container** to the npm registry: the image build
  runs `yarn workspaces focus`. On an air-gapped host, pre-build elsewhere and either push the image or
  copy it over.
- **The in-image front-end build uses an 8GB heap** (`NODE_OPTIONS=--max-old-space-size=8192` in
  `packages/twenty-docker/twenty/Dockerfile`), so a small self-hosted box can OOM. The script warns when
  `/proc/meminfo` reports under 8GB. Workaround: run `npx nx build twenty-front` on a bigger machine and
  place the output at `packages/twenty-front/build` in the checkout; the Dockerfile explicitly uses it
  when it is already there, skipping the heavy step.
- **Local storage is archived per mount shape**: named volume (helper container), bind mount (host
  `tar`), or neither (S3, skipped with a warning). The manifest records `local_storage=` as the volume
  name, `bind:<path>`, or `none`.
- Compose prints `WARN The "FALLBACK_ENCRYPTION_KEY" variable is not set` on every call when the
  deployment `.env` omits it. That is a warning about the compose file's own reference, and the empty
  value it defaults to is what the instance already runs with; adding `FALLBACK_ENCRYPTION_KEY=` to
  `.env` silences it.

## Status

- Implemented and verified by running the full `all`, `patch`, `rollback` and failure paths against a
  stand-in for the `docker`/`curl` CLI, which asserted the calls issued as well as the output: only
  `docker compose up -d server worker` is ever run, `down`/`stop`/`restart` never appear, the `.env`
  mode is preserved and only `TAG` changes, and a still-gated image makes `validate` exit non-zero.
- The stand-in now validates the CLI surface it is handed, including flags. The first version did not,
  which is how `docker exec -T` reached a real host: `-T` is a `docker compose exec` flag, `docker
  exec` has no such flag and rejects it. Every `docker exec` call is now the plain form (or `-i` when
  it reads stdin), and `docker compose exec -T` keeps `-T`.
- Also verified against the stand-in: all three local-storage mount shapes, and the bind-mount path
  really producing a tar of the directory.
- The stand-in also reproduces the restore-drill race (a Unix-socket answer during cluster init, TCP
  only afterwards), so the fix is covered: a socket-based readiness check restores nothing and is now
  reported as an incomplete drill rather than as row-count drift.
- The drill's count step is covered for three outcomes: counts read back (verified), a first round that
  fails and is recovered by the retry, and counts that stay unreadable in both rounds (reported as
  unverified, with psql's error, the container's status and its last log lines).
- Not yet run against a real Docker daemon, and never against the production instance. The first real
  run should be `backup` alone, then the by-hand UI checklist after `all`.
