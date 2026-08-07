# CDRSS Hybrid Collaboration — End-to-End Request Flow

**Companion to:** `HYBRID-FLOW.MD` (that doc explains *concepts per flow*; this doc traces *complete request journeys* from browser → controller → resolver → service → SQL → shared table → the other app's browser).

**Last updated:** 2026-08-06
**Code base:** Backend (Spring Boot + Angular 15) — files under `gov.doh.cdrss.*`

---

## 0. Cast of Characters (Who Does What)

| Layer | Class | Role |
|---|---|---|
| REST entry | `caseManagement/controller/CaseController.java` | All collaboration endpoints: `/getCaseInfo`, `/acquireLock`, `/releaseLock`, `/releaseAllLocks`, `/removeCaseViewer`, `/getCaseUpdateNotification` (+ `?stream=true` SSE variant) |
| Feature flag | `collaboration/service/CollaborationStoreRouter.java` | THE branch point: `useDbStore()` reads `collaboration.store.mode` (default `DB`). Every endpoint asks it first |
| Identity | `collaboration/service/CollaborationPrincipalResolver.java` | Builds `CollaborationPrincipal` = (userId, auhId, collaborationSessionId, browserTabId, clientType, authModel) from the HTTP request + Spring Security context |
| Identity model | `collaboration/model/CollaborationPrincipal.java` | Immutable carrier of the resolved identity (builder pattern) |
| Viewer logic | `collaboration/service/ViewerServiceImpl.java` | `join` / `heartbeat` / `leave` / `getActiveViewers` / `cleanupStaleViewers` |
| Lock logic | `collaboration/service/LockServiceImpl.java` | `acquire` (with conflict + race handling) / `renew` / `release` / `releaseAllByUser` / `getActiveLock` |
| Viewer SQL | `collaboration/dao/DbViewerStore.java` | Oracle `MERGE` upsert into `case_viewer_presence`; staleness-filtered reads |
| Lock SQL | `collaboration/dao/DbLockStore.java` | Atomic INSERT into `case_section_lock`; token-keyed release; fencing token sequence |
| Outbox SQL | `collaboration/dao/DbCaseUpdateNotificationStore.java` | INSERT / fetch-and-delete on `case_update_notification` |
| Save-side fanout | `caseManagement/service/CaseServiceImpl.java` | Local SSE fanout, cross-app outbox producer, SSE drain heartbeat, polling drain |
| Janitor | `collaboration/service/CollaborationCleanupService.java` | Scheduled sweeps of all three tables (backend only) |
| Login identity | `login/service/CustomUserDetails.java` | Spring Security principal for session logins; carries `userId`, `auhId`, `profileId`, … |
| CORS / security | `config/SecurityConfig.java` | Whitelists collaboration headers: `Auhid`, `X-Tab-Id` |

**Three shared Oracle tables** (single source of truth for both apps):

| Table | Written by | Read by | Row lifetime |
|---|---|---|---|
| `case_viewer_presence` | both apps on open/heartbeat | both apps for fanout | until leave / stale sweep (10 min) |
| `case_section_lock` | both apps on section edit | both apps on acquire attempt | until release / TTL 300s / sweep (5 min) |
| `case_update_notification` | both apps on save | both apps' drain endpoints | **seconds** — delete-on-read; orphan sweep (60 min) |

---

## 1. FLOW A — User Opens a Case (Viewer Presence Registration)

**Scenario:** ng15 user clicks a case in the worklist.

```
Browser (Angular 15)
  │  GET /getCaseInfo?caseId=123&diseaseId=45
  │  Headers: Authorization: Bearer <jwt>   (or JSESSIONID cookie for session auth)
  ▼
CaseController.getCaseInfo(caseId, diseaseId, principal, request)          [~line 439]
  │
  ├─ 1. collaborationStoreRouter.useDbStore()?                              [~line 443]
  │       reads collaboration.store.mode (default DB) → true
  │
  ├─ 2. collaborationPrincipalResolver.resolve(request)                     [~line 445]
  │       │
  │       ├─ SecurityContextHolder.getContext().getAuthentication()
  │       │     null → IllegalStateException (fail fast, no anonymous collab)
  │       │
  │       ├─ isJwtRequest(request)?  "Authorization: Bearer …" present?
  │       │     yes → authModel=JWT,     clientType=ANGULAR15
  │       │     no  → authModel=SESSION, clientType=ANGULARJS
  │       │
  │       ├─ collaborationSessionId — priority chain:
  │       │     1. X-Collab-Session-Id header (validated: ≤128 chars, [A-Za-z0-9-:._])
  │       │     2. request.getRequestedSessionId()  (HTTP session)
  │       │     3. JWT: "<userId>:browser:<hash(User-Agent)>"  (stable fingerprint)
  │       │     4. random UUID (WARN logged — heartbeat continuity breaks)
  │       │
  │       ├─ browserTabId = X-Tab-Id header  ∥  "sess:<collaborationSessionId>"
  │       │     (Phase 1: header not sent → always the "sess:" fallback)
  │       │
  │       ├─ userId  = CustomUserDetails.getUserId() ∥ authentication.getName()
  │       │
  │       └─ auhId   = resolveAuhId(request, authentication)     ← CHANGED 2026-08-06
  │             1. CustomUserDetails.getAuhId() if non-null      (session logins)
  │             2. "Auhid" request header parsed as Long          (JWT fallback)
  │             3. null + WARN log with principal type            (traceable)
  │
  ├─ 3. viewerService.join(caseId, principal, DeliveryMode.BOTH)            [~line 446]
  │       │  ViewerServiceImpl.join()                              [line 38]
  │       │    builds CaseViewerPresenceRecord:
  │       │      caseId, userId, auhId, collaborationSessionId,
  │       │      browserTabId, clientType,
  │       │      deliveryMode = "BOTH"   ← null-guard: defaults to BOTH
  │       │      joinedAt = lastHeartbeatAt = now
  │       │
  │       └─ DbViewerStore.upsert(record)                          [line ~140]
  │             MERGE INTO case_viewer_presence
  │               ON (case_id, collaboration_session_id, browser_tab_id)
  │               MATCHED     → UPDATE user_id, auh_id, client_type,
  │                              delivery_mode, last_heartbeat_at
  │               NOT MATCHED → INSERT (viewer_id from sequence, all columns)
  │             ⇒ reopening / refreshing NEVER duplicates a row
  │
  └─ 4. return caseService.getCaseInfo(caseId, diseaseId)  — normal case payload
```

**If the flag is OFF** (`collaboration.store.mode=IN_MEMORY`): step 2-3 are skipped entirely; legacy `caseService.insertCaseViewer(caseId, userId)` runs (JVM-local hashtable). *Instant rollback, no redeploy.*

**Monolith mirror:** same table, same MERGE-equivalent (UPDATE-then-INSERT). Each app *sees the other's viewers* purely by reading the shared table — zero direct communication.

### Data lineage — why a column can be NULL here

| Column | Source chain | NULL when… |
|---|---|---|
| `auh_id` | `CustomUserDetails.auhId` → `CollaborationPrincipal` → record → MERGE | login flow never called `setAuhId(...)`, **or** JWT principal isn't a `CustomUserDetails` and the UI doesn't send the `Auhid` header (pre-2026-08-06 code returned null silently) |
| `delivery_mode` | hardcoded `DeliveryMode.BOTH` at the controller call | only if a caller passes `null` **and** the null-guard is removed; monolith writers that don't populate the column also leave NULL |

---

## 2. FLOW B — Viewer Heartbeat (Keeping Presence Alive)

**Scenario:** case is open in a browser tab; UI polls the notification endpoint every few seconds.

```
Browser (Angular 15)
  │  GET /getCaseUpdateNotification?caseId=123          (plain polling variant)
  ▼
CaseController.getCaseUpdateNotification(caseId, request)                   [~line 3168]
  │
  ├─ caseId valid AND useDbStore()?
  │     yes → resolver.resolve(request) → principal
  │           viewerService.heartbeat(caseId,
  │                                   principal.collaborationSessionId,
  │                                   principal.effectiveTabId,
  │                                   lastSeenEventId = null)
  │             └─ DbViewerStore: UPDATE case_viewer_presence
  │                   SET last_heartbeat_at = now
  │                 WHERE case_id + collaboration_session_id + browser_tab_id
  │
  └─ return caseService.getCaseUpdateNotification(caseId)
        └─ also drains ONE cross-app outbox row  (see FLOW E, polling path)
```

**Key insight:** *polling doubles as heartbeat*. There is no separate heartbeat request — the notification poll refreshes `last_heartbeat_at` on the exact row created in FLOW A (matched by the same 3-part key).

**Freshness contract:** readers ignore rows with `last_heartbeat_at < now − 10 min` (`collaboration.viewer.heartbeat-timeout-minutes`). Correctness never depends on cleanup running.

---

## 3. FLOW C — Section Lock (Acquire → Renew → Release)

### 3a. Acquire

**Scenario:** user clicks into an editable section.

```
Browser
  │  GET /acquireLock?lockId=123&section=Epidemiology&sectionId=7
  ▼
CaseController.acquireLock(lockId, section, sectionId, principal, request)  [~line 1908]
  │
  ├─ useDbStore()?  no → legacy UserAccessArbitrator (in-memory) and STOP
  │
  ├─ parseLongOrNull(lockId), parseLongOrNull(sectionId)
  │     non-numeric (modal flows) → WARN + legacy path (intentional routing)
  │
  ├─ resolver.resolve(request) → CollaborationPrincipal
  │
  └─ lockService.acquire(caseId, secId, section, principal, lockTtlSeconds)
        │  LockServiceImpl.acquire()                                [line 37]
        │
        ├─ 1. lockStore.findByCaseAndSection(caseId, sectionId)
        │
        ├─ 2. lock EXISTS?
        │       ├─ isSameOwner(current, principal)?
        │       │     same userId AND same collaborationSessionId
        │       │     AND tab match (Phase 1: both "sess:…" ⇒ same owner)
        │       │       yes → lockStore.renew(lockToken, sessionId, now+TTL)
        │       │             ⇒ SUCCESS (idempotent re-acquire, e.g. F5)
        │       │       no  → CONFLICT (returns owner's userId + sessionId)
        │       │
        │       └─ (expired rows are treated as free by the store)
        │
        ├─ 3. lock ABSENT → build CaseSectionLockRecord:
        │       userId, auhId, sessionId, tabId, clientType,
        │       lockToken = random UUID,
        │       acquiredAt = now, expiresAt = now + TTL (300s)
        │     lockStore.acquire(record)
        │       → atomic INSERT INTO case_section_lock
        │         (fencing token from Oracle sequence at insert)
        │
        └─ 4. INSERT threw (unique constraint)?  ← the RACE path
              Another session inserted between our read and write.
              → re-read the winner → CONFLICT with winner's identity
              → winner also gone (acquired + instantly expired)? → ERROR

Response contract (UNCHANGED from legacy — UI needs no changes):
  SUCCESS  → { "isLocked":"true",  "lockedBy": me,    "expiry_time": minutes }
  CONFLICT → { "isLocked":"false", "lockedBy": owner, "expiry_time": -1 }
  ERROR    → { "isLocked":"false", "lockedBy": "",    "expiry_time": -1 }
             ⚠ DB error does NOT fall back to legacy → prevents split-brain
             (DB and in-memory both granting the same section simultaneously)
```

### 3b. Release (single section)

```
Browser
  │  POST /releaseLock?lockId=123&section=…&sectionId=7
  ▼
CaseController.releaseLock(...)                                             [~line 1984]
  │
  ├─ useDbStore() + numeric ids?
  │     lockService.getActiveLock(caseId, secId).ifPresent(lockRecord →
  │       OWNERSHIP TRIPLE-CHECK:
  │         sameUser    = principal name == lockRecord.userId
  │         sameSession = resolved sessionId == lockRecord.sessionId
  │         sameTab     = isOwnerTab(...)   (Phase 1: no-op via "sess:" fallback)
  │       all three → lockService.release(lockToken, sessionId)
  │                     └─ DELETE … WHERE lock_token = :token
  │                        (token-keyed: a stale/racing caller can never
  │                         delete a NEWER lock that reused the section)
  │     )
  └─ else legacy arbitrator release
```

### 3c. Release all (logout)

```
Browser │ POST /releaseAllLocks
        ▼
CaseController.releaseUsersLock(principal)                                  [~line 2032]
  ├─ useDbStore() → lockService.releaseAllByUser(userId)
  │                   └─ DELETE all case_section_lock rows for user
  │                      (without this, locks would linger up to TTL=300s
  │                       after logout, blocking other users)
  └─ legacy arbitrator cleanup ALWAYS runs too (backward compat)
```

**Crash-safety:** browser dies without releasing → row expires via `expires_at` (TTL 300s); acquire treats expired rows as free; janitor physically deletes them every 5 min.

---

## 4. FLOW D — User Closes the Case (Leave)

```
Browser │ DELETE /removeCaseViewer?caseId=123
        ▼
CaseController.removeCaseViewer(caseId, principal, request)                 [~line 3116]
  ├─ useDbStore() → resolver.resolve(request)
  │                 viewerService.leave(caseId, sessionId, effectiveTabId)
  │                   └─ DELETE FROM case_viewer_presence
  │                       WHERE case_id + collaboration_session_id + browser_tab_id
  └─ else legacy caseService.removeCaseViewer(caseId)
```

If the browser is killed instead: the row goes stale (no heartbeats), is invisible to readers after 10 min, and is physically swept by the janitor.

---

## 5. FLOW E — Save → Cross-App Toast (The Full Round Trip)

The most intricate flow. Split into **producer** (the saver's JVM) and **consumer** (the recipient's JVM).

### 5a. Producer — ng15 user saves a section

```
Browser │ POST /saveCaseEpidemiology (any section save endpoint)
        ▼
CaseController.save*  →  CaseServiceImpl.save*  →  DB commit of section data
        │
        ▼  (same save call, after local fanout)
CaseServiceImpl — notification fanout                                       [~line 11660]
  │
  ├─ 1. LOCAL fanout (unchanged legacy behavior):
  │       recipients = this JVM's viewer cache + SSE subscriber map
  │       → emitter.send(...) per local viewer
  │       → audit: "delivery-complete … channel=stream"
  │
  └─ 2. CROSS-APP fanout (only when useDbStore()):                          [~line 11675]
        dbViewers = viewerService.getActiveViewers(caseId)
          └─ SELECT … FROM case_viewer_presence
              WHERE case_id=:caseId AND last_heartbeat_at >= :activeSince
              (staleness-filtered read: dead sessions never receive rows)
        for each dbViewer:
          ├─ skip if userId == editor              (no self-notification)
          ├─ skip if already delivered locally     (no double toast)
          ├─ skip if already queued this pass      (HashSet de-dupe)
          └─ caseUpdateNotificationStore.insert(
                 caseId, recipientUserId, senderUserId, sectionName, message)
               └─ INSERT INTO case_update_notification
                    (case_id, recipient_user_id, sender_user_id,
                     section_name, message, source_app, delivery_mode)   ← 2026-08-06
                  VALUES (…, 'BACKEND', 'PENDING')
             log: "CROSS_APP_NOTIFICATION queued: …"

        catch (RuntimeException) → WARN only.
        ⚠ FAIL-OPEN BY DESIGN: cross-app fanout must NEVER break the save.
```

### 5b. Consumer — ng15 user receives (SSE path)

The recipient's browser opened a stream when they opened the case:

```
Browser │ GET /getCaseUpdateNotification?caseId=123&stream=true   (EventSource)
        ▼
CaseController.getCaseUpdateNotificationStream(caseId, response)            [~line 3147]
  ├─ caseId ≤ 0 → 400 (fail fast)
  ├─ headers: Cache-Control:no-cache, X-Accel-Buffering:no  (no proxy buffering)
  └─ caseService.getCaseUpdateNotificationStream(caseId)
        ├─ new SseEmitter(timeout)
        ├─ register emitter in per-case map keyed by userId
        ├─ duplicate tab / reconnect → cancel OLD heartbeat, complete old emitter
        │    (one stream per user/case — no leaks)
        ├─ lifecycle hooks: onCompletion / onTimeout / onError
        │    ALL route to removeCaseNotificationEmitter (single cleanup path:
        │    cancel heartbeat FIRST, then remove this exact emitter)
        └─ startCaseNotificationHeartbeat(caseId, userId, emitter)          [~line 11443]

        THE 3-SECOND TICK (scheduled per stream):
        ┌────────────────────────────────────────────────────────────┐
        │ every 3s:                                                  │
        │   if useDbStore():                                         │
        │     loop (max 20 rows):                                    │
        │       msg = fetchAndDeleteNextMessage(userId)              │
        │         └─ SELECT oldest row for recipient → DELETE it     │
        │            (read-and-delete = one-time delivery)           │
        │       emitter.send(event "caseUpdateNotification", payload)│
        │     delivered > 0 → audit "cross-app-heartbeat-delivered"  │
        │     drain error → WARN only (fail-open, next tick retries) │
        │                                                            │
        │   every 5th tick (15s): emitter.send("heartbeat","ping")   │
        │     ping failure = dead client → tear down THIS stream     │
        └────────────────────────────────────────────────────────────┘
```

**Why the 3s/15s split:** the drain originally rode the 15s ping (8-9s median latency). Now it runs every 3s tick while the keep-alive ping stays at 15s — the cadence proxies/load balancers were tuned for.

### 5c. Consumer — polling fallback (old clients)

```
Browser │ GET /getCaseUpdateNotification?caseId=123     (no stream param)
        ▼
CaseController → heartbeat (FLOW B) → caseService.getCaseUpdateNotification()
  └─ fetchCrossAppNotification(userId)                              [~line 11302]
       ├─ !useDbStore() or no user → null
       ├─ fetchAndDeleteNextMessage(userId)  — ONE row per poll
       │    (matches legacy one-message-per-poll contract)
       └─ any RuntimeException → WARN, return null (never breaks polling)
```

### 5d. The monolith side (for completeness)

- Monolith **producer**: same recipe — list active viewers, insert one outbox row per cross-app viewer, `source_app='MONOLITH'`.
- Monolith **consumer**: AngularJS `EventSource` → monolith SSE endpoint → `fetchAndDeleteMessages(user)` drains **all** pending rows at connect (log: `Cross-app case update notifications merged`).

### End-to-end latency budget

```
save commit → outbox INSERT:               ~0 ms   (same transaction scope)
outbox row → recipient's next drain tick:  0–3 s   (SSE) / 0–poll interval (polling)
drain → toast render:                      ~0 ms   (EventSource listener)
                          TYPICAL TOTAL:   ≤ 3 s
```

---

## 6. FLOW F — Background Cleanup (Backend Only)

`CollaborationCleanupService` — `@ConditionalOnProperty(collaboration.cleanup.enabled)` (default ON; OFF = bean never created). **Single janitor** (backend only) = no delete races with the monolith.

| Job | Cadence | Action |
|---|---|---|
| `cleanupExpiredLocks()` | 5 min | DELETE `case_section_lock` rows past `expires_at` |
| `cleanupStaleViewers()` | 10 min | DELETE `case_viewer_presence` rows with heartbeat older than timeout |
| `cleanupOrphanedNotifications()` | 15 min | DELETE `case_update_notification` rows older than 60 min (recipient never came back) |

Each job has its own try/catch — one failing sweep never stops the others. **Cleanup is an optimization, not a correctness requirement**: every reader already filters expired/stale rows.

---

## 7. Identity Cheat-Sheet (Used by Every Flow)

```
CollaborationPrincipal
├── userId                   CustomUserDetails.getUserId() ∥ authentication.getName()
│                            (missing → IllegalStateException; never silent)
├── auhId                    ① CustomUserDetails.getAuhId() (if non-null)
│                            ② "Auhid" request header, parsed Long   ← added 2026-08-06
│                            ③ null + WARN(principal type)           ← was silent before
├── collaborationSessionId   ① X-Collab-Session-Id  ② HTTP session id
│                            ③ userId:browser:hash(User-Agent)  ④ UUID+WARN
├── browserTabId             X-Tab-Id ∥ "sess:<sessionId>"  (Phase 1: always fallback)
├── clientType               ANGULAR15 (Bearer) / ANGULARJS (session)
└── authModel                JWT / SESSION
```

**Row-matching key used everywhere:** `(case_id, collaboration_session_id, browser_tab_id)` — join, heartbeat, and leave all address the same row through this triple.

---

## 8. Troubleshooting Map (Symptom → First File to Open)

| Symptom | Start here | What to check |
|---|---|---|
| `auh_id` NULL in tables | `CollaborationPrincipalResolver.resolveAuhId()` | WARN log shows principal type; JWT path needs `Auhid` header or JWT filter must call `setAuhId` |
| `delivery_mode` NULL in `case_viewer_presence` | writer of that row (check `source_app`/`client_type`) | monolith writer may not populate the column; backend always sends BOTH |
| `delivery_mode` NULL in `case_update_notification` | `DbCaseUpdateNotificationStore.insert()` | column added to INSERT on 2026-08-06; older builds omit it |
| No cross-app toast | `case_update_notification` table | rows present & lingering? consumer drain broken. no rows? producer fanout — check `CROSS_APP_NOTIFICATION queued` log |
| Toast slow (>5s) | `CaseServiceImpl` cadence constants | tick 3s / ping 15s; verify `cross-app-heartbeat-delivered` in logs |
| Presence not visible cross-app | `case_viewer_presence` | recent `last_heartbeat_at`? staleness window (10 min)? flags ON in **both** apps? |
| Locks not conflicting cross-app | `case_section_lock` | rows exist? both flags ON? numeric lockId (non-numeric → legacy path)? |
| Locks stuck after logout | `/releaseAllLocks` → `releaseAllByUser` | endpoint hit? else wait TTL 300s / 5-min sweep |
| Duplicate presence rows | session id chain | random-UUID fallback firing? look for "Generated fallback random session ID" WARN |
| Whole feature dead | `CollaborationStoreRouter.logConfiguration()` at startup | `collaboration.store.mode` value; profile actually loaded |

### The log markers that prove each hop

```
Resolved collaboration principal: userId=…, auhId=…      identity resolved (DEBUG)
CROSS_APP_NOTIFICATION queued: …                          producer wrote outbox row
cross-app-heartbeat-delivered … count=N                   SSE drain delivered N rows
CROSS_APP_NOTIFICATION delivered: …                       polling drain delivered
Released N DB lock(s) for user '…' on logout              logout lock cleanup
auhId unresolved for user=… (principal type=…)            ← auh_id will be NULL (WARN)
```

---

## 9. One-Paragraph Summary

Opening a case MERGE-upserts a presence row keyed by *(case, session, tab)*; every notification poll doubles as a heartbeat on that same row. Editing a section atomically INSERTs a lock row — the row *is* the lock, TTL makes it crash-safe, and a token-keyed DELETE makes release race-proof. Saving a section reads the *staleness-filtered* presence table, writes one outbox row per cross-app viewer, and each recipient's own app drains its rows (SSE: every 3 s, up to 20 rows; polling: one per request) with delete-on-read one-time delivery — so a save in one app becomes a toast in the other app within ~3 seconds, while a single config flag (`collaboration.store.mode`) can revert everything to legacy in-memory behavior instantly.

