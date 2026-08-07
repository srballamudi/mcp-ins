# FLOW A Deep-Dive — Verifying `resolve()` → `join()` → What Happens Next

**Companion to:** `HYBRID-FLOW.MD` (concepts) and `END-TO-END-REQUEST-FLOW.md` (all flows).
This doc zooms into ONE question: *how do I confirm the request actually travels from
`CollaborationPrincipalResolver.resolve(request)` into `ViewerServiceImpl.join(...)`,
and what is the next call after `join()`?*

**Last updated:** 2026-08-07

---

## 1. The Call Chain (Static Code Trace)

Both calls live back-to-back in **the same method** — `CaseController.getCaseInfo()` (~line 443-446):

```java
// CaseController.getCaseInfo(...)
if (collaborationStoreRouter.useDbStore()) {                                        // gate
    CollaborationPrincipal collaborationPrincipal =
            collaborationPrincipalResolver.resolve(request);                        // ① resolve
    collaborationStoreRouter.getViewerService()
            .join(caseId, collaborationPrincipal, ViewerService.DeliveryMode.BOTH); // ② join
}
```

Key facts that make the hop guaranteed:

- The object returned by ① (`collaborationPrincipal`) is passed **directly as the argument** to ②.
- There is **no queue / async hop / event bus** in between — same thread, same HTTP request.
- `getViewerService()` always returns the DB-backed `ViewerServiceImpl` (Phase 1).
- Therefore: **if `resolve()` ran and did not throw, `join()` WILL run.**

---

## 2. What Happens Next After `join()` — Full Sequence

```
HTTP GET /getCaseInfo?caseId=123&diseaseId=45
  → CaseController.getCaseInfo()                       [~line 439]
    → router.useDbStore()                              (flag check: collaboration.store.mode)
    → resolver.resolve(request)                        (build CollaborationPrincipal)
    → ViewerServiceImpl.join(caseId, principal, BOTH)  [line 38]
      │  builds CaseViewerPresenceRecord:
      │    userId, auhId, collaborationSessionId, browserTabId,
      │    clientType, deliveryMode="BOTH", joinedAt = lastHeartbeatAt = now
      │
      → viewerStore.upsert(presenceRecord)             [line 55]   ← NEXT CALL after record build
        → DbViewerStore.upsert()                       [~line 140]
          → jdbcTemplate.update(UPSERT_VIEWER)
            → Oracle: MERGE INTO case_viewer_presence
                 ON (case_id, collaboration_session_id, browser_tab_id)
                 MATCHED     → UPDATE (refresh heartbeat, auh_id, delivery_mode…)
                 NOT MATCHED → INSERT (new row, viewer_id from sequence)
          → re-SELECT the row (SELECT_BY_KEY) and return persisted record
    → caseService.getCaseInfo(caseId, diseaseId)       ← NEXT CALL after join() returns
      → loads sections / patient info / case payload
  → JSONArray response to browser (case renders)
```

Two "next calls" depending on the level you ask at:

| After… | Next call | File : Line |
|---|---|---|
| `join()` builds the record | `viewerStore.upsert(presenceRecord)` | `ViewerServiceImpl.java : 55` |
| `join()` returns to controller | `caseService.getCaseInfo(caseId, diseaseId)` | `CaseController.java : ~453` |
| the case renders in browser | FLOW B: polling `GET /getCaseUpdateNotification?caseId=…` (doubles as heartbeat) or SSE stream open | `CaseController.java : ~3147 / ~3168` |

**Key point:** the collaboration part (`join`) finishes **before** case data is even fetched —
presence registration is a side effect on the way in. `ViewerServiceImpl` is `@Transactional`,
so the MERGE commits when `join()` returns.

---

## 3. Runtime Verification — Three Ways to PROVE the Hop Executed

### Method A — Log Correlation (easiest, no code change)

Enable debug logging:

```properties
logging.level.gov.doh.cdrss.collaboration=DEBUG
```

Open a case and look for this sequence with the **same timestamp/thread**:

