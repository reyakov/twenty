import { gql } from '@apollo/client';

export const FIELD_PERMISSION_FRAGMENT = gql`
  fragment FieldPermissionFragment on FieldPermission {
    objectMetadataId
    fieldMetadataId
    canReadFieldValue
    canUpdateFieldValue
    restrictFieldValueToCreator
    id
    roleId
  }
`;
