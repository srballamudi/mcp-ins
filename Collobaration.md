# Collaboration Session ID and Lock Renewal

## Where does `collaborationSessionId` come from?

The `resolveCollaborationSessionId(request, authentication)` method follows these priority rules:

1. **`X-Collab-Session-Id` header**
   - Preferred source
   - Not used in Phase 1

2. **HTTP session ID**
   - Used in AngularJS

3. **Derived stable ID for JWT**
   - Built from `userId + browser fingerprint`

4. **Random UUID**
   - Used only if all other options fail

### Example values

`collaborationSessionId` can look like any of the following:

- `ABCD1234EFGH5678` — HTTP session ID
- `user123:browser:a1b2c3d4` — JWT-based stateless fingerprint
- `7cc9e3d0-4581-4b41-9555-f66f2a44ecdf` — fallback UUID

---

## Final synthetic tab ID in Phase 1

In Phase 1, the synthetic tab ID is built with the `sess:` prefix:

- `sess:ABCD1234EFGH5678`
- `sess:user123:browser:a1b2c3d4`
- `sess:7cc9e3d0-4581-4b41-9555-f66f2a44ecdf`

This acts as the synthetic tab ID.

### Why use the `sess:` prefix?

The prefix is used to:

- Mark the value as fallback Phase 1 mode
- Tell the lock logic that this is **not** an explicit tab ID from a header
- Maintain backward compatibility
- Make Phase 2 easier to introduce later

### When Phase 2 introduces `X-Tab-Id`

The meaning becomes:

- `sess:<...>` = fallback value
- `actual-tab-uuid` = explicit tab ID

---

## Lock renewal behavior

The `renew()` method belongs to the **new distributed collaboration system**, not the legacy implementation.

### Legacy “renew lock” used:

- `userId`
- HTTP session
- in-memory map
- `lockId` only

### New model uses:

- `lockToken` (UUID)
- `collaborationSessionId`
- expiration timestamp

---

## Resolve CollaborationPrincipal

The backend builds the identity and uses:

- fencing tokens for stale-lock prevention
- DB persistence

Internally, it now calls `lockStore.renew()` in the database instead of the legacy in-memory lock manager.
