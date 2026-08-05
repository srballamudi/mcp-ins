# CDRSS Hybrid Collaboration - Code Walkthrough Guide

A comprehensive guide for understanding how CDRSS implements cross-app collaboration during the migration period. This document contains a high-level overview followed by detailed code navigation guides.

**Estimated walkthrough time:** 15-20 minutes  
**PR References:**
- Backend: `feature/hybrid-lock-viewer-next` (PR 10379)
- Monolith: `feature/hybrid-lock-viewer-monolith-localtest-v2` (PR 10380)

---

## 🎯 Part 1: The Big Picture (Start Here)

### The Problem

CDRSS runs two separate applications during migration:
- **Monolith**: Spring MVC + AngularJS, running on Tomcat (:9090)
- **Backend**: Spring Boot + Angular 15, running on (:19009)

Users can open the **same case simultaneously in both apps**. Before this work:
- Each app only tracked "who is viewing" and "who is editing" in its own JVM memory
- A monolith user and backend user could edit the same section simultaneously
- **Result**: Silent data overwrites ❌

### The Solution: Shared Oracle Database

We use a **shared Oracle schema as the single source of truth**. No REST calls between apps, no message brokers—just three shared tables:

| Table | Purpose |
|-------|---------|
| `CASE_SECTION_LOCK` | Cross-app section edit locks (300-second TTL) |
| `CASE_VIEWER_PRESENCE` | Real-time "who has this case open" tracking |
| `CASE_UPDATE_NOTIFICATION` | Outbox for cross-app "case updated" notifications |

### Feature Flag & Rollback

**Everything is behind a feature flag:**
- Monolith: `cdrss.collaboration.mode=db`
- Backend: `collaboration.store.mode=DB`

**Rollback is instant**: Flip the config flag → both apps revert to legacy in-memory behavior. **No code redeploy needed.** ✅

### Architecture Pattern

Both apps follow the same internal structure:
1. **Store Router** – Single decision point: Use DB mode or fall back to legacy?
2. **Principal Resolver** – Identify the caller: (User + Session + Tab)
3. **Services** – Business logic for locks, viewers, notifications
4. **DB Stores** – SQL layer for the three collaboration tables

---

## 📍 Part 2: Flow 1 - Viewer Presence

**What happens:** User opens a case → system records "who is viewing"

**Key Concept:** Both apps write heartbeat rows to the same table. Each app reads from this table to see who else is viewing. Zero direct communication needed.

### Backend (ng15 app)

| Step | File : Line | What It Does |
|------|------------|-------------|
| 1 | `caseManagement/controller/CaseController.java : 439` | `getCaseInfo(...)` endpoint called when case opens. Note the new `HttpServletRequest request` parameter—this is how we identify the caller. |
| 2 | Same file : 443-446 | **Router check:** `collaborationStoreRouter.useDbStore()` — THE key pattern in this entire PR. If true → use DB collaboration. |
| 3 | Same file : 447-451 | Legacy fallback (if DB mode is OFF) — unchanged in-memory viewer tracking. Flag off = only this code runs. |
| 4 | `collaboration/service/CollaborationPrincipalResolver.java : 72` | `resolve(request)` builds the 3-part identity: (user ID, session ID, tab ID). Line 70 shows the `X-Tab-Id` header constant. |
| 5 | `collaboration/service/ViewerServiceImpl.java : 38` | `join(...)` makes joining idempotent per (case, session, tab). Also see: `heartbeat()` (line 59), `leave()` (line 79), `getActiveViewers()` (line 84). |
| 6 | `collaboration/dao/DbViewerStore.java : 51` | `MERGE INTO case_viewer_presence` — Oracle MERGE provides idempotent semantics. Reopening a case or refreshing doesn't create duplicates. |
| 7 | Same file : 39-48 | `SELECT_ACTIVE_BY_CASE` query — Notice the staleness filter in WHERE: rows with old heartbeats are **ignored at read time**. Correctness never depends on cleanup. |

### Monolith (AngularJS app)

