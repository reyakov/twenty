import { getFieldPermissions } from '@/object-metadata/utils/getFieldPermissions';

const FIELD_METADATA_ID = 'field-metadata-id';

describe('getFieldPermissions', () => {
  it('should allow reading and updating a field without restriction', () => {
    expect(
      getFieldPermissions({
        objectPermissions: { restrictedFields: {} },
        fieldMetadataId: FIELD_METADATA_ID,
      }),
    ).toEqual({
      canReadField: true,
      canUpdateField: true,
      restrictToCreator: false,
    });
  });

  it('should only deny what the restriction explicitly denies', () => {
    expect(
      getFieldPermissions({
        objectPermissions: {
          restrictedFields: {
            [FIELD_METADATA_ID]: { canRead: null, canUpdate: false },
          },
        },
        fieldMetadataId: FIELD_METADATA_ID,
      }),
    ).toEqual({
      canReadField: true,
      canUpdateField: false,
      restrictToCreator: false,
    });
  });

  it('should expose the creator restriction', () => {
    expect(
      getFieldPermissions({
        objectPermissions: {
          restrictedFields: {
            [FIELD_METADATA_ID]: {
              canRead: null,
              canUpdate: null,
              restrictToCreator: true,
            },
          },
        },
        fieldMetadataId: FIELD_METADATA_ID,
      }),
    ).toEqual({
      canReadField: true,
      canUpdateField: true,
      restrictToCreator: true,
    });
  });

  it('should deny reading a field restricted for reading', () => {
    expect(
      getFieldPermissions({
        objectPermissions: {
          restrictedFields: {
            [FIELD_METADATA_ID]: { canRead: false, canUpdate: false },
          },
        },
        fieldMetadataId: FIELD_METADATA_ID,
      }),
    ).toEqual({
      canReadField: false,
      canUpdateField: false,
      restrictToCreator: false,
    });
  });
});
