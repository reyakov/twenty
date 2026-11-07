import { type FieldMetadataItem } from '@/object-metadata/types/FieldMetadataItem';
import { type ObjectPermissionsByObjectMetadataId } from '@/object-metadata/types/ObjectPermissionsByObjectMetadataId';
import { getFieldPermissions } from '@/object-metadata/utils/getFieldPermissions';
import { getObjectPermissionsForObject } from '@/object-metadata/utils/getObjectPermissionsForObject';
import { isOneToManyRelationFieldReadOnlyDueToTargetUpdatePermission } from '@/object-record/read-only/utils/isOneToManyRelationFieldReadOnlyDueToTargetUpdatePermission';
import { type FieldDefinition } from '@/object-record/record-field/ui/types/FieldDefinition';
import { type FieldMetadata } from '@/object-record/record-field/ui/types/FieldMetadata';
import { canReachSomeRecords, isDefined } from 'twenty-shared/utils';

type IsRecordFieldReadOnlyParams = {
  isRecordReadOnly: boolean;
  objectMetadataId: string;
  fieldMetadataItem: Pick<FieldMetadataItem, 'id' | 'isUIEditable'>;
  objectPermissionsByObjectMetadataId: ObjectPermissionsByObjectMetadataId;
  fieldDefinition?: FieldDefinition<FieldMetadata>;
  recordCreatedByWorkspaceMemberId?: string;
  currentWorkspaceMemberId?: string;
};

export const isRecordFieldReadOnly = ({
  isRecordReadOnly,
  objectMetadataId,
  fieldMetadataItem,
  objectPermissionsByObjectMetadataId,
  fieldDefinition,
  recordCreatedByWorkspaceMemberId,
  currentWorkspaceMemberId,
}: IsRecordFieldReadOnlyParams) => {
  if (isRecordReadOnly || !(fieldMetadataItem.isUIEditable ?? true)) {
    return true;
  }

  const objectPermissions = getObjectPermissionsForObject(
    objectPermissionsByObjectMetadataId,
    objectMetadataId,
  );

  const fieldPermissions = getFieldPermissions({
    objectPermissions,
    fieldMetadataId: fieldMetadataItem.id,
  });

  if (
    !canReachSomeRecords({
      objectRecordsPermissions: objectPermissions,
      operationType: 'update',
    }) ||
    !fieldPermissions.canUpdateField ||
    (fieldPermissions.restrictToCreator &&
      recordCreatedByWorkspaceMemberId !== currentWorkspaceMemberId)
  ) {
    return true;
  }

  return (
    isDefined(fieldDefinition) &&
    isOneToManyRelationFieldReadOnlyDueToTargetUpdatePermission({
      fieldDefinition,
      objectPermissionsByObjectMetadataId,
    })
  );
};