| Step | File : Line | What It Does |
|------|------------|-------------|
| 8 | `caseManagement/controller/CaseController.java : 420-423` | Same pattern: opening a case calls `viewerService.join(caseId, collabPrincipal)`. Line 420 comment states the contract. |
| 9 | Same file : 2833 | `viewerService.heartbeat(caseId, collabPrincipal)` — sent periodically while case is open (rides the notification endpoint request). Monolith is fully request-driven; no background jobs. |
| 10 | Same file : 2801 | `viewerService.leave(caseId, collabPrincipal)` — explicit cleanup when user closes the case. |
| 11 | `caseManagement/collaboration/service/ViewerServiceImpl.java : 40, 62, 78, 91` | Four operations: `join`, `leave`, `heartbeat`, `listActiveViewerUserIds`. Mirrors the backend service. |
| 12 | `caseManagement/collaboration/store/DbViewerStore.java : 51` | `upsert(...)` — monolith uses UPDATE-then-INSERT (line 63) instead of MERGE, but same idempotent result. See also: `heartbeatBySession()` (75), `deleteBySession()` (85). |

**💡 Key Takeaway:** Both apps write heartbeat rows to `CASE_VIEWER_PRESENCE` and filter stale rows on read. Each app sees the other's viewers with zero direct communication.

---

## 🔒 Part 3: Flow 2 - Section Locks

**What happens:** User clicks into an editable section → system ensures only one editor per section

**Key Concept:** The database row IS the lock. Atomic insert = acquire, TTL = crash-safety, token-keyed delete = safe release.

### Lock Acquisition

| Step | File : Line | What It Does |
|------|------------|-------------|
| 1 | Backend `CaseController.java : 1901` | `acquireLock(...)` entry point. Routes request to either DB-backed or legacy in-memory flow. Mirrors monolith at line 1691. |
| 2 | Backend `CaseController.java : 4452` | `parseLongOrNull(...)` helper — routing decision: numeric IDs → DB flow; non-numeric → legacy fallback. Intentional routing for modal flows. |
| 3 | Backend `DbLockStore.java : 107` | `acquire(lockRecord)` — atomic INSERT into `case_section_lock`. If live lock exists → CONFLICT (return owner). If expired → treated as free. TTL ≈ 300 seconds. |
| 4 | Backend `DbLockStore.java : 43, 65-66` | **Fencing token logic** — Oracle sequence assigned at insert, incremented on renew. Provides monotonic token for concurrency correctness in Phase 2+. DDL default lets monolith insert without change. |
| 5 | Backend `CaseController.java` (acquire flow) | Response format unchanged: `"isLocked": true` = lock acquired; `"isLocked": false, "lockedBy": user` = conflict. On DB error → do NOT fall back (avoids split-brain state). |
| *Monolith* | `DbLockStore.java : 77` | Monolith side: same pattern. INSERT at line 77; mirrors backend flow. |

**Key Design:** Avoid split-brain (DB and legacy granting locks simultaneously). On DB error, fail loud not silent.

### Lock Release

| Step | File : Line | What It Does |
|------|------------|-------------|
| 6 | Backend `CaseController.java : 1977` | `releaseLock(...)` entry point. (Monolith: 1752). Routes to DB or legacy release logic. |
| 7 | Backend `CaseController.java : 1991-2006` | Ownership check: `sameUser && sameSession && sameTab` — only exact owner can release. Line 1994 uses `isOwnerTab()` helper (line 4479); uses X-Tab-Id header in Phase 2. |
| 8 | Backend `DbLockStore.java : 152` | `release(lockToken, sessionId)` — DELETE keyed by lock token. Stale/racing callers cannot delete a newer lock. |
| 9 | Backend `CaseController.java : 2023` | `releaseUsersLock` (`/releaseAllLocks` logout path) → `DbLockStore.releaseAllByUser : 165`. Also runs legacy cleanup for compatibility. |
| 10 | Monolith `DbLockStore.java : 77, 94, 101` | Monolith store: INSERT (77), release by case+section (94), release all by user on logout (101). |

**💡 Key Takeaway:** The row IS the lock. Atomic insert = acquire. TTL = crash-safety. Token-keyed delete = safe release. Wire contract unchanged—both UIs work as-is.

---

## 📢 Part 4: Flow 3 - Case Update Notifications

**What happens:** User saves a section → all viewers from the OTHER app get a toast

**Key Concept:** Transactional outbox with delete-on-read. Rows live only until delivery—table is empty at rest.

### 4a. Producer: Save & Enqueue Notifications

