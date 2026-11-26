# Changelog

## 0.2.0
Additive; 0.1.0 code compiles and behaves the same.
- `NotificationApi(productCode: ...)` sends `X-Product-Code`, needed when `accessToken` returns a Supabase or OIDC JWT.
- `inboxPage({limit, cursor, unreadOnly})` with `NotificationPage.nextCursor`; `inbox()` accepts optional `limit` / `unreadOnly`.
- `markAllRead()`, `markManyRead(ids)`.
- `registerDevice(...)`, `unregisterDevice(...)` for FCM push.
- `preferences()`, `setPreferences(...)` with `ChannelPreference`.
- `NotificationApiException` exposes `code`, `message`, `correlationId` (status stays positional).
- `NotificationItem` exposes `createdAt` and `purpose`.
- Admin console lists `rule-channels` (editable) and `attempts`.

Server note: the engine now requires `X-Organization-Id` for user and admin credentials. The SDK has always sent it.

## 0.1.0
Initial DEV baseline: inbox, unread badge, mark read, JSON admin console.
