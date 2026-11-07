import { type ObjectRecord } from 'twenty-shared/types';

export const getRecordCreatorWorkspaceMemberId = (
  record: ObjectRecord | null | undefined,
): string | undefined => {
  const createdBy = record?.createdBy;

  if (
    typeof createdBy !== 'object' ||
    createdBy === null ||
    !('workspaceMemberId' in createdBy)
  ) {
    return undefined;
  }

  const workspaceMemberId = createdBy.workspaceMemberId;

  return typeof workspaceMemberId === 'string' ? workspaceMemberId : undefined;
};
