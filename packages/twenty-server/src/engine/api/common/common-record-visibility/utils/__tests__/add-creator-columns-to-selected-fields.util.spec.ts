import {
  FieldMetadataType,
  type RestrictedFieldsPermissions,
} from 'twenty-shared/types';

import { addCreatorColumnsToSelectedFields } from 'src/engine/api/common/common-record-visibility/utils/add-creator-columns-to-selected-fields.util';
import { createEmptyFlatEntityMaps } from 'src/engine/metadata-modules/flat-entity/constant/create-empty-flat-entity-maps.constant';
import { type FlatEntityMaps } from 'src/engine/metadata-modules/flat-entity/types/flat-entity-maps.type';
import { getFlatFieldMetadataMock } from 'src/engine/metadata-modules/flat-field-metadata/__mocks__/get-flat-field-metadata.mock';
import { type OrmFlatFieldMetadata } from 'src/engine/metadata-modules/flat-field-metadata/types/orm-flat-field-metadata.type';
import { getFlatObjectMetadataMock } from 'src/engine/metadata-modules/flat-object-metadata/__mocks__/get-flat-object-metadata.mock';
import { type FlatObjectMetadata } from 'src/engine/metadata-modules/flat-object-metadata/types/flat-object-metadata.type';
import { type RoleRecordsPermissions } from 'src/engine/permissions/types/role-records-permissions.type';

const COMPANY_ID = 'company-id';
const AMOUNT_FIELD_ID = 'amount-field-id';
const CREATED_BY_FIELD_ID = 'created-by-field-id';

const flatObjectMetadataMaps: FlatEntityMaps<FlatObjectMetadata> =
  createEmptyFlatEntityMaps();
const flatFieldMetadataMaps: FlatEntityMaps<OrmFlatFieldMetadata> =
  createEmptyFlatEntityMaps();

const companyObjectMetadata = getFlatObjectMetadataMock({
  id: COMPANY_ID,
  universalIdentifier: 'company',
  fieldIds: [AMOUNT_FIELD_ID, CREATED_BY_FIELD_ID],
});

flatObjectMetadataMaps.byUniversalIdentifier.company = companyObjectMetadata;
flatObjectMetadataMaps.universalIdentifierById[COMPANY_ID] = 'company';

for (const fieldMetadata of [
  getFlatFieldMetadataMock({
    id: AMOUNT_FIELD_ID,
    universalIdentifier: 'amount',
    objectMetadataId: COMPANY_ID,
    type: FieldMetadataType.CURRENCY,
    name: 'annualRevenue',
  }),
  getFlatFieldMetadataMock({
    id: CREATED_BY_FIELD_ID,
    universalIdentifier: 'created-by',
    objectMetadataId: COMPANY_ID,
    type: FieldMetadataType.ACTOR,
    name: 'createdBy',
  }),
]) {
  flatFieldMetadataMaps.byUniversalIdentifier[
    fieldMetadata.universalIdentifier
  ] = fieldMetadata;
  flatFieldMetadataMaps.universalIdentifierById[fieldMetadata.id] =
    fieldMetadata.universalIdentifier;
}

const buildRecordsPermissions = (
  restrictedFields: RestrictedFieldsPermissions,
): RoleRecordsPermissions => ({
  canReadAllRecords: true,
  canUpdateAllRecords: true,
  canSoftDeleteAllRecords: true,
  canDestroyAllRecords: true,
  objects: {
    [COMPANY_ID]: {
      canReadAllRecords: true,
      canUpdateAllRecords: true,
      canSoftDeleteAllRecords: true,
      canDestroyAllRecords: true,
      restrictedFields,
    },
  },
});

describe('addCreatorColumnsToSelectedFields', () => {
  it('adds every actor column needed to resolve the record creator', () => {
    const select = { annualRevenueAmountMicros: true };

    addCreatorColumnsToSelectedFields({
      select,
      recordsPermissions: buildRecordsPermissions({
        [AMOUNT_FIELD_ID]: { canRead: null, restrictToCreator: true },
      }),
      flatObjectMetadata: companyObjectMetadata,
      flatObjectMetadataMaps,
      flatFieldMetadataMaps,
    });

    expect(select).toEqual({
      annualRevenueAmountMicros: true,
      createdBySource: true,
      createdByName: true,
      createdByWorkspaceMemberId: true,
      createdByContext: true,
    });
  });

  it('completes an existing actor selection instead of adding raw columns', () => {
    const select = {
      createdBy: { workspaceMemberId: true },
    };

    addCreatorColumnsToSelectedFields({
      select,
      recordsPermissions: buildRecordsPermissions({
        [AMOUNT_FIELD_ID]: { canRead: null, restrictToCreator: true },
      }),
      flatObjectMetadata: companyObjectMetadata,
      flatObjectMetadataMaps,
      flatFieldMetadataMaps,
    });

    expect(select).toEqual({
      createdBy: {
        source: true,
        name: true,
        workspaceMemberId: true,
        context: true,
      },
    });
  });

  it('does not touch the selection without a creator restriction', () => {
    const select = { annualRevenueAmountMicros: true };

    addCreatorColumnsToSelectedFields({
      select,
      recordsPermissions: buildRecordsPermissions({
        [AMOUNT_FIELD_ID]: { canRead: false },
      }),
      flatObjectMetadata: companyObjectMetadata,
      flatObjectMetadataMaps,
      flatFieldMetadataMaps,
    });

    expect(select).toEqual({ annualRevenueAmountMicros: true });
  });
});
