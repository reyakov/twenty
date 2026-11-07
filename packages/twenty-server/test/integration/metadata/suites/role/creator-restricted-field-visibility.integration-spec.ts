import { default as request } from 'supertest';
import { createOneOperationFactory } from 'test/integration/graphql/utils/create-one-operation-factory.util';
import { deleteOneOperationFactory } from 'test/integration/graphql/utils/delete-one-operation-factory.util';
import { findOneOperationFactory } from 'test/integration/graphql/utils/find-one-operation-factory.util';
import { makeGraphqlApiRequest } from 'test/integration/graphql/utils/make-graphql-api-request.util';
import { makeGraphqlApiRequestWithMemberRole } from 'test/integration/graphql/utils/make-graphql-api-request-with-member-role.util';
import { updateOneOperationFactory } from 'test/integration/graphql/utils/update-one-operation-factory.util';
import { updateWorkspaceMemberRole } from 'test/integration/graphql/utils/update-workspace-member-role.util';
import { makeRestApiRequest } from 'test/integration/rest/utils/make-rest-api-request.util';
import { findRoles } from 'test/integration/metadata/suites/role/utils/find-roles.util';
import { findManyFieldsMetadata } from 'test/integration/metadata/suites/field-metadata/utils/find-many-fields-metadata.util';
import { upsertFieldPermissions } from 'test/integration/metadata/suites/field-permission/utils/upsert-field-permissions.util';
import { findManyObjectMetadata } from 'test/integration/metadata/suites/object-metadata/utils/find-many-object-metadata.util';
import { upsertObjectPermissions } from 'test/integration/metadata/suites/object-permission/utils/upsert-object-permissions.util';
import { createOneRole } from 'test/integration/metadata/suites/role/utils/create-one-role.util';
import { deleteOneRole } from 'test/integration/metadata/suites/role/utils/delete-one-role.util';
import { jestExpectToBeDefined } from 'test/utils/jest-expect-to-be-defined.util.test';

import { ErrorCode } from 'src/engine/core-modules/graphql/utils/graphql-errors.util';
import { WORKSPACE_MEMBER_DATA_SEED_IDS } from 'src/engine/workspace-manager/dev-seeder/data/constants/workspace-member-data-seeds.constant';

const client = request(`http://localhost:${APP_PORT}`);

const COMPANY_GQL_FIELDS = `
  id
  name
  annualRevenue {
    amountMicros
  }
`;