| Step | File : Line | What It Does |
|------|------------|-------------|
| 1 | Backend `CaseServiceImpl.java : 11700-11701` | After local in-memory notifications fan out, query presence: `getActiveViewers(caseId)` — who ELSE is viewing? (Both apps, staleness-filtered.) |
| 2 | Same file : 11705-11706 | Skip the editor themselves — no self-notifications. |
| 3 | Same file : 11708-11709 | Skip viewers served by local in-memory path. HashSet prevents double-queueing. |
| 4 | Same file : 11710-11712 | **Outbox write:** `caseUpdateNotificationStore.insert(...)` + audit log `CROSS_APP_NOTIFICATION queued` (validation marker). Store SQL in: `collaboration/dao/DbCaseUpdateNotificationStore.java`. |
| 5 | Same file : 11715-11717 | Catch block — "cross-app fanout must never break the local save." DB error = warning log, save succeeds anyway. **Fail-open by design.** |
| 6 | Monolith `CaseServiceImpl.java : 10973-10974, 10988-10989` | Monolith producer: same recipe. List active viewers (10973), then per cross-app viewer insert outbox row (10988) + same audit log. |

### 4b. Consumer: Monolith User Receives (Backend Saved)

**Scenario:** An ng15 user saved a case → monolith user should see a toast.

| Step | File : Line | What It Does |
|------|------------|-------------|
| 7 | Monolith `ngEditCaseCtrl.js : 7298` | Frontend URL constant. Included because browser side makes delivery visible—reviewers always ask "how does the toast actually appear?" |
| 8 | Same file : 7302 | `new EventSource(url, { withCredentials: true })` — AngularJS opens SSE connection while case is open. EventSource auto-reconnects = effective long-polling. |
| 9 | Same file : 7304 | `addEventListener('caseUpdateNotification', ...)` — handler that renders the toast. Error/reconnect states at 7319-7327. |
| 10 | Monolith `CaseController.java : 2824-2825` | Server endpoint backing that EventSource — returns SseEmitter per connection. |
| 11 | Monolith `CaseController.java : 2842` | **THE cross-app drain:** `fetchAndDeleteMessages(principal.getName())` — fetch ALL outbox rows for this user, delete them in one call. Store SQL in: `DbCaseUpdateNotificationStore.java`. |
| 12 | Monolith `CaseController.java : 2853` | Log marker: `Cross-app case update notifications merged` — proof in logs that backend→monolith rows were picked up. |

### 4c. Consumer: Backend User Receives (Monolith Saved)

**Scenario:** A monolith user saved a case → ng15 user should see a toast.

**Key Difference:** Backend SSE stream is long-lived, so draining must happen **during stream life**, not just at connect.

| Step | File : Line | What It Does |
|------|------------|-------------|
| 13 | Backend `CaseServiceImpl.java : 204-211` | **Cadence constants:** 15s ping (204), 3s tick (210), 5 ticks/ping (211). This split is the latency fix—originally drain rode the 15s ping (8-9s latency observed); now runs every 3s. |
| 14 | Same file : 11346 | `getCaseUpdateNotificationStream(caseId)` — SSE endpoint. Emitter created with timeout (11350); guards for bad caseId / missing auth (11352-11363). |
| 15 | Same file : 11367-11370 | Emitter registered in per-case map keyed by userId. |
| 16 | Same file : 11380-11384 | Reconnect/duplicate-tab: OLD stream's heartbeat cancelled, old emitter completed. One stream per user/case, no leaks. |
| 17 | Same file : 11387-11391 | Lifecycle hooks — completion, timeout, error ALL route to `removeCaseNotificationEmitter`. Heartbeat scheduler started. Every death path covered before stream goes live. |
| 18 | Same file : 11467 | `startCaseNotificationHeartbeat(...)` — one scheduled task per stream, ticking every 3s. |
| 19 | Same file : 11485 | **The drain loop:** `fetchAndDeleteNextMessage(userId)` repeatedly, capped at 20 rows/tick. Store SQL: `DbCaseUpdateNotificationStore.java : 64` — oldest row first (`FETCH FIRST 1 ROWS ONLY`). |
| 20 | Same file : 11494 | Audit log: `cross-app-heartbeat-delivered` with count — validation marker. |
| 21 | Same file : 11508 | **Ping gate:** `tickCounter % HEARTBEAT_TICKS_PER_PING == 0` — keep-alive only every 5th tick. Preserves original 15s cadence load balancers expect. |
| 22 | Same file : 11513 | Ping failure → remove emitter, complete with error. Dead client tears down its own stream. Drain failures = warning log (fail-open). |
| 23 | Same file : 11426-11445 | `removeCaseNotificationEmitter` — single cleanup path: cancel heartbeat FIRST (11428), tolerate already-gone registry (11429-11437), remove this exact emitter (11438-11444). |
| 24 | Same file : 11266, 11326-11331 | Also: backend's legacy POLLING endpoint got same treatment. `fetchCrossAppNotification()` (11326) drains one row per poll (11331), fail-open. Polling keeps working unchanged. |

