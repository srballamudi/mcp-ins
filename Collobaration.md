**Where does collaborationSessionId come from?**

**resolveCollaborationSessionId(request, authentication)**

******This method follows priority rules:**
1. First choice: X-Collab-Session-Id header
(not used in Phase 1)
2. Second choice: HTTP session ID
(Used in AngularJS)
3. Third choice: Derived stable ID for JWT
(using userId + browser fingerprint)
4. Fourth choice: random UUID
(only if all else fails)
So collaborationSessionId looks like:****

"ABCD1234EFGH5678" (session ID)
"user123:browser:a1b2c3d4" (JWT stateless fingerprint)
or a fallback UUID

Final synthetic tab ID (Phase 1)
Examples:
sess:ABCD1234EFGH5678
sess:user123:browser:a1b2c3d4
sess:7cc9e3d0-4581-4b41-9555-f66f2a44ecdf

This acts as the synthetic tab ID.

Why “sess:” prefix?
is used to:

Mark this value as fallback Phase 1 mode
Tell the lock logic:
“This is NOT an explicit tab ID from header”
Maintain backward compatibility
Make Phase 2 logic easier later

When the Phase 2 header X-Tab-Id arrives:

"sess:<...>" = fallback
"actual-tab-uuid" = explicit tab ID


============================

The renew() method is part of the new distributed collaboration system, NOT part of legacy.
Legacy “renew lock” used:

userId
HTTP session
in-memory map
lockId only

The new model uses:

lockToken (UUID)
collaborationSessionId
expiration timestamp

=============
Resolve CollaborationPrincipal
Backend builds the identity:
fencing tokens (for stale lock prevention)
DB persistence
Internally:

**it now hits lockStore.renew() (DB) instead of the legacy in-memory lock manager.**
