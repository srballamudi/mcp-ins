1. INITIAL SETUP
2. Code BlockMeaningString userId = principal.getName();Get the current logged-in user.JSONObject jsonObject = null;Prepare a JSON to return to UI.if (lockId != null && !lockId.equals("") && !lockId.equals("null"))Validate lockId (must be non-empty). If invalid → nothing happens.

2. CHECK IF DB LOCKING IS ENABLED
3. Code BlockMeaningif (collaborationStoreRouter.useDbStore()) {Hybrid mode: we try DB locking first, but only if IDs are numeric.

4. 3. NUMERIC CHECK (CRITICAL PART)
  
   4. Code BlockMeaningWhy It MattersLong caseId = parseLongOrNull(lockId);Try converting lockId to a LongOnly numeric IDs belong to DB locking domain (real case IDs).Long secId = parseLongOrNull(sectionId);Try converting sectionId to a LongLegacy uses string IDs like “CASE-123”, “HEADER”.`if (caseId == nullsecId == null)`
  
   5. his is the key rule:
Numeric IDs → DB lock; Non-numeric IDs → Legacy lock.

4. DB LOCK PATH (IF IDs ARE NUMERIC)

5. Code BlockMeaningif (caseId != null && secId != null) {Both numeric → safely use DB locking.CollaborationPrincipal collaborationPrincipal = collaborationPrincipalResolver.resolve(request);Prepare DB-aware principal (session, tenant, user).result = lockService.acquire(caseId, secId, section, collaborationPrincipal, lockTtlSeconds);Try acquiring l

6. DB ACQUIRE RESULT HANDLING

Code BlockMeaningif (result.getStatus() == SUCCESS)You acquired the lock → return JSON with isLocked=true.if (result.getStatus() == CONFLICT)Someone else already holds the lock → isLocked=false.log.warn("Hybrid DB acquireLock returned ERROR...")DB error → return failure but do not fall back to legacy. Prevents split-brain.


FINAL SUPER-SHORT SUMMARY (TO REMEMBER)























ModeHow chosenWhy numeric mattersUI behaviorDB Locking (new)lockId + sectionId are numericDB lock table uses Long caseId/sectionIdModern UI (JSON-driven)Legacy Locking (old)IDs not numericLegacy screens use string IDs like “CASE-123”, “HEADER”Popup/modal-driven



















Code BlockMeaningif (result.getStatus() == SUCCESS)You acquired the lock → return JSON with isLocked=true.if (result.getStatus() == CONFLICT)Someone else already holds the lock → isLocked=false.log.warn("Hybrid DB acquireLock returned ERROR...")DB error → return failure but do not fall back to legacy. Prevents split-brain.

