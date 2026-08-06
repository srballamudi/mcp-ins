# Acquire flow walkthrough

This file explains how the **acquire lock** logic works.

The main idea is simple:

- If **DB locking** is enabled and the IDs are numeric, use the **new DB lock flow**.
- Otherwise, fall back to the **legacy lock flow**.

---

## 1) Initial setup

```java
String userId = principal.getName();
JSONObject jsonObject = null;
```

### What this means

- `userId` gets the name of the currently logged-in user.
- `jsonObject` is prepared for the response that will be sent back to the UI.

At this point, the code is getting ready to process the lock request and return a result to the front end.

---

## 2) Check whether DB locking is enabled

```java
if (collaborationStoreRouter.useDbStore()) {
```

### What this means

If the application is configured to use the **DB collaboration store**, the code tries the DB locking path first.

If DB locking is not enabled, the code will use the older legacy flow instead.

---

## 3) Check whether the IDs are numeric

```java
Long caseId = parseLongOrNull(lockId);
Long secId = parseLongOrNull(sectionId);
```

### What this means

The code tries to convert:

- `lockId`
- `sectionId`

into `Long` values.

This is the key decision point in the file.

### Important rule

- **Numeric IDs** → DB lock
- **Non-numeric IDs** → Legacy lock

That rule prevents the new DB locking system from being used for old ID formats it does not support.

---

## 4) Use DB locking only when both IDs are numeric

```java
if (caseId != null && secId != null) {
```

### What this means

If both values were successfully parsed as numbers, the code knows it can safely use the DB lock flow.

At this stage, it resolves the collaboration principal and starts the DB acquire process.

---

## 5) Handle the DB acquire result

### Success

```java
if (result.getStatus() == SUCCESS)
```

If the lock is acquired successfully, the response says:

- `isLocked = true`

That tells the UI the lock was granted.

### Conflict

```java
if (result.getStatus() == CONFLICT)
```

If another user already holds the lock, the response says:

- `isLocked = false`

That tells the UI the lock could not be acquired.

---

## Final takeaway

This file keeps both locking systems working together:

1. It checks whether DB locking is enabled.
2. It checks whether the IDs are numeric.
3. If both IDs are numeric, it uses DB locking.
4. If not, it falls back to the legacy lock flow.
5. It returns a response so the UI knows whether the lock was acquired.