**💡 Key Takeaway:** Rows live only seconds—written on save, deleted on delivery. Table is empty at rest; that's the health check.

**Latency:** Gap between events = delay until recipient's next connect/poll cycle (typically 2-3 seconds).

---

## 🧹 Part 5: Background Jobs & Safety Nets

**Single Source of Cleanup:** Backend only (single janitor = no delete races). Monolith stays request-driven and relies on query-side staleness filters.

Backend `collaboration/service/CollaborationCleanupService.java`:

| Step | Line | What It Does |
|------|------|-------------|
| 1 | 24 | `@ConditionalOnProperty(collaboration.cleanup.enabled)` — master kill switch (default: ON). OFF = bean never created. |
| 2 | 58-59 | `cleanupExpiredLocks()` — every 5 minutes, DELETE lock rows past expiry. Queries already ignore expired rows, so cleanup only keeps table small. |
| 3 | 77-78 | `cleanupStaleViewers()` — every 10 minutes, DELETE presence rows with heartbeats older than timeout. |
| 4 | 97-98 | `cleanupOrphanedNotifications()` — every 15 minutes, DELETE outbox rows older than 60 minutes (recipient closed browser before next tick). Sweep SQL in: `DbCaseUpdateNotificationStore.java`. |

**Error Handling:** Each job has its own try/catch—one failing sweep never stops the others.

---

## ✅ Part 6: Validation & Monitoring

### Quick SQL Checks

Run these queries to validate the system is working:

```sql
-- Who is viewing right now?
SELECT case_id, user_id, source_app, last_heartbeat 
FROM case_viewer_presence;

-- Current locks
SELECT case_id, section_id, user_id, expiry_time 
FROM case_section_lock;

-- Pending notifications (should drain to empty in ~3 seconds)
SELECT recipient_user_id, source_app, created_date 
FROM case_update_notification;
```

### Log Markers

Watch for these in application logs:

| Marker | App | Meaning |
|--------|-----|---------|
| `CROSS_APP_NOTIFICATION queued` | Monolith | Outbox row created |
| `Cross-app case update notifications merged` | Monolith | Rows delivered to monolith user |
| `cross-app-queued` | Backend | Outbox row created |
| `cross-app-heartbeat-delivered` | Backend | Rows delivered to backend user |

---

## 🎬 Part 7: Closing Points

### 1. Rollback (The Safety Net)

Flip one config flag, both apps revert to legacy in-memory behavior **instantly**:
- Monolith: `cdrss.collaboration.mode=db` → OFF
- Backend: `collaboration.store.mode=DB` → OFF

**No code redeploy. No data migration. Instant rollback.** ✅

### 2. Phase 2 (Future Work)

Small follow-up enables fencing tokens:
- Frontends send `X-Tab-Id` header (~20 lines each app)
- Tab checks become real (Part 3, step 7)
- Fencing token enforcement at save time

### 3. Troubleshooting

| Issue | Check |
|-------|-------|
| Users don't see each other's presence | `case_viewer_presence` table has recent rows; check staleness threshold in query |
| Lock conflicts not appearing cross-app | `case_section_lock` table has rows; verify feature flags are enabled |
| Toasts not appearing | `case_update_notification` table (should be empty); check SSE connection health in browser console |
| High table row counts | Cleanup jobs enabled? Check `collaboration.cleanup.enabled` flag and logs for errors |

---

## 📚 Summary in One Sentence

**The row sits in the outbox only until User A's browser next touches the notification endpoint—the server hands over ALL pending rows and deletes them in the same call, the browser's event listener turns them into a toast, and the table is empty again.**

---

## 🔍 Tips for Code Navigation

- **Line numbers may drift** after rebases/merges. If a jump lands slightly off, search the symbol name from the "What It Does" column—names are stable.
- **Always check the feature flag first** before diving into a flow (decide DB vs. legacy).
- **Look for the router pattern:** `if (useDbStore())` appears everywhere—this is THE branching point.
- **Follow the audit logs:** They tell you exactly which path executed.
- **Split-brain prevention:** DB errors don't fall back to legacy—this prevents both systems from granting locks/visibility simultaneously.
