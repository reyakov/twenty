/* @license Enterprise */

import { Injectable } from '@nestjs/common';

import { isDefined } from 'twenty-shared/utils';

import { WorkspaceManyOrAllFlatEntityMapsCacheService } from 'src/engine/metadata-modules/flat-entity/services/workspace-many-or-all-flat-entity-maps-cache.service';
import { findFlatEntityByIdInFlatEntityMaps } from 'src/engine/metadata-modules/flat-entity/utils/find-flat-entity-by-id-in-flat-entity-maps.util';
import { fromFlatRowLevelPermissionPredicateGroupToDto } from 'src/engine/metadata-modules/flat-row-level-permission-predicate/utils/from-flat-row-level-permission-predicate-group-to-dto.util';
import { RowLevelPermissionPredicateGroupDTO } from 'src/engine/metadata-modules/row-level-permission-predicate/dtos/row-level-permission-predicate-group.dto';

@Injectable()
export class RowLevelPermissionPredicateGroupService {
  constructor(
    private readonly flatEntityMapsCacheService: WorkspaceManyOrAllFlatEntityMapsCacheService,
  ) {}

  async findByWorkspaceId(
    workspaceId: string,
  ): Promise<RowLevelPermissionPredicateGroupDTO[]> {
    const { flatRowLevelPermissionPredicateGroupMaps } =
      await this.flatEntityMapsCacheService.getOrRecomputeManyOrAllFlatEntityMaps(
        {
          workspaceId,
          flatMapsKeys: ['flatRowLevelPermissionPredicateGroupMaps'],
        },
      );

    return Object.values(
      flatRowLevelPermissionPredicateGroupMaps.byUniversalIdentifier,
    )
      .filter(isDefined)
      .filter((group) => group.deletedAt === null)
      .sort(
        (a, b) =>
          (a.positionInRowLevelPermissionPredicateGroup ?? 0) -
          (b.positionInRowLevelPermissionPredicateGroup ?? 0),
      )
      .map(fromFlatRowLevelPermissionPredicateGroupToDto);
  }

  async findByRole(
    workspaceId: string,
    roleId: string,
  ): Promise<RowLevelPermissionPredicateGroupDTO[]> {
    const { flatRowLevelPermissionPredicateGroupMaps } =
      await this.flatEntityMapsCacheService.getOrRecomputeManyOrAllFlatEntityMaps(
        {
          workspaceId,
          flatMapsKeys: ['flatRowLevelPermissionPredicateGroupMaps'],
        },
      );

    return Object.values(
      flatRowLevelPermissionPredicateGroupMaps.byUniversalIdentifier,
    )
      .filter(isDefined)
      .filter((group) => group.deletedAt === null && group.roleId === roleId)
      .sort(
        (a, b) =>
          (a.positionInRowLevelPermissionPredicateGroup ?? 0) -
          (b.positionInRowLevelPermissionPredicateGroup ?? 0),
      )
      .map(fromFlatRowLevelPermissionPredicateGroupToDto);
  }

  async findById(
    id: string,
    workspaceId: string,
  ): Promise<RowLevelPermissionPredicateGroupDTO | null> {
    const { flatRowLevelPermissionPredicateGroupMaps } =
      await this.flatEntityMapsCacheService.getOrRecomputeManyOrAllFlatEntityMaps(
        {
          workspaceId,
          flatMapsKeys: ['flatRowLevelPermissionPredicateGroupMaps'],
        },
      );

    const flatGroup = findFlatEntityByIdInFlatEntityMaps({
      flatEntityId: id,
      flatEntityMaps: flatRowLevelPermissionPredicateGroupMaps,
    });

    if (!isDefined(flatGroup) || flatGroup.deletedAt !== null) {
      return null;
    }

    return fromFlatRowLevelPermissionPredicateGroupToDto(flatGroup);
  }
}