describe('creator-restricted field visibility', () => {
  let originalMemberRoleId: string;
  let roleId: string;
  let companyObjectMetadataId: string;
  let annualRevenueFieldMetadataId: string;
  let companyNameFieldMetadataId: string;
  let janeCompanyId: string;
  let jonyCompanyId: string;

  const createCompany = async ({
    asJony,
    name,
    amountMicros,
  }: {
    asJony: boolean;
    name: string;
    amountMicros: number;
  }) => {
    const operation = createOneOperationFactory({
      objectMetadataSingularName: 'company',
      gqlFields: 'id',
      data: {
        name,
        annualRevenue: { amountMicros, currencyCode: 'USD' },
      },
    });

    const response = asJony
      ? await makeGraphqlApiRequestWithMemberRole(operation)
      : await makeGraphqlApiRequest(operation);

    expect(response.body.errors).toBeUndefined();

    return response.body.data.createCompany.id as string;
  };

  beforeAll(async () => {
    const { objects } = await findManyObjectMetadata({
      expectToFail: false,
      input: { filter: {}, paging: { first: 1000 } },
      gqlFields: 'id nameSingular',
    });

    const companyId = objects.find(
      (object) => object.nameSingular === 'company',
    )?.id;
    jestExpectToBeDefined(companyId);
    companyObjectMetadataId = companyId;

    const { fields } = await findManyFieldsMetadata({
      expectToFail: false,
      input: {
        filter: { objectMetadataId: { eq: companyObjectMetadataId } },
        paging: { first: 1000 },
      },
      gqlFields: 'id name',
    });

    const annualRevenueFieldId = fields?.find(
      (field: { node: { name: string; id: string } }) =>
        field.node.name === 'annualRevenue',
    )?.node.id;
    jestExpectToBeDefined(annualRevenueFieldId);
    annualRevenueFieldMetadataId = annualRevenueFieldId;

    const companyNameFieldId = fields?.find(
      (field: { node: { name: string; id: string } }) =>
        field.node.name === 'name',
    )?.node.id;
    jestExpectToBeDefined(companyNameFieldId);
    companyNameFieldMetadataId = companyNameFieldId;

    const { data: rolesData } = await findRoles({ gqlFields: 'id label' });
    const memberRoleId = rolesData?.getRoles.find(
      (role) => role.label === 'Member',
    )?.id;
    jestExpectToBeDefined(memberRoleId);
    originalMemberRoleId = memberRoleId;

    const { data: roleData } = await createOneRole({
      expectToFail: false,
      input: {
        label: 'Creator restricted field role',
        description: 'Creator restricted field role',
        icon: 'IconSettings',
        canUpdateAllSettings: false,
        canAccessAllTools: false,
        canAccessAllAgentChatChannels: false,
        canReadAllObjectRecords: false,
        canUpdateAllObjectRecords: false,
        canSoftDeleteAllObjectRecords: false,
        canDestroyAllObjectRecords: false,
        canBeAssignedToUsers: true,
        canBeAssignedToAgents: false,
        canBeAssignedToApiKeys: false,
      },
      gqlFields: 'id',
    });

    roleId = roleData?.createOneRole.id;
    jestExpectToBeDefined(roleId);

    await upsertObjectPermissions({
      expectToFail: false,
      input: {
        roleId,
        objectPermissions: [
          {
            objectMetadataId: companyObjectMetadataId,
            canReadObjectRecords: true,
            canUpdateObjectRecords: true,
            canSoftDeleteObjectRecords: false,
            canDestroyObjectRecords: false,
          },
        ],
      },
    });

    await upsertFieldPermissions({
      expectToFail: false,
      input: {
        roleId,
        fieldPermissions: [
          {
            objectMetadataId: companyObjectMetadataId,
            fieldMetadataId: annualRevenueFieldMetadataId,
            canReadFieldValue: null,
            canUpdateFieldValue: null,
            restrictFieldValueToCreator: true,
          },
        ],
      },
    });

    await updateWorkspaceMemberRole({
      client,
      roleId,
      workspaceMemberId: WORKSPACE_MEMBER_DATA_SEED_IDS.JONY,
    });

    janeCompanyId = await createCompany({
      asJony: false,
      name: 'Creator restriction Jane company',
      amountMicros: 100,
    });
    jonyCompanyId = await createCompany({
      asJony: true,
      name: 'Creator restriction Jony company',
      amountMicros: 200,
    });
  });

  afterAll(async () => {
    for (const companyId of [janeCompanyId, jonyCompanyId]) {
      if (companyId) {
        await makeGraphqlApiRequest(
          deleteOneOperationFactory({
            objectMetadataSingularName: 'company',
            gqlFields: 'id',
            recordId: companyId,
          }),
        );
      }
    }

    await updateWorkspaceMemberRole({
      client,
      roleId: originalMemberRoleId,
      workspaceMemberId: WORKSPACE_MEMBER_DATA_SEED_IDS.JONY,
    });

    if (roleId) {
      await deleteOneRole({
        expectToFail: false,
        input: { idToDelete: roleId },
      });
    }
  });

  it('hides the field on a record created by another member', async () => {
    const response = await makeGraphqlApiRequestWithMemberRole(
      findOneOperationFactory({
        objectMetadataSingularName: 'company',
        gqlFields: COMPANY_GQL_FIELDS,
        filter: { id: { eq: janeCompanyId } },
      }),
    );

    expect(response.body.errors).toBeUndefined();
    expect(response.body.data.company.annualRevenue).toBeNull();
  });

  it('returns the field on a record created by the member', async () => {
    const response = await makeGraphqlApiRequestWithMemberRole(
      findOneOperationFactory({
        objectMetadataSingularName: 'company',
        gqlFields: COMPANY_GQL_FIELDS,
        filter: { id: { eq: jonyCompanyId } },
      }),
    );

    expect(response.body.errors).toBeUndefined();
    expect(response.body.data.company.annualRevenue).toEqual({
      amountMicros: 200,
    });
  });

  it('hides the field on a record created by another member over REST', async () => {
    const response = await makeRestApiRequest({
      method: 'get',
      path: `/companies/${janeCompanyId}?fields=id,annualRevenue`,
      bearer: APPLE_JONY_MEMBER_ACCESS_TOKEN,
    });

    expect(response.body.data.company.annualRevenue).toBeNull();
  });

  it('rejects filtering on the restricted field', async () => {
    const response = await makeGraphqlApiRequestWithMemberRole(
      findOneOperationFactory({
        objectMetadataSingularName: 'company',
        gqlFields: 'id',
        filter: { annualRevenue: { amountMicros: { gt: 0 } } },
      }),
    );

    expect(response.body.errors).toBeDefined();
    expect(response.body.errors[0].message).toContain(
      'cannot be used to filter or sort',
    );
  });

  it('rejects restricting the label identifier', async () => {
    const { errors } = await upsertFieldPermissions({
      expectToFail: true,
      input: {
        roleId,
        fieldPermissions: [
          {
            objectMetadataId: companyObjectMetadataId,
            fieldMetadataId: companyNameFieldMetadataId,
            canReadFieldValue: null,
            canUpdateFieldValue: null,
            restrictFieldValueToCreator: true,
          },
        ],
      },
    });

    expect(errors).toBeDefined();
    expect(errors?.[0].message).toContain('label identifier');
  });

  it('rejects updating the field on a record created by another member', async () => {
    const response = await makeGraphqlApiRequestWithMemberRole(
      updateOneOperationFactory({
        objectMetadataSingularName: 'company',
        gqlFields: 'id',
        recordId: janeCompanyId,
        data: {
          annualRevenue: { amountMicros: 999, currencyCode: 'USD' },
        },
      }),
    );

    expect(response.body.errors).toBeDefined();
    expect(response.body.errors[0].message).toContain(
      'can only be updated on records you created.',
    );
    expect(response.body.errors[0].extensions.code).toBe(ErrorCode.FORBIDDEN);
  });

  it('allows updating the field on its own record', async () => {
    const response = await makeGraphqlApiRequestWithMemberRole(
      updateOneOperationFactory({
        objectMetadataSingularName: 'company',
        gqlFields: COMPANY_GQL_FIELDS,
        recordId: jonyCompanyId,
        data: {
          annualRevenue: { amountMicros: 300, currencyCode: 'USD' },
        },
      }),
    );

    expect(response.body.errors).toBeUndefined();
    expect(response.body.data.updateCompany.annualRevenue).toEqual({
      amountMicros: 300,
    });
  });
});
