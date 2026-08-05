# CDRSS Hybrid Collaboration - Code Walkthrough Script

A presenter's script for walking the team through the hybrid collaboration code,
end to end. Part 1 is the high-level picture (say this first, no code open).
Parts 2-5 are ordered jump lists: open the file, go to the line (Ctrl+G in
IntelliJ), and the "Purpose" column tells you what that method/line does and
why it exists.

All line numbers verified against the PR branch heads:
- Backend = `feature/hybrid-lock-viewer-next` (PR 10379)
- Monolith = `feature/hybrid-lock-viewer-monolith-localtest-v2` (PR 10380)

---

## Part 1 - High-level description (2 minutes, no code)

CDRSS runs as two applications during the migration period:

- **Monolith** - Spring MVC + AngularJS, WAR on Tomcat (:9090)
- **Backend** - Spring Boot + Angular 15 (:19009)

Users on BOTH apps can open the same case at the same time. Before this work,
each app tracked "who is viewing" and "who is editing" only in its own JVM
memory - so a monolith user and an ng15 user could edit the same section
simultaneously and silently overwrite each other.

**The hybrid model fixes that using the shared Oracle schema as the only
integration point.** No REST calls between apps, no message broker. Three
shared tables:

| Table | Feature |
|---|---|
| `CASE_SECTION_LOCK` | cross-app section edit locks (TTL 300s) |
| `CASE_VIEWER_PRESENCE` | who has which case open (heartbeat rows) |
| `CASE_UPDATE_NOTIFICATION` | outbox for cross-app "case updated" toasts |

Everything is behind a feature flag (monolith `cdrss.collaboration.mode=db`,
backend `collaboration.store.mode=DB`). Flag off = each app falls back to its
old in-memory behavior. Rollback is a config flip, no code change.

Both apps have the same internal shape: a **store router** (single decision
point: DB mode or legacy?), a **principal resolver** (who is calling: user +
session + tab), **services** (lock/viewer business rules), and **DB stores**
(the SQL). The walkthrough below follows a user's actual journey: open a case
-> presence; edit a section -> lock; save -> notification; background cleanup.

---

## Part 2 - Flow 1: Viewer presence ("who else has this case open")

The journey starts when a user opens a case.

### Backend (user opens a case in ng15)

| # | File : line | Purpose - what to say here |
|---|---|---|
| 1 | `caseManagement/controller/CaseController.java : 439` | `getCaseInfo(...)` - the endpoint hit when a case is opened. Note the added `HttpServletRequest request` parameter - needed so we can resolve session/tab identity (Principal alone only gives the username). |
| 2 | same file : 443-446 | The router check `collaborationStoreRouter.useDbStore()` - THE pattern of this whole PR: every hybrid path starts with this if. True -> resolve the CollaborationPrincipal and `viewerService.join(...)` writes a presence row. |
| 3 | same file : 447-451 | The else branch - legacy in-memory viewer tracking, byte-for-byte the old behavior. Flag off = this code path, nothing else. |
| 4 | `collaboration/service/CollaborationPrincipalResolver.java : 72` | `resolve(request)` - builds the 3-part identity (user, collaboration session id, tab id). Line 70: the `X-Tab-Id` header constant. Lines 89-93: Phase 1 fallback - no header yet, so tab id = `"sess:<sessionId>"`. |
| 5 | `collaboration/service/ViewerServiceImpl.java : 38` | `join(...)` - business rule: joining is idempotent per (case, session, tab). Also see `heartbeat` (59), `leave` (79), `getActiveViewers` (84). |
| 6 | `collaboration/dao/DbViewerStore.java : 51` | The `MERGE INTO case_viewer_presence` upsert - comment on line 50 says it: "Oracle MERGE provides idempotent join semantics". Reopening/refreshing never creates duplicate rows. |
| 7 | same file : 39-48 | `SELECT_ACTIVE_BY_CASE` - the "who is viewing" query. Point out the staleness filter in the WHERE clause: rows with old heartbeats are ignored AT READ TIME - correctness never waits for a cleanup job. |

### Monolith (user opens a case in AngularJS)

