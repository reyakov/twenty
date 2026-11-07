import { currentWorkspaceMemberState } from '@/auth/states/currentWorkspaceMemberState';
import { getRecordCreatorWorkspaceMemberId } from '@/object-record/read-only/utils/getRecordCreatorWorkspaceMemberId';
import { recordStoreFamilyState } from '@/object-record/record-store/states/recordStoreFamilyState';
import { useAtomFamilyStateValue } from '@/ui/utilities/state/jotai/hooks/useAtomFamilyStateValue';
import { useAtomStateValue } from '@/ui/utilities/state/jotai/hooks/useAtomStateValue';

export const useRecordCreatorAccess = (recordId: string) => {
  const record = useAtomFamilyStateValue(recordStoreFamilyState, recordId);
  const currentWorkspaceMember = useAtomStateValue(currentWorkspaceMemberState);

  return {
    recordCreatedByWorkspaceMemberId: getRecordCreatorWorkspaceMemberId(record),
    currentWorkspaceMemberId: currentWorkspaceMember?.id,
  };
};
