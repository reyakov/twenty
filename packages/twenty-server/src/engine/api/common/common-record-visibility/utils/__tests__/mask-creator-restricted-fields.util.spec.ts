import {
  FieldMetadataType,
  type ObjectRecord,
  type RestrictedFieldsPermissions,
} from 'twenty-shared/types';

import { maskCreatorRestrictedFields } from 'src/engine/api/common/common-record-visibility/utils/mask-creator-restricted-fields.util';
import { createEmptyFlatEntityMaps } from 'src/engine/metadata-modules/flat-entity/constant/create-empty-flat-entity-maps.constant';
import { type FlatEntityMaps } from 'src/engine/metadata-modules/flat-entity/types/flat-entity-maps.type';
import { getFlatFieldMetadataMock } from 'src/engine/metadata-modules/flat-field-metadata/__mocks__/get-flat-field-metadata.mock';
import { type OrmFlatFieldMetadata } from 'src/engine/metadata-modules/flat-field-metadata/types/orm-flat-field-metadata.type';
import { getFlatObjectMetadataMock } from 'src/engine/metadata-modules/flat-object-metadata/__mocks__/get-flat-object-metadata.mock';
import { type FlatObjectMetadata } from 'src/engine/metadata-modules/flat-object-metadata/types/flat-object-metadata.type';
import { type RoleRecordsPermissions } from 'src/engine/permissions/types/role-records-permissions.type';

const COMPANY_ID = 'company-id';
const PERSON_ID = 'person-id';
const CURRENT_MEMBER_ID = 'current-member-id';

const flatObjectMetadataMaps: FlatEntityMaps<FlatObjectMetadata> =
  createEmptyFlatEntityMaps();
const flatFieldMetadataMaps: FlatEntityMaps<OrmFlatFieldMetadata> =
  createEmptyFlatEntityMaps();

const companyObjectMetadata = getFlatObjectMetadataMock({
  id: COMPANY_ID,
  universalIdentifier: 'company',
  labelIdentifierFieldMetadataId: 'name-field-id',
  fieldIds: ['revenue-field-id', 'creator-field-id', 'people-field-id'],
});

flatObjectMetadataMaps.byUniversalIdentifier.company = companyObjectMetadata;
flatObjectMetadataMaps.universalIdentifierById[COMPANY_ID] = 'company';
flatObjectMetadataMaps.byUniversalIdentifier.person = getFlatObjectMetadataMock(
  {
    id: PERSON_ID,
    universalIdentifier: 'person',
    labelIdentifierFieldMetadataId: 'person-name-field-id',
    fieldIds: ['person-secret-field-id', 'person-creator-field-id'],
  },
);
flatObjectMetadataMaps.universalIdentifierById[PERSON_ID] = 'person';

for (const fieldMetadata of [
  getFlatFieldMetadataMock({
    id: 'revenue-field-id',
    universalIdentifier: 'revenue',
    objectMetadataId: COMPANY_ID,
    type: FieldMetadataType.CURRENCY,
    name: 'annualRevenue',
  }),
  getFlatFieldMetadataMock({
    id: 'creator-field-id',
    universalIdentifier: 'creator',
    objectMetadataId: COMPANY_ID,
    type: FieldMetadataType.ACTOR,
    name: 'createdBy',
  }),
  getFlatFieldMetadataMock({
    id: 'people-field-id',
    universalIdentifier: 'people',
    objectMetadataId: COMPANY_ID,
    type: FieldMetadataType.RELATION,
    name: 'people',
    relationTargetObjectMetadataId: PERSON_ID,
  }),
  getFlatFieldMetadataMock({
    id: 'person-secret-field-id',
    universalIdentifier: 'person-secret',
    objectMetadataId: PERSON_ID,
    type: FieldMetadataType.TEXT,
    name: 'secret',
  }),
  getFlatFieldMetadataMock({
    id: 'person-creator-field-id',
    universalIdentifier: 'person-creator',
    objectMetadataId: PERSON_ID,
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
  companyRestrictedFields: RestrictedFieldsPermissions,
  personRestrictedFields: RestrictedFieldsPermissions = {},
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
      restrictedFields: companyRestrictedFields,
    },
    [PERSON_ID]: {
      canReadAllRecords: true,
      canUpdateAllRecords: true,
      canSoftDeleteAllRecords: true,
      canDestroyAllRecords: true,
      restrictedFields: personRestrictedFields,
    },
  },
});