| # | File : line | Purpose - what to say here |
|---|---|---|
| 8 | `caseManagement/controller/CaseController.java : 420-423` | Same pattern, monolith side: opening a case calls `viewerService.join(caseId, collabPrincipal)`. The comment at 420 states the contract: presence is what lets cross-app saves find this user later. |
| 9 | same file : 2833 | `viewerService.heartbeat(caseId, collabPrincipal)` - refreshed while the case stays open (rides the notification endpoint request - the monolith is fully request-driven, no timers). |
| 10 | same file : 2801 | `viewerService.leave(caseId, collabPrincipal)` - explicit removal when the user closes the case. |
| 11 | `caseManagement/collaboration/service/ViewerServiceImpl.java : 40 / 62 / 78 / 91` | The four operations: `join`, `leave`, `heartbeat`, `listActiveViewerUserIds`. Mirrors the backend service - same shape, monolith package. |
| 12 | `caseManagement/collaboration/store/DbViewerStore.java : 51` | `upsert(...)` - monolith uses try-UPDATE-then-INSERT (63) instead of MERGE; same idempotent result. `heartbeatBySession` (75), `delete` (93), `listActiveViewerUserIds` (100). |

**Wrap-up line for this flow:** both apps write heartbeat rows to the same
table and filter stale rows in the query - so each app "sees" the other's
viewers with zero direct communication.

---

## Part 3 - Flow 2: Section locks ("one editor per section")

The journey continues: the user clicks into an editable section.

### Acquire (backend example; monolith is the same pattern)

