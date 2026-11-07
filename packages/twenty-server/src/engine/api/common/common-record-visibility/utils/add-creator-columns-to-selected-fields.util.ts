import {
  FieldMetadataType,
  compositeTypeDefinitions,
} from 'twenty-shared/types';
import { isDefined, isPlainObject } from 'twenty-shared/utils';

import { type CommonSelectedFields } from 'src/engine/api/common/types/common-selected-fields-result.type';
import { computeCompositeColumnName } from 'src/engine/metadata-modules/field-metadata/utils/compute-column-name.util';
import { type FlatEntityMaps } from 'src/engine/metadata-modules/flat-entity/types/flat-entity-maps.type';
import { findFlatEntityByIdInFlatEntityMaps } from 'src/engine/metadata-modules/flat-entity/utils/find-flat-entity-by-id-in-flat-entity-maps.util';
import { type OrmFlatFieldMetadata } from 'src/engine/metadata-modules/flat-field-metadata/types/orm-flat-field-metadata.type';
import { type FlatObjectMetadata } from 'src/engine/metadata-modules/flat-object-metadata/types/flat-object-metadata.type';
import { type RoleRecordsPermissions } from 'src/engine/permissions/types/role-records-permissions.type';

export const addCreatorColumnsToSelectedFields = ({
  select,
  recordsPermissions,
  flatObjectMetadata,
  flatObjectMetadataMaps,
  flatFieldMetadataMaps,
}: {
  select: CommonSelectedFields;
  recordsPermissions: RoleRecordsPermissions;
  flatObjectMetadata: FlatObjectMetadata;
  flatObjectMetadataMaps: FlatEntityMaps<FlatObjectMetadata>;
  flatFieldMetadataMaps: FlatEntityMaps<OrmFlatFieldMetadata>;
}): CommonSelectedFields => {
  const hasAnyCreatorRestriction = Object.values(
    recordsPermissions.objects,
  ).some(
    (objectPermissions) =>
      isDefined(objectPermissions) &&
      Object.values(objectPermissions.restrictedFields).some(
        (fieldPermission) => fieldPermission.restrictToCreator === true,
      ),
  );

  if (!hasAnyCreatorRestriction) {
    return select;
  }

  const addToObject = (
    objectSelect: CommonSelectedFields,
    objectMetadata: FlatObjectMetadata,
  ): void => {
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

    const hasCreatorRestriction = Object.values(restrictedFields).some(
      (fieldPermission) => fieldPermission.restrictToCreator === true,
    );
    const createdByFieldMetadata = [...fieldMetadataById.values()].find(
      (fieldMetadata) =>
        fieldMetadata.name === 'createdBy' &&
        fieldMetadata.type === FieldMetadataType.ACTOR,
    );

    if (
      hasCreatorRestriction &&
      isDefined(createdByFieldMetadata) &&
      restrictedFields[createdByFieldMetadata.id]?.canRead !== false
    ) {
      const actorCompositeType = compositeTypeDefinitions.get(
        FieldMetadataType.ACTOR,
      );
      const existingCreatedBySelect = objectSelect[createdByFieldMetadata.name];

      for (const property of actorCompositeType?.properties ?? []) {
        if (isPlainObject(existingCreatedBySelect)) {
          existingCreatedBySelect[property.name] = true;
        } else {
          objectSelect[
            computeCompositeColumnName(createdByFieldMetadata.name, property)
          ] = true;
        }
      }
    }

    for (const fieldMetadata of fieldMetadataById.values()) {
      if (
        (fieldMetadata.type !== FieldMetadataType.RELATION &&
          fieldMetadata.type !== FieldMetadataType.MORPH_RELATION) ||
        !isDefined(fieldMetadata.relationTargetObjectMetadataId)
      ) {
        continue;
      }

      const relationSelect = objectSelect[fieldMetadata.name];

      if (!isPlainObject(relationSelect)) {
        continue;
      }

      const targetObjectMetadata = findFlatEntityByIdInFlatEntityMaps({
        flatEntityId: fieldMetadata.relationTargetObjectMetadataId,
        flatEntityMaps: flatObjectMetadataMaps,
      });

      if (isDefined(targetObjectMetadata)) {
        addToObject(
          relationSelect as CommonSelectedFields,
          targetObjectMetadata,
        );
      }
    }
  };

  addToObject(select, flatObjectMetadata);

  return select;
};
