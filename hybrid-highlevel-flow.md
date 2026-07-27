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
(`CaseController.acquireLock`, monolith mirrors it):

1. UI opens an editable section → `POST /acquireLock?lockId=<caseId>&sectionId=<id>&section=<name>`.
2. `parseLongOrNull(lockId)` / `parseLongOrNull(sectionId)`:
   - Both numeric → DB path (step 3).
   - Either non-numeric → **intentional fallback** to the legacy in-memory
     arbitrator (some callers legitimately pass non-numeric ids). A `log.warn`
     ("non-numeric ids, using legacy flow") makes mis-routed locks visible.
3. `CollaborationPrincipalResolver.resolve(request)` builds the caller identity:
   user id + collaboration session id + effective tab id (currently a
   session-based fallback `"sess:<sessionId>"` because the frontends don't send
   `X-Tab-Id` yet - see section 2.3).
4. `LockServiceImpl.acquire(...)` → `DbLockStore`: an **atomic claim** on
   `CASE_SECTION_LOCK` keyed by (case_id, section_id). The row stores
   lock_token, user, session, tab, and an expiry (TTL 300s,
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

`POST /releaseLock` — same id parsing and routing, then the ownership check:

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
is token-based in SQL, so a stale caller can't delete a newer lock.
`releaseAllLocks` (logout path) releases all DB locks for the user, then always
runs the legacy in-memory cleanup too.

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

- Monolith producer: `CaseServiceImpl` → `DbCaseUpdateNotificationStore.insert`
  (source_app = `MONOLITH`), log marker `CROSS_APP_NOTIFICATION queued`.
- Backend producer: `collaboration.dao.DbCaseUpdateNotificationStore.insert`
  (source_app = `BACKEND`), log marker `cross-app-queued`.

### 4.2 Consumer side - monolith (polling)

AngularJS polls its notification endpoint while a case is open. Each poll
drains the rows addressed to the current user (SELECT + DELETE, one-time
delivery) and shows them. No server-side timers.

### 4.3 Consumer side - backend (SSE stream)

ng15 opens ONE persistent SSE stream per open case
(`getCaseUpdateNotification`). In `CaseServiceImpl.startCaseNotificationHeartbeat`,
each stream gets a scheduler ticking every **3 seconds**:

```java
// every 3s tick:
//   1) drain: fetchAndDeleteNextMessage(userId) in a loop (max 20 rows/tick),
//      push each down the SSE stream as event "caseUpdateNotification"
//   2) every 5th tick (= 15s): send the keep-alive "heartbeat" ping
```

Design decisions worth knowing:

- **Drain on every tick, not just at connect.** The original implementation
  drained only at connect time — rows queued after connect sat forever. This
  was the first major bug fixed during integration testing.
- **Drain decoupled from ping.** The drain first ran on the 15s ping (avg wait
  7.5s, worst 8–9s observed). Now: drain every 3s, ping cadence unchanged at
  15s toward proxies/load balancers. Worst-case latency ≤3s, avg ~1.5s.
- **Fail-open:** a drain failure logs a warning and the stream lives on; only a
  ping failure tears the stream down (`removeCaseNotificationEmitter`).
- Per-tick cost: one indexed `FETCH FIRST 1 ROWS ONLY` on a near-empty table.

### 4.4 Cleanup of the outbox

Delivery is delete-on-read, so the table drains itself in seconds. A
safety-net job also deletes orphaned rows (recipient closed the browser before
their next poll/tick) older than 60 minutes — see section 5.

---

## 5. Background jobs (backend only - the single janitor)

`collaboration.service.CollaborationCleanupService`
(`@ConditionalOnProperty collaboration.cleanup.enabled`, default true;
`@EnableScheduling` on `CdrssApplication`):

| Job | Interval | Deletes | Property |
|---|---|---|---|
| `cleanupExpiredLocks` | 5 min | lock rows past expiry | `collaboration.cleanup.lock-interval-ms` |
| `cleanupStaleViewers` | 10 min | presence rows with heartbeat older than timeout | `collaboration.cleanup.viewer-interval-ms` |
| `cleanupOrphanedNotifications` | 15 min | outbox rows older than 60 min | `collaboration.cleanup.notification-interval-ms` / `notification-ttl-minutes` |

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