| # | File : line | Purpose - what to say here |
|---|---|---|
| 1 | backend `CaseController.java : 1901` | This is the main entry point for lock acquisition.
It mirrors the monolith’s CaseController.java:1691, ensuring identical API behavior.
The controller routes the request into either the DB collaboration lock flow or the legacy in‑memory lock flow depending on configuration and input format. |
| 2 | backend `CaseController.java : 4452` | `This helper converts request parameters into numeric IDs.
Its behavior is intentional:

Numeric IDs → DB collaboration lock flow
Non‑numeric IDs → legacy in‑memory arbitrator

Some callers legitimately send non‑numeric section IDs (modals, older screens), so this is routing logic, not validation.
The monolith uses the same approach (mirror at approx. line 1814).|
| 3 | backend `DbLockStore.java : 107` | `acquire(lockRecord)` - the atomic claim. Insert SQL at line 50: one row per (case_id, section_id) with lock_token, user, session, tab, expiry (TTL 300s). If a LIVE row already exists -> conflict, return the current owner. Expired rows are treated as free. |
| 4 | backend `DbLockStore.java : 43 + 65-66` | `fencing_token` column: filled by an Oracle sequence on insert, bumped via `NEXTVAL` on renew (comment at 65: "monotonic fencing token per renew"). Phase 1 stores it; enforcement at save-time is a later phase. The DDL DEFAULT lets the monolith insert rows without knowing about it. |
| 5 | back in `CaseController.java` acquire method | The response contract - unchanged from legacy so no UI changes were needed: `isLocked` is a STRING meaning "caller GOT the lock" (`"true"` = acquired; `"false"` + lockedBy = conflict). On DB error we return failure WITHOUT falling back to legacy - two lock systems at once would let two users edit (split-brain). |

### Release

| # | File : line | Purpose - what to say here |
|---|---|---|
| 6 | backend `CaseController.java : 1977` | `releaseLock(...)` - entry point. (Monolith mirror: `:1752`.) |
| 7 | backend `CaseController.java : 1991-2006` | The ownership check: `sameUser && sameSession && sameTab` - only the exact owner may release. `sameTab` (1994) uses `isOwnerTab` (helper at 4479); in Phase 1 both sides resolve the tab to the same session fallback, so it cannot fail yet - it becomes real when the UIs send `X-Tab-Id` (Phase 2, ~20 lines per frontend, no server change). |
| 8 | backend `DbLockStore.java : 152` | `release(lockToken, sessionId)` - the DELETE is keyed by lock token, so even a racing stale caller cannot delete a newer lock. |
| 9 | backend `CaseController.java : 2023` | `releaseUsersLock` (`/releaseAllLocks`, logout path) -> `DbLockStore.releaseAllByUser : 165`. Then ALWAYS runs the legacy in-memory cleanup too - without this, a logged-out user's DB locks would block others for up to 300s. |
| 10 | monolith `DbLockStore.java : 77 / 94 / 101` | Monolith's store: insert claim (77), release by case+section (94), release all by user on logout (101). |

**Wrap-up line:** the lock row IS the lock. Atomic insert = acquire, TTL =
crash-safety, token-keyed delete = safe release, and the wire contract is
unchanged so both existing UIs work as-is.

---

## Part 4 - Flow 3: Case update notifications ("someone changed the case you're viewing")

The journey continues: the user saves a section. Every viewer from the OTHER
app must get a toast. Pattern: transactional outbox with delete-on-read.

### 4a. Producer (the app that saves)

| # | File : line | Purpose - what to say here |
|---|---|---|
| 1 | backend `CaseServiceImpl.java : 11700-11701` | After the local (in-memory) notification fan-out, ask the presence table: `getActiveViewers(caseId)` - who ELSE is viewing (both apps, staleness-filtered). |
| 2 | same file : 11705-11706 | Skip the editor themselves - no self-notifications. |
| 3 | same file : 11708-11709 | Skip viewers already served by the local in-memory path, and a HashSet prevents double-queueing a recipient. |
| 4 | same file : 11710-11712 | The outbox write: `caseUpdateNotificationStore.insert(...)` + audit log `CROSS_APP_NOTIFICATION queued` (the marker used during validation). Store SQL: `collaboration/dao/DbCaseUpdateNotificationStore.java : 41`, source_app=BACKEND. |
| 5 | same file : 11715-11717 | The catch block - "cross-app fanout must never break the local save". DB hiccup = warning, save still succeeds. Fail-open by design. |
| 6 | monolith `CaseServiceImpl.java : 10973-10974 + 10988-10989` | The monolith producer, same recipe: list active viewers (10973), then per cross-app viewer insert the outbox row (10988) + the same audit log (10989). Store: `collaboration/store/DbCaseUpdateNotificationStore.java : 41`, source_app=MONOLITH. |

### 4b. Consumer - monolith user receives (backend saved)
Delivery to a monolith viewer (scenario: an ng15 user saved the case)---

| # | File : line | Purpose - what to say here |
|---|---|---|
| 7 | monolith `ngEditCaseCtrl.js : 7298` | Frontend: the endpoint URL constant. Included because the browser side is where delivery becomes visible - reviewers always ask "how does the toast actually appear?". |
| 8 | monolith `ngEditCaseCtrl.js : 7302` | `new EventSource(url, { withCredentials: true })` - AngularJS opens an SSE connection while the case is open; EventSource auto-reconnects, which effectively makes this a poll loop. |
| 9 | monolith `ngEditCaseCtrl.js : 7304` | `addEventListener('caseUpdateNotification', ...)` - the handler that renders the toast. (Error/reconnect states: 7319-7327.) |
| 10 | monolith `CaseController.java : 2824-2825` | The server endpoint behind that EventSource - returns an SseEmitter per connection. |
| 11 | monolith `CaseController.java : 2842` | THE cross-app drain: `fetchAndDeleteMessages(principal.getName())` - fetch ALL outbox rows addressed to this user, in one call. Store SQL: `DbCaseUpdateNotificationStore.java : 55` - SELECT then DELETE by recipient = one-time delivery. |
| 12 | monolith `CaseController.java : 2853` | Log marker `Cross-app case update notifications merged` - your proof in the logs that backend->monolith rows were picked up. |

### 4c. Consumer - backend user receives (monolith saved)
Delivery to a backend/ng15 viewer (scenario: a monolith user saved the case)-----

The interesting side: ng15 holds ONE long-lived SSE stream per open case, so
draining must happen DURING the stream's life, not just at connect. All in
backend `CaseServiceImpl.java`:

| # | File : line | Purpose - what to say here |
|---|---|---|
| 13 | : 204-211 | The cadence constants: 15s ping (204), 3s tick (210), 5 ticks/ping (211). This split is the latency fix - originally the drain rode the 15s ping (8-9s observed latency); now it runs every 3s while the ping cadence toward proxies is unchanged. |
| 14 | : 11346 | `getCaseUpdateNotificationStream(caseId)` - the SSE endpoint. Emitter created with a timeout (11350); guards for bad caseId / missing auth (11352-11363). |
| 15 | : 11367-11370 | Emitter registered in a per-case map keyed by userId. |
| 16 | : 11380-11384 | Reconnect/duplicate-tab handling: the OLD stream's heartbeat is cancelled and the old emitter completed - one stream per user/case, no leaks. |
| 17 | : 11387-11391 | Lifecycle hooks - completion/timeout/error ALL route to `removeCaseNotificationEmitter`; then the heartbeat scheduler is started. Every death path is covered before the stream goes live. |
| 18 | : 11467 | `startCaseNotificationHeartbeat(...)` - one scheduled task per stream, ticking every 3s. |
| 19 | : 11485 | The drain loop: `fetchAndDeleteNextMessage(userId)` repeatedly, capped at 20 rows/tick. Store SQL: `DbCaseUpdateNotificationStore.java : 64` - oldest row first (`FETCH FIRST 1 ROWS ONLY`), delete by notification_id. This line is WHY monolith->backend latency is <=3s. |
| 20 | : 11494 | Audit log `cross-app-heartbeat-delivered` with the count - the validation marker. |
| 21 | : 11508 | The ping gate: `tickCounter % HEARTBEAT_TICKS_PER_PING == 0` - keep-alive only every 5th tick, preserving the original 15s cadence load balancers expect. |
| 22 | : 11513 | Ping failure -> remove emitter + `completeWithError` - a dead client tears down its own stream. Drain failures, by contrast, only log a warning (fail-open). |
| 23 | : 11426-11445 | `removeCaseNotificationEmitter` - the single cleanup path: cancel heartbeat FIRST (11428), tolerate already-gone registry with an audit log (11429-11437), remove this EXACT emitter (11439), and only unregister the viewer if this emitter was current (11443-11445) - a replaced stream must not kick a still-active viewer. |
| 24 | : 11266 + 11326-11331 | Also mention: the backend's legacy POLLING endpoint got the same treatment - `fetchCrossAppNotification` (11326) drains one outbox row per poll (11331), fail-open. Poll clients get cross-app messages too. |

**Wrap-up line:** rows live seconds - written on save, deleted on delivery.
The table is empty at rest; that's the health check.

---

## Part 5 - Background jobs and safety nets

All scheduled cleanup lives in the BACKEND ONLY (single janitor = no delete
races; the monolith stays request-driven and relies on the query-side
staleness filters you saw in Part 2 stop 7).

Backend `collaboration/service/CollaborationCleanupService.java`:

| # | Line | Purpose - what to say here |
|---|---|---|
| 1 | 24 | `@ConditionalOnProperty(collaboration.cleanup.enabled)` - master kill switch; default true. Off = the bean is never created. |
| 2 | 58-59 | `cleanupExpiredLocks()` - every 5 min, delete lock rows past expiry. Queries already ignore expired rows, so this only keeps the table small. |
| 3 | 77-78 | `cleanupStaleViewers()` - every 10 min, delete presence rows with heartbeats older than the timeout. |
| 4 | 97-98 | `cleanupOrphanedNotifications()` - every 15 min, delete outbox rows older than 60 min (recipient closed the browser before their next tick). Sweep SQL: `DbCaseUpdateNotificationStore.java : 90`. 60 min vs <=3s normal delivery = a 1200x margin; the sweep can never race a live drain. |

Each job has its own try/catch - one failing sweep never stops the others.

---

## Part 6 - Closing points (1 minute)

1. **Rollback**: flip `cdrss.collaboration.mode` / `collaboration.store.mode` -
   both apps instantly revert to legacy in-memory behavior. No redeploy.
2. **Phase 2** (deferred, small): frontends send `X-Tab-Id` (~20 lines each
   app) -> the tab checks you saw in Part 3 stop 7 become real; and fencing
   token enforcement at save time.
3. **Validation** (live demo if time allows):
   ```sql
   SELECT case_id, user_id, source_app, last_heartbeat FROM case_viewer_presence;
   SELECT case_id, section_id, user_id, expiry_time    FROM case_section_lock;
   SELECT recipient_user_id, source_app, created_date  FROM case_update_notification; -- drains to empty in ~3s
   ```
   Log markers: `CROSS_APP_NOTIFICATION queued` / `...merged` (monolith),
   `cross-app-queued` / `cross-app-heartbeat-delivered` (backend).


**One-sentence summary for the walkthrough: "The row sits in the outbox only until User A's browser next touches the notification endpoint —
the server hands over ALL pending rows and deletes them in the same call, 
the browser's event listener turns them into a toast, and the table is empty again.**"

Timing
The latency for this direction = the gap until User A's next connect/poll cycle — a few seconds, 
similar to the backend's 3s tick in the reverse direction.

> Line numbers drift after rebases/merges - if a jump lands slightly off,
> search the symbol name from the Purpose column; names are stable.

