ReleaseLock Method — Full Tabular Explanation

NITIAL SETUP













Code BlockMeaningString userId = principal.getName();Identify the current user who is trying to release the lock.

2. VALIDATE lockId













Code BlockMeaningif (lockId != null && !lockId.equals("") && !lockId.equals("null"))Only proceed if lockId is meaningful.
3. CHECK IF DB LOCKING IS ENABLED



4. NUMERIC CHECK (Routing Logic)

























Code BlockMeaningWhy It MattersLong caseId = parseLongOrNull(lockId);Convert lockId to LongDB lock table only uses numeric caseId.Long secId = parseLongOrNull(sectionId);Convert sectionId to LongLegacy strings (“CASE-123”, “HEADER”) cannot go to DB.if (caseId != null && secId != null)IDs are numeric → go to DB releasePrevents legacy UI IDs from touching DB locks.

5. DB RELEASE PATH (IDs ARE NUMERIC)

















Code BlockMeaningCollaborationPrincipal collaborationPrincipal = collaborationPrincipalResolver.resolve(request);Identify the session + tab + principal information (required for safety checks).collaborationStoreRouter.getLockService().getActiveLock(caseId, secId).ifPresent(lockRecord -> { ... })Fetch the active lock row from DB (if the lock exists).

Safety Checks (Critical)





















Code BlockMeaningsameUser = userId.equals(lockRecord.getUserId());Only the user who owns the lock can release it.sameSession = collaborationPrincipal.getCollaborationSessionId().equals(lockRecord.getCollaborationSessionId());Must be same browser session (prevents other sessions from breaking lock).sameTab = isOwnerTab(lockRecord.getBrowserTabId(), collaborationPrincipal.getEffectiveTabId());Must be same browser tab

All 3 must match:
sameUser && sameSession && sameTab

Release the Lock













Code BlockMeaninggetLockService().release(lockRecord.getLockToken(), collaborationSessionId)DB lock is removed/expired for that user’s session + tab.

SUPER SHORT SUMMARY




















ModeWhen UsedWhat Release DoesDB ReleaselockId & sectionId are numericVerify same user + same session + same tab → release lock in DBLegacy ReleaseIDs are non-numericIn-memory lock released only if current user owns it













Code BlockMeaningif (collaborationStoreRouter.useDbStore()) {Hybrid mode → try DB release path first.

