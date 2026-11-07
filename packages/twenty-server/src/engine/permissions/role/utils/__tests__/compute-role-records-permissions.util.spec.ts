import { computeRoleRecordsPermissions } from 'src/engine/permissions/role/utils/compute-role-records-permissions.util';

const OBJECT_ID = 'object-id';
const LABEL_IDENTIFIER_FIELD_ID = 'label-identifier-field-id';
const AMOUNT_FIELD_ID = 'amount-field-id';

const compute = () =>
  computeRoleRecordsPermissions({
    roleDefinition: {
      canReadAllObjectRecords: true,
      canUpdateAllObjectRecords: true,
      canSoftDeleteAllObjectRecords: true,
      canDestroyAllObjectRecords: true,
      isPermissionFlagGranted: () => false,
      objectPermissions: [],
      fieldPermissions: [
        {
          objectMetadataId: OBJECT_ID,
          fieldMetadataId: AMOUNT_FIELD_ID,
          canReadFieldValue: null,
          canUpdateFieldValue: null,
          restrictFieldValueToCreator: true,
        },
        {
          objectMetadataId: OBJECT_ID,
          fieldMetadataId: LABEL_IDENTIFIER_FIELD_ID,
          canReadFieldValue: null,
          canUpdateFieldValue: null,
          restrictFieldValueToCreator: true,
        },
      ],
      rowLevelPermissionPredicates: [],
      rowLevelPermissionPredicateGroups: [],
    },
    objectMetadataCollection: [
      {
        id: OBJECT_ID,
        isSystem: false,
        universalIdentifier: 'company',
        labelIdentifierFieldMetadataId: LABEL_IDENTIFIER_FIELD_ID,
      },
    ],
    resolveMorphRelationPermissionFieldIds: (fieldMetadataId) => [
      fieldMetadataId,
    ],
  });

describe('computeRoleRecordsPermissions creator restriction', () => {
  it('projects the creator restriction on regular fields', () => {
    expect(
      compute().objects[OBJECT_ID]?.restrictedFields[AMOUNT_FIELD_ID],
    ).toEqual({
      canRead: null,
      canUpdate: null,
      restrictToCreator: true,
    });
  });

  it('never applies the creator restriction to the label identifier', () => {
    expect(
      compute().objects[OBJECT_ID]?.restrictedFields[LABEL_IDENTIFIER_FIELD_ID],
    ).toEqual({
      canRead: true,
      canUpdate: null,
      restrictToCreator: undefined,
    });
  });
});