const buildRecord = ({
  id,
  creatorId,
  revenue,
  people,
}: {
  id: string;
  creatorId?: string;
  revenue: number;
  people: ObjectRecord[];
}): ObjectRecord => ({
  id,
  createdBy: creatorId === undefined ? null : { workspaceMemberId: creatorId },
  annualRevenue: { amountMicros: revenue },
  people,
});

const mask = ({
  records,
  recordsPermissions,
  currentWorkspaceMemberId,
}: {
  records: ObjectRecord[];
  recordsPermissions: RoleRecordsPermissions;
  currentWorkspaceMemberId?: string;
}) =>
  maskCreatorRestrictedFields({
    records,
    flatObjectMetadata: companyObjectMetadata,
    flatObjectMetadataMaps,
    flatFieldMetadataMaps,
    recordsPermissions,
    currentWorkspaceMemberId,
  });

describe('maskCreatorRestrictedFields', () => {
  it('keeps the value for the record creator and hides it from other members', () => {
    const ownRecord = buildRecord({
      id: 'own',
      creatorId: CURRENT_MEMBER_ID,
      revenue: 100,
      people: [],
    });
    const otherRecord = buildRecord({
      id: 'other',
      creatorId: 'other-member-id',
      revenue: 200,
      people: [],
    });

    mask({
      records: [ownRecord, otherRecord],
      recordsPermissions: buildRecordsPermissions({
        'revenue-field-id': { canRead: null, restrictToCreator: true },
      }),
      currentWorkspaceMemberId: CURRENT_MEMBER_ID,
    });

    expect(ownRecord.annualRevenue).toEqual({ amountMicros: 100 });
    expect(otherRecord.annualRevenue).toBeNull();
  });

  it('masks every row when there is no user workspace member', () => {
    const ownRecord = buildRecord({
      id: 'own',
      creatorId: CURRENT_MEMBER_ID,
      revenue: 100,
      people: [],
    });

    mask({
      records: [ownRecord],
      recordsPermissions: buildRecordsPermissions({
        'revenue-field-id': { canRead: null, restrictToCreator: true },
      }),
      currentWorkspaceMemberId: undefined,
    });

    expect(ownRecord.annualRevenue).toBeNull();
  });

  it('fails closed when the record has no creator', () => {
    const record = buildRecord({
      id: 'no-creator',
      revenue: 100,
      people: [],
    });

    mask({
      records: [record],
      recordsPermissions: buildRecordsPermissions({
        'revenue-field-id': { canRead: null, restrictToCreator: true },
      }),
      currentWorkspaceMemberId: CURRENT_MEMBER_ID,
    });

    expect(record.annualRevenue).toBeNull();
  });

  it('leaves unmarked fields and records untouched', () => {
    const record = buildRecord({
      id: 'other',
      creatorId: 'other-member-id',
      revenue: 200,
      people: [],
    });

    mask({
      records: [record],
      recordsPermissions: buildRecordsPermissions({
        'revenue-field-id': { canRead: false, canUpdate: null },
      }),
      currentWorkspaceMemberId: CURRENT_MEMBER_ID,
    });

    expect(record.annualRevenue).toEqual({ amountMicros: 200 });
  });

  it('masks creator-restricted fields of nested relations', () => {
    const nestedPerson = buildRecord({
      id: 'person',
      creatorId: 'other-member-id',
      revenue: 0,
      people: [],
    });
    nestedPerson.secret = 'visible only to its creator';

    const record = buildRecord({
      id: 'company',
      creatorId: CURRENT_MEMBER_ID,
      revenue: 100,
      people: [nestedPerson],
    });

    mask({
      records: [record],
      recordsPermissions: buildRecordsPermissions(
        {},
        {
          'person-secret-field-id': { canRead: null, restrictToCreator: true },
        },
      ),
      currentWorkspaceMemberId: CURRENT_MEMBER_ID,
    });

    expect(nestedPerson.secret).toBeNull();
  });
});
