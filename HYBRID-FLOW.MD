# CDRSS Hybrid Collaboration - Technical Walkthrough

A guided, code-level walk through the three collaboration flows shared by the
AngularJS monolith and the Angular 15 backend. Written for reviewers and new
developers: each flow is traced end-to-end through the actual classes, methods,
endpoints, and SQL.

Companion docs:
- `HYBRID_TECHNICAL_FLOW.md` - full reference (DDL, validation runbook, test plan)
- `HYBRID_TECH_FLOW_SUMMARY.md` - 2-page summary

---

## 1. The big picture

Two apps, one Oracle schema. The database is the ONLY integration point - there
are no REST calls or message queues between the apps.

```
+---------------------------+          +---------------------------+
|  Monolith (:9090)         |          |  Backend (:19009)         |
|  Spring MVC + AngularJS   |          |  Spring Boot + Angular 15 |
|  WAR on Tomcat            |          |                           |
+------------+--------------+          +------------+--------------+
             |                                      |
             |         shared Oracle schema         |
             +-----------------+--------------------+
                               |
              CASE_SECTION_LOCK
              CASE_VIEWER_PRESENCE
              CASE_UPDATE_NOTIFICATION
```

**Feature toggles** (rollback = flip the flag, no code change):

| App | Flag | Location |
|---|---|---|
| Monolith | `cdrss.collaboration.mode=db` | `env/config.intt.properties` |
| Backend | `collaboration.store.mode=DB` + `collaboration.enabled=true` | `application[-intt].properties` |

When the flag is off, each app falls back to its legacy in-memory behavior
(monolith: `UserAccessArbitrator`; backend: in-memory stores).

**Key packages:**

| App | Package |
|---|---|
| Monolith | `gov.doh.cdrss.caseManagement.collaboration.*` (router, services, stores, models) |
| Backend | `gov.doh.cdrss.collaboration.*` (same shape: router, services, DAO stores) |

Both sides use a `CollaborationStoreRouter` as the single decision point:
`useDbStore()` returns true only when the flag says DB mode. Every hybrid code
path starts with that check.

---

## 2. Flow 1 - Section locks

**Goal:** while user A edits a case section in either app, user B (in either
app) cannot edit the same section, and sees who holds the lock.

### 2.1 Acquire (both apps, same pattern)

Trace, using the backend as the example
(`CaseController.acquireLock`, monolith mirrors it at `CaseController.java:1691`):

1. UI opens an editable section → `POST /acquireLock?lockId=<caseId>&sectionId=<id>&section=<name>`
   → backend `CaseController.java:1901`.
2. `parseLongOrNull(lockId)` / `parseLongOrNull(sectionId)`
   (backend `CaseController.java:4452`, monolith `CaseController.java:1814`):
   - Both numeric → DB path (step 3).
   - Either non-numeric → **intentional fallback** to the legacy in-memory
     arbitrator (some callers legitimately pass non-numeric ids). A `log.warn`
     ("non-numeric ids, using legacy flow") makes mis-routed locks visible.
