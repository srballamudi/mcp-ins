# ReleaseLock Method — Beginner-Friendly Table

| Step | Code Block | Simple Meaning |
|---|---|---|
| 1 | `String userId = principal.getName();` | Get the name of the current user. |
| 2 | `if (lockId != null && !lockId.equals("") && !lockId.equals("null"))` | Continue only if `lockId` has a real value. |
| 3 | `if (collaborationStoreRouter.useDbStore()) {` | Check whether the app is using DB-based locking. |
| 4 | `Long caseId = parseLongOrNull(lockId);` | Try to convert `lockId` into a number. |
| 5 | `Long secId = parseLongOrNull(sectionId);` | Try to convert `sectionId` into a number. |
| 6 | `CollaborationPrincipal collaborationPrincipal = collaborationPrincipalResolver.resolve(request);` | Get session, tab, and user details from the request. |
| 7 | `sameUser = userId.equals(lockRecord.getUserId());` | Check that the same user owns the lock. |
| 8 | `sameSession = collaborationPrincipal.getCollaborationSessionId().equals(lockRecord.getCollaborationSessionId());` | Check that the same session matches. |
| 9 | `sameTab = collaborationPrincipal.getTabId().equals(lockRecord.getTabId());` | Check that the same tab matches. |
| 10 | `getLockService().release(lockRecord.getLockToken(), collaborationSessionId)` | Release the lock from the DB. |

## Quick Summary

| Mode | When It Happens | What It Does |
|---|---|---|
| DB Release | When `lockId` and `sectionId` are numbers | Checks user, session, and tab, then releases the lock. |
| Legacy Release | When IDs are not numbers | Releases the in-memory lock only. |