```
DEBUG CollaborationPrincipalResolver - Using existing HTTP session ID: A1B2C3…          ← inside resolve()
DEBUG CollaborationPrincipalResolver - Resolved collaboration principal: userId=jdoe,
      auhId=456, authModel=SESSION, collaborationSessionId=A1B2C3…, browserTabId=sess:… ← resolve() finished
```

Then confirm `join()` completed via its **only side effect** — the DB row:

```sql
SELECT user_id, auh_id, collaboration_session_id, browser_tab_id,
       delivery_mode, joined_at, last_heartbeat_at
  FROM case_viewer_presence
 WHERE case_id = 123;
```

A fresh row (or refreshed `last_heartbeat_at`) whose `collaboration_session_id` **matches the
session ID printed by the resolver's debug log** = proof the same principal flowed
`resolve()` → `join()` → MERGE.

### Method B — Debugger (most direct)

Set two breakpoints in IntelliJ:

| # | File | Line | Method |
|---|---|---|---|
| 1 | `CollaborationPrincipalResolver.java` | 72 | `resolve()` entry |
| 2 | `ViewerServiceImpl.java` | 38 | `join()` entry |

Open a case in the browser → breakpoint 1 hits → Resume → breakpoint 2 hits.
Inspect the `principal` parameter at breakpoint 2 — it is the **exact same object**
built at breakpoint 1 (verify by object ID in the debugger).

### Method C — Temporary Log at `join()` Entry (when no debugger available)

```java
// ViewerServiceImpl.join(...) — first line, TEMPORARY
log.info("VIEWER_JOIN caseId={} userId={} sessionId={} tabId={} auhId={}",
    caseId, principal.getUserId(), principal.getCollaborationSessionId(),
    principal.getEffectiveTabId(), principal.getAuhId());
```

One `GET /getCaseInfo` → one `VIEWER_JOIN` log line carrying the resolved values —
a single line proving the full hop with the actual data.

---

## 4. The ONE Case Where `resolve()` Runs but `join()` Does NOT

`resolve()` can **throw** in two places:

| Exception | Thrown when |
|---|---|
| `IllegalStateException: missing authentication context` | `SecurityContextHolder` has no `Authentication` (unauthenticated/misconfigured filter chain) |
| `IllegalStateException: missing userId` | principal is not a `CustomUserDetails` AND `authentication.getName()` is blank |

When that happens:

- the exception propagates out of `getCaseInfo`'s try-block → `join()` never executes
- the controller's catch logs it: `log.info(exe.toString())`
- **no row** appears in `case_viewer_presence`

**Diagnostic rule:** *exception in logs + no presence row = flow broke between ① and ②.*

---

## 5. Quick Checklist (Copy-Paste Runbook)

```
[ ] 1. Flag on?          grep collaboration.store.mode application*.properties   → DB
[ ] 2. Debug log on?     logging.level.gov.doh.cdrss.collaboration=DEBUG
[ ] 3. Open a case       GET /getCaseInfo?caseId=<id>&diseaseId=<id>
[ ] 4. See resolver log? "Resolved collaboration principal: userId=…, auhId=…"
[ ] 5. See DB row?       SELECT * FROM case_viewer_presence WHERE case_id=<id>
[ ] 6. Session IDs match between log (step 4) and row (step 5)?
        YES → resolve() → join() → MERGE confirmed ✔
        NO row + exception in log → resolve() threw; join() never ran ✘
```

---

## 6. Related Log Markers

```
Using explicit X-Collab-Session-Id header: …          resolve(): priority-1 session id
Using existing HTTP session ID: …                     resolve(): priority-2 session id
Derived stable session ID for stateless JWT: …        resolve(): priority-3 (JWT path)
Generated fallback random session ID: …               resolve(): priority-4 (WARN, id churn!)
Resolved collaboration principal: userId=…, auhId=…   resolve() completed successfully
auhId unresolved for user=… (principal type=…)        auh_id will be NULL (WARN, 2026-08-06)
```

