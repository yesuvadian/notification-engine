# notification_sdk (Flutter)

Inbox, unread badge, push registration, preferences and a JSON admin console for the shared notification engine.

## Install (pinned release tag)

```yaml
dependencies:
  notification_sdk:
    git:
      url: https://github.com/yesuvadian/notification-engine.git   # or git@github.com:yesuvadian/notification-engine.git
      path: flutter_sdk
      ref: v0.2.0          # release tag (or a commit SHA); avoid `main` in products
```

Run `flutter pub get`, then commit your app's `pubspec.lock` (it must show `source: git` and a resolved commit). Tags are immutable: to upgrade, change `ref` to a newer tag. See `CHANGELOG.md`.

## Create the client

Option A: same Supabase project as the engine (for example CMM). Use the Supabase session JWT and your product code:

```dart
final api = NotificationApi(
  baseUrl: Uri.parse('https://<ref>.supabase.co/functions/v1/notification/'), // trailing slash required
  organizationId: currentOrgId,
  productCode: 'cmm',
  accessToken: () async => Supabase.instance.client.auth.currentSession!.accessToken,
);
```

The engine verifies the JWT with Supabase Auth. The user must have been synced to that organization (`POST /v1/users/sync` from your backend), and the product's issuer must be registered (see the root README).

Option B: other backends. Your backend calls `POST /v1/auth/exchange` with its service credential and returns the short-lived engine token to the app. Pass it through `accessToken`, and leave `productCode` unset.

Never put service, product or worker tokens in Flutter.

## Widgets and calls

- `NotificationBell(api:, onPressed:)` polls the unread count every 30 seconds.
- `NotificationInbox(api:, onAction:)` lists notifications and marks them read on tap. The host must allowlist routes in `onAction` and re-authorize record access.
- `NotificationAdmin(api:)` is a JSON console for users with a notification-admin role.
- `api.inboxPage()`, `api.markAllRead()`, `api.unreadCount()`.
- `api.registerDevice(token: fcmToken, installationId: id, platform: 'android')` after the OS permission is granted. Call `unregisterDevice` on logout.
- `api.preferences()` and `api.setPreferences([...])` read and set per-channel opt-in and consent.

On logout or tenant switch, unmount the notification widgets, call `close()` on the old client, and create a new one.

Errors throw `NotificationApiException(status, code, message, correlationId)`.

## Develop

`flutter pub get && flutter analyze && flutter test`