3. `CollaborationPrincipalResolver.resolve(request)`
   (backend `CollaborationPrincipalResolver.java:72`) builds the caller identity:
   user id + collaboration session id + effective tab id (currently a
   session-based fallback `"sess:<sessionId>"` at lines 89-93, because the
   frontends don't send `X-Tab-Id` yet - see section 2.3).
4. `LockServiceImpl.acquire(...)` → `DbLockStore.acquire` (backend
   `DbLockStore.java:107`, claim SQL at line 50; monolith `DbLockStore.java:77`):
   an **atomic claim** on `CASE_SECTION_LOCK` keyed by (case_id, section_id).
   The row stores lock_token, user, session, tab, and an expiry (TTL 300s,
   `collaboration.lock.ttl-seconds`).
5. Outcome maps to the legacy wire contract (unchanged so the existing UIs
   keep working — `isLocked` is a STRING, and means "caller acquired it"):

| Outcome | Response |
|---|---|
| Acquired | `isLocked:"true"`, lockedBy = caller, expiry minutes |
| Conflict (live lock held by someone else) | `isLocked:"false"`, lockedBy = owner, `expiry_time:-1` |
| DB error | `isLocked:"false"` — deliberately does NOT fall back to legacy (two lock systems at once = split-brain: both users could edit) |

Expired rows are treated as free: queries ignore any row past its expiry, so a
crashed browser can never hold a section hostage longer than the TTL.

### 2.2 Release

`POST /releaseLock` (backend `CaseController.java:1977`, monolith
`CaseController.java:1752`) — same id parsing and routing, then the ownership
check (backend lines 1991-2006, `sameTab` at 1994 via `isOwnerTab` helper
at 4479):

```java
getActiveLock(caseId, secId).ifPresent(lockRecord -> {
    boolean sameUser    = userId.equals(lockRecord.getUserId());
    boolean sameSession = principal.getCollaborationSessionId().equals(lockRecord.getCollaborationSessionId());
    boolean sameTab     = isOwnerTab(lockRecord.getBrowserTabId(), principal.getEffectiveTabId());
    if (sameUser && sameSession && sameTab) {
        lockService.release(lockRecord.getLockToken(), principal.getCollaborationSessionId());
    }
});
```

Only the owner (same user + session + tab) can delete the row; release itself
is token-based in SQL (backend `DbLockStore.java:152`; monolith
`DbLockStore.java:94`), so a stale caller can't delete a newer lock.
`releaseAllLocks` (logout path, backend `CaseController.java:2023` →
`DbLockStore.releaseAllByUser:165`) releases all DB locks for the user, then
always runs the legacy in-memory cleanup too.

### 2.3 Phase 1 vs Phase 2

- **Phase 1 (this release):** the tab check is a structural no-op. Neither
  frontend sends `X-Tab-Id` yet, so both acquire and release resolve the
  effective tab id to the same `"sess:<sessionId>"` fallback → `sameTab` is
  always true. Protection granularity today = user + session.
- **Phase 2 (deferred UI work):** frontends generate a per-tab id and send
  `X-Tab-Id` on every request. No server change needed — the stored and
  compared tab ids simply become real, and two tabs of one session are
  distinguished.

---

## 3. Flow 2 - Viewer presence

**Goal:** everyone with a case open sees "also viewing: ..." across both apps.

1. While a case is open, each frontend heartbeats its own app
   (monolith: request-driven poll; backend: heartbeat endpoint). Each heartbeat
   upserts a row in `CASE_VIEWER_PRESENCE`: (case_id, user_id, source_app,
   last_heartbeat).
2. "Who is viewing" reads filter **in the query**: rows older than the timeout
   (10 min, `collaboration.viewer.heartbeat-timeout-minutes`) and the
   requesting user are excluded. Staleness never depends on a cleanup job
   having run.
3. Merge behavior differs by app:
   - **Backend:** DB rows are the single source of truth.
   - **Monolith:** merges DB rows (cross-app viewers) with its legacy
     in-memory viewer list, de-duplicated — so monolith-only deployments keep
     working with the flag off.

Phase 2 impact: none — presence is per-user, not per-tab.

---

## 4. Flow 3 - Case update notifications

**Goal:** user A saves a case; every *other-app* viewer of that case gets a
toast within seconds. (Same-app viewers keep the pre-existing in-memory path -
this flow only bridges the cross-app gap.)

### 4.1 Producer side (either app saves)

On save, the saving app asks the presence table who else is viewing the case
**from the other app**, and inserts one outbox row per recipient into
`CASE_UPDATE_NOTIFICATION` (recipient_user_id, sender, section_name, message,
source_app). The sender never inserts a row for themselves (no
self-notifications).

**Backend producer — `CaseServiceImpl.java:11700-11718`** (fan-out block inside
the save-notification method). Walking the block top to bottom:

| Line | What you'll see / what to say |
|---|---|
| 11700-11701 | `getActiveViewers(caseId)` — asks the presence table who is viewing this case (both apps' viewers, already staleness-filtered) |
| 11705-11706 | `continue` when the viewer IS the editor — "we never notify the person who made the change" |
| 11708-11709 | de-dup: skips viewers already served by the local in-memory path (`deliveredLocally`), and a `HashSet` guards against double-queueing the same recipient |
| 11710 | the actual outbox write: `caseUpdateNotificationStore.insert(...)` (store method `DbCaseUpdateNotificationStore.java:41`, source_app=BACKEND) |
| 11711-11712 | audit log `CROSS_APP_NOTIFICATION queued` — the log marker used during validation |
| 11715-11717 | catch-all: "cross-app fanout must never break the local save" — a DB hiccup here logs a warning, the save still succeeds |

**Monolith producer — `CaseServiceImpl.java:10988-10989`**: same pattern —
`insert(...)` per cross-app viewer (store method at
`collaboration/store/DbCaseUpdateNotificationStore.java:41`,
source_app=MONOLITH), then the `CROSS_APP_NOTIFICATION queued` log.

### 4.2 Consumer side - monolith

The monolith UI uses `EventSource` (SSE) against its own endpoint; the endpoint
serves pending messages and completes, and `EventSource` auto-reconnects — so
in practice it behaves like a poll loop.

| Stop | File : line | What you'll see / what to say |
|---|---|---|
| 1 | `ngEditCaseCtrl.js:7298` | `GET_UPDATE_NOTIFICATION = "/cdrss/caseManagement/getCaseUpdateNotification"` — the URL constant |
| 2 | `ngEditCaseCtrl.js:7302` | `new EventSource(url, { withCredentials: true })` — opens the stream while the case is open |
| 3 | `ngEditCaseCtrl.js:7304` | `addEventListener('caseUpdateNotification', ...)` — receives the event and shows the toast |
| 4 | `CaseController.java:2824-2825` | the server endpoint — returns an `SseEmitter` per connection |
| 5 | `CaseController.java:2842` | **the cross-app drain**: `fetchAndDeleteMessages(principal.getName())` — pulls ALL outbox rows addressed to this user in one call (store method `DbCaseUpdateNotificationStore.java:55`, SELECT then DELETE by recipient = one-time delivery) |
| 6 | `CaseController.java:2853` | log marker `Cross-app case update notifications merged` — proof in the logs that backend→monolith rows were picked up |

### 4.3 Consumer side - backend (persistent SSE stream)

ng15 holds ONE long-lived SSE stream per open case. Two methods matter — the
stream setup and the per-stream scheduler. All in
`caseManagement/service/CaseServiceImpl.java`:

**Stream setup — `getCaseUpdateNotificationStream(Long caseId)` at 11346:**

| Line | What you'll see / what to say |
|---|---|
| 11350 | `new SseEmitter(timeout)` — stream created with a timeout so stale streams self-close |
| 11352-11363 | guards: invalid caseId or missing auth context → complete immediately (polling can race session refresh) |
| 11367-11370 | registers the emitter in `caseNotifEmitterCache` (per-case map keyed by userId) |
| 11380-11384 | if the same user reconnects (or opens a duplicate tab), the OLD stream's heartbeat is cancelled and the old emitter completed — one stream per user/case |
| 11387-11389 | lifecycle hooks: completion / timeout / error all route to `removeCaseNotificationEmitter` — no leak path |
| 11391 | `startCaseNotificationHeartbeat(...)` — hands the stream to the scheduler (next table) |
| 11395 | sends a `connected` event with a 5s reconnect hint for the EventSource client |

**Per-stream scheduler — `startCaseNotificationHeartbeat` at 11467**
(constants at 204-211: 15s ping, 3s tick, 5 ticks per ping):

| Line | What you'll see / what to say |
|---|---|
| 11467-11471 | method + comment block: one scheduled task per stream, ticking every 3s |
| 11485 | the drain loop: `fetchAndDeleteNextMessage(userId)` repeatedly, capped at 20 rows/tick — "this is why monolith→backend latency is ≤3s" |
| 11494 | audit log `cross-app-heartbeat-delivered` with the delivered count |
| 11508 | the ping gate: `tickCounter.incrementAndGet() % HEARTBEAT_TICKS_PER_PING == 0` — ping only every 5th tick, preserving the original 15s keep-alive cadence toward proxies |
| 11513 | ping failure → `removeCaseNotificationEmitter` + `completeWithError` — a dead client tears its own stream down |

**Cleanup — `removeCaseNotificationEmitter` at 11426** (every stream-death path
lands here):

| Line | What you'll see / what to say |
|---|---|
| 11428 | cancels the heartbeat task FIRST — "a cancelled stream must never keep pinging" |
| 11429-11437 | if the emitter registry is already gone, still clean the viewer registry and log `stream-remove-skipped` (audit trail, not silent) |
| 11439-11442 | removes this exact emitter from the per-case map; drops the map when empty |
| 11443-11445 | removes the user from the viewer registry ONLY if this exact emitter was removed — "if `removed=false`, a newer stream replaced this one, so the user is still viewing and must stay registered" |

**Also worth knowing:** the backend ALSO has a legacy polling endpoint
(`getCaseUpdateNotification(Long caseId)` at 11266). Its cross-app hook is
`fetchCrossAppNotification` at 11326 (drain call at 11331): fail-open, returns
null when the DB store is off — so polling clients get cross-app messages too.

Design decisions worth knowing:

- **Drain on every tick, not just at connect.** The original implementation
  drained only at connect time — rows queued after connect sat forever. This
  was the first major bug fixed during integration testing.
- **Drain decoupled from ping.** The drain first ran on the 15s ping (avg wait
  7.5s, worst 8–9s observed). Now: drain every 3s, ping cadence unchanged at
  15s toward proxies/load balancers. Worst-case latency ≤3s, avg ~1.5s.
- **Fail-open:** a drain failure logs a warning and the stream lives on; only a
  ping failure tears the stream down (`removeCaseNotificationEmitter`,
  `CaseServiceImpl.java:11426`).
- Per-tick cost: one indexed `FETCH FIRST 1 ROWS ONLY` on a near-empty table.

### 4.4 Cleanup of the outbox

Delivery is delete-on-read, so the table drains itself in seconds. A
safety-net job also deletes orphaned rows (recipient closed the browser before
their next poll/tick) older than 60 minutes — see section 5.

### 4.5 Removed from the PR - cross-framework navigation scaffolding

Commit `bc492d21` originally included cross-framework navigation helpers
(AngularJS `cross-framework-navigation.service.js`, an ng15
`cross-framework-navigation.service.ts`, and two empty Java placeholders
`CrossFrameworkNavigationController/Service`). They were **removed in commit
`8d5eee87`** because none were functional yet: no page loaded the JS, the .ts
had no Angular build in this repo to compile it, and the Java files were
empty. The navigation actually used by the hybrid flows comes from the
pre-existing `release/pochybrid` work (login/dashboard handoff). The helpers
will be reintroduced with the Phase 2 navigation work where they can run.

---

## 5. Background jobs (backend only - the single janitor)

`collaboration.service.CollaborationCleanupService`
(`@ConditionalOnProperty collaboration.cleanup.enabled`, default true;
`@EnableScheduling` on `CdrssApplication`):

| Job | Line | Interval | Deletes | Property |
|---|---|---|---|---|
| `cleanupExpiredLocks` | 58 | 5 min | lock rows past expiry | `collaboration.cleanup.lock-interval-ms` |
| `cleanupStaleViewers` | 77 | 10 min | presence rows with heartbeat older than timeout | `collaboration.cleanup.viewer-interval-ms` |
| `cleanupOrphanedNotifications` | 97 | 15 min | outbox rows older than 60 min (`DbCaseUpdateNotificationStore.deleteOlderThanMinutes:90`) | `collaboration.cleanup.notification-interval-ms` / `notification-ttl-minutes` |

The monolith runs **no** hybrid schedulers by design: one janitor means no
delete races between apps, and the monolith stays purely request-driven,
relying on query-side staleness filters for correctness. Every sweep interval
has a huge margin over the corresponding query-side filter, so a late (or
disabled) sweep can never cause wrong behavior — only slightly larger tables.

---

## 6. What was implemented, phase by phase

### Phase 1 (these PRs)

1. **Schema** — 3 shared tables + indexes
   (`db/migration/V001__case_collaboration_phase1_oracle.sql` in the backend;
   applied to INTT).
2. **Both apps:** collaboration package (router, principal resolver,
   lock/viewer services, DB stores) behind feature flags; legacy paths fully
   preserved.
3. **Cross-app section locks** with TTL, atomic claim, owner-checked release,
   legacy wire contract kept intact.
4. **Cross-app viewer presence** with query-side staleness and monolith
   legacy-merge.
5. **Cross-app notification bridge** (DB outbox): producers on save, polling
   consumer (monolith), SSE tick consumer with 3s drain / 15s ping (backend).
6. **Cleanup jobs** (backend): locks, viewers, orphaned notifications.
7. **Fixes found during integration testing:** SSE connect-only drain gap,
   8–9s latency (drain/ping decoupling), restored `CASE_READ` on 3 read-only
   endpoints, restored the `saveCommentsInfo` JSON escape shim, lock-flow
   observability logging.

### Phase 2 (deferred, no server changes required)

1. **`X-Tab-Id` header** from both frontends → real per-tab lock ownership
   (the server-side plumbing already stores and compares tab ids).
2. Optional hardening candidates: re-enable the backend `CorsFilter` per
   environment if a cross-origin topology returns; post-release refactor of
   `acquireLock`/`releaseLock` structure (kept as-is in Phase 1 to protect the
   legacy wire contract).

---

## 7. Five-minute verification (INTT)

```sql
-- presence rows appear while cases are open, disappear after close/timeout
SELECT case_id, user_id, source_app, last_heartbeat FROM case_viewer_presence;

-- one active lock per edited section, gone after release (or TTL)
SELECT case_id, section_id, user_id, expiry_time FROM case_section_lock;

-- outbox should drain to empty within ~3s of any save
SELECT recipient_user_id, source_app, created_date FROM case_update_notification;
```

Log markers: monolith `CROSS_APP_NOTIFICATION queued` /
`Cross-app case update notifications merged`; backend `cross-app-queued`,
`cross-app-drained`, `cross-app-stream-delivered`, `cross-app-heartbeat-delivered`.
(Monolith `gov.doh` logger must be at `info` to see them.)

---

## Appendix - Code reference index (exact file : line)

Line numbers are pinned to the PR branch heads:
backend = `feature/hybrid-lock-viewer-next` (PR 10379),
monolith = `feature/hybrid-lock-viewer-monolith-localtest-v2` (PR 10380).

### A.1 Backend (njdoh-cdrss-backend)

**`caseManagement/controller/CaseController.java`**

| Line | What |
|---|---|
| 1901 | `acquireLock(...)` - entry point, id parsing + DB/legacy routing |
| 1977 | `releaseLock(...)` - entry point |
| 1994 | `sameTab` ownership check inside release (`isOwnerTab`) |
| 2023 | `releaseUsersLock(...)` - `/releaseAllLocks` logout path |
| 1585 | `saveCommentsInfo(...)` - comments save endpoint |
| 1596-1597 | JSON escape shim (`\n`/`\r`/`<`) before Jackson parse |
| 4452 | `parseLongOrNull(...)` helper - null instead of throw (routing contract) |
| 4479 | `isOwnerTab(...)` helper - Phase 1 fallback logic |

**`caseManagement/service/CaseServiceImpl.java`**

| Line | What |
|---|---|
| 204 | `CASE_NOTIFICATION_HEARTBEAT_INTERVAL_MS = 15_000L` (ping cadence) |
| 210 | `CASE_NOTIFICATION_TICK_INTERVAL_MS = 3_000L` (drain cadence) |
| 211 | `HEARTBEAT_TICKS_PER_PING` (= 5, derived) |
| 11266 | `getCaseUpdateNotification(caseId)` - legacy POLLING endpoint (one message per call) |
| 11326 | `fetchCrossAppNotification(userId)` - cross-app hook for the polling path (drain at 11331, fail-open) |
| 11346 | `getCaseUpdateNotificationStream(caseId)` - the persistent SSE stream endpoint |
| 11367-11370 | emitter registered in `caseNotifEmitterCache`; old stream replaced on reconnect (11380-11384) |
| 11387-11389 | emitter lifecycle hooks (completion/timeout/error -> remove) |
| 11391 | `startCaseNotificationHeartbeat(...)` call |
| 11426 | `removeCaseNotificationEmitter(...)` - single cleanup path for all stream deaths |
| 11467 | `startCaseNotificationHeartbeat(...)` - the 3s tick scheduler |
| 11485 | per-tick drain loop (max 20 rows/tick) |
| 11494 | log marker `cross-app-heartbeat-delivered` |
| 11508 | ping gate: `tickCounter % HEARTBEAT_TICKS_PER_PING == 0` |
| 11700-11718 | producer fan-out block (insert at 11710, `CROSS_APP_NOTIFICATION queued` log at 11711) |

**`collaboration/dao/DbCaseUpdateNotificationStore.java`**

| Line | What |
|---|---|
| 41 | `insert(...)` - outbox row per cross-app viewer (source_app=BACKEND) |
| 64 | `fetchAndDeleteNextMessage(userId)` - oldest row, delete-on-read |
| 90 | `deleteOlderThanMinutes(ttl)` - orphan sweep SQL |

**`collaboration/dao/DbLockStore.java`**

| Line | What |
|---|---|
| 50 | `INSERT INTO case_section_lock` - atomic claim SQL |
| 72-83 | `DELETE FROM case_section_lock` variants (token release / by-user / expired) |
| 107 | `acquire(lockRecord)` |
| 152 | `release(lockToken, collaborationSessionId)` - token-based |
| 165 | `releaseAllByUser(userId)` |

**`collaboration/service/CollaborationPrincipalResolver.java`**

| Line | What |
|---|---|
| 70 | `HEADER_TAB_ID = "X-Tab-Id"` |
| 72 | `resolve(request)` - builds user/session/tab principal |
| 89-93 | Phase 2 hook + Phase 1 fallback `"sess:" + collaborationSessionId` |

**`collaboration/service/CollaborationCleanupService.java`**

| Line | What |
|---|---|
| 24 | `@ConditionalOnProperty(collaboration.cleanup.enabled)` master switch |
| 58-59 | `cleanupExpiredLocks()` - every 5 min |
| 77-78 | `cleanupStaleViewers()` - every 10 min |
| 97-98 | `cleanupOrphanedNotifications()` - every 15 min |

**Schema:** `src/main/resources/db/migration/V001__case_collaboration_phase1_oracle.sql`

### A.2 Monolith (njdoh-cdrss-monolith)

**`caseManagement/controller/CaseController.java`**

| Line | What |
|---|---|
| 1691 | `acquireLock(...)` - entry point |
| 1752 | `releaseLock(...)` - entry point |
| 1814 | `parseLongOrNull(...)` helper (with Javadoc on the routing contract) |
| 2824-2825 | `getCaseUpdateNotification(...)` - SSE endpoint serving the AngularJS EventSource |
| 2842 | cross-app drain: `fetchAndDeleteMessages(principal.getName())` |
| 2853 | log marker `Cross-app case update notifications merged` |

**`caseManagement/service/CaseServiceImpl.java`**

| Line | What |
|---|---|
| 10988 | producer: `caseUpdateNotificationStore.insert(...)` per cross-app viewer |
| 10989 | log marker `CROSS_APP_NOTIFICATION queued` |

**`caseManagement/collaboration/store/DbCaseUpdateNotificationStore.java`**

| Line | What |
|---|---|
| 41 | `insert(...)` (source_app=MONOLITH) |
| 55 | `fetchAndDeleteMessages(userId)` - drains ALL rows for the user per call |

**`caseManagement/collaboration/store/DbLockStore.java`**

| Line | What |
|---|---|
| 77 | `INSERT INTO case_section_lock` - atomic claim |
| 94 | delete by case+section (release) |
| 101 | delete by user (logout) |

**Frontend - `webapp/resources/js/cdrss/caseManagement/ngEditCaseCtrl.js`**

| Line | What |
|---|---|
| 7298 | `GET_UPDATE_NOTIFICATION = "/cdrss/caseManagement/getCaseUpdateNotification"` |
| 7302 | `new EventSource(..., { withCredentials: true })` - opens the stream |
| 7304 | `addEventListener('caseUpdateNotification', ...)` - toast handler |
| 7319-7327 | error handling / reconnect states |

> Note: line numbers drift as commits land. If a number is off after a rebase or
> merge, search the symbol name in the table instead - names are stable.

