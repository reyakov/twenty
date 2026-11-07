import { isNonEmptyString } from '@sniptt/guards';
import { FieldMetadataType, type ObjectRecord } from 'twenty-shared/types';
import { isDefined } from 'twenty-shared/utils';

import { CREATED_BY_WORKSPACE_MEMBER_ID_COLUMN_NAME } from 'src/engine/permissions/private-record/constants/created-by-workspace-member-id-column-name.constant';
import { type FlatEntityMaps } from 'src/engine/metadata-modules/flat-entity/types/flat-entity-maps.type';
import { findFlatEntityByIdInFlatEntityMaps } from 'src/engine/metadata-modules/flat-entity/utils/find-flat-entity-by-id-in-flat-entity-maps.util';
import { type OrmFlatFieldMetadata } from 'src/engine/metadata-modules/flat-field-metadata/types/orm-flat-field-metadata.type';
import { type FlatObjectMetadata } from 'src/engine/metadata-modules/flat-object-metadata/types/flat-object-metadata.type';
import { type RoleRecordsPermissions } from 'src/engine/permissions/types/role-records-permissions.type';

const getCreatedByWorkspaceMemberId = (
  record: ObjectRecord,
): string | null | undefined => {
  const rawCreatorWorkspaceMemberId =
    record[CREATED_BY_WORKSPACE_MEMBER_ID_COLUMN_NAME];

  if (isNonEmptyString(rawCreatorWorkspaceMemberId)) {
    return rawCreatorWorkspaceMemberId;
  }

  const createdBy = record.createdBy;

  if (
    typeof createdBy !== 'object' ||
    createdBy === null ||
    !('workspaceMemberId' in createdBy)
  ) {
    return undefined;
  }

  const workspaceMemberId = createdBy.workspaceMemberId;

  return typeof workspaceMemberId === 'string' ? workspaceMemberId : null;
};

export const maskCreatorRestrictedFields = ({
  records,
  flatObjectMetadata,
  flatObjectMetadataMaps,
  flatFieldMetadataMaps,
  recordsPermissions,
  currentWorkspaceMemberId,
}: {
  records: ObjectRecord[];
  flatObjectMetadata: FlatObjectMetadata;
  flatObjectMetadataMaps: FlatEntityMaps<FlatObjectMetadata>;
  flatFieldMetadataMaps: FlatEntityMaps<OrmFlatFieldMetadata>;
  recordsPermissions: RoleRecordsPermissions;
  currentWorkspaceMemberId: string | undefined;
}): void => {
  const hasAnyCreatorRestriction = Object.values(
    recordsPermissions.objects,
  ).some(
    (objectPermissions) =>
      isDefined(objectPermissions) &&
      Object.values(objectPermissions.restrictedFields).some(
        (fieldPermission) => fieldPermission.restrictToCreator === true,
      ),
  );

  if (!hasAnyCreatorRestriction || records.length === 0) {
    return;
  }

  const visitedRecords = new WeakSet<object>();

  const applyToRecords = ({
    objectRecords,
    objectMetadata,
  }: {
    objectRecords: ObjectRecord[];
    objectMetadata: FlatObjectMetadata;
  }): void => {
    const restrictedFields =
      recordsPermissions.objects[objectMetadata.id]?.restrictedFields ?? {};

    const fieldMetadataById = new Map<string, OrmFlatFieldMetadata>();

    for (const fieldMetadataId of objectMetadata.fieldIds) {
      const fieldMetadata = findFlatEntityByIdInFlatEntityMaps({
        flatEntityId: fieldMetadataId,
        flatEntityMaps: flatFieldMetadataMaps,
      });

      if (isDefined(fieldMetadata)) {
        fieldMetadataById.set(fieldMetadataId, fieldMetadata);
      }
    }

    const creatorRestrictedFieldMetadataIds = Object.entries(restrictedFields)
      .filter(
        ([, fieldPermission]) => fieldPermission.restrictToCreator === true,
      )
      .map(([fieldMetadataId]) => fieldMetadataId);

    for (const record of objectRecords) {
      if (visitedRecords.has(record)) {
        continue;
      }

      visitedRecords.add(record);

      const isRecordCreator =
        isNonEmptyString(currentWorkspaceMemberId) &&
        getCreatedByWorkspaceMemberId(record) === currentWorkspaceMemberId;

      for (const fieldMetadataId of creatorRestrictedFieldMetadataIds) {
        const fieldMetadata = fieldMetadataById.get(fieldMetadataId);

        if (isDefined(fieldMetadata) && !isRecordCreator) {
          record[fieldMetadata.name] = null;
        }
      }

      for (const fieldMetadata of fieldMetadataById.values()) {
        if (
          fieldMetadata.type !== FieldMetadataType.RELATION &&
          fieldMetadata.type !== FieldMetadataType.MORPH_RELATION
        ) {
          continue;
        }

        const relationTargetObjectMetadataId =
          fieldMetadata.relationTargetObjectMetadataId;

        if (!isDefined(relationTargetObjectMetadataId)) {
          continue;
        }

        const targetObjectMetadata = findFlatEntityByIdInFlatEntityMaps({
          flatEntityId: relationTargetObjectMetadataId,
          flatEntityMaps: flatObjectMetadataMaps,
        });

        if (!isDefined(targetObjectMetadata)) {
          continue;
        }

        const relationValue = record[fieldMetadata.name];

        if (typeof relationValue !== 'object' || relationValue === null) {
          continue;
        }

        applyToRecords({
          objectRecords: (Array.isArray(relationValue)
            ? relationValue
            : [relationValue]) as ObjectRecord[],
          objectMetadata: targetObjectMetadata,
        });
      }
    }
  };

  applyToRecords({
    objectRecords: records,
    objectMetadata: flatObjectMetadata,
  });
};
