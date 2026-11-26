# Flutter notification SDK starter
Run flutter pub get, flutter analyze and flutter test in a Flutter environment. This package was not compiled here (Flutter/Dart unavailable).

Integrate NotificationApi with HTTPS central API URL, current organization and short-lived token callback. Use NotificationInbox and NotificationBell in the host UI; NotificationAdmin is a basic JSON editor for authorized product admins, not the full visual designer. On logout or tenant switch unmount all notification widgets, close the old API client and create a new one. Host navigation callback must allowlist routes and reauthorize record access.

Proposed API contract (backend not included): GET /v1/notifications -> {items:[{id,title,body,read_at,design,action}]}; GET /v1/notifications/unread-count -> {count:int}; POST /v1/notifications/{id}/read; GET /v1/admin/{templates,events,roles,rules,channels,overrides,deliveries,audit}; POST /v1/admin/{rules,channels,overrides}; POST /v1/admin/templates/preview. All require bearer token and validated tenant scope. Admin payload schemas must be finalized with backend. Polling badge is included; realtime, Firebase setup, permission flows, preferences UI, pagination, dynamic design rendering and full visual admin screens are future work. No provider credentials belong in Flutter.

Private Git distribution: commit package to private repository and pin a release tag in host pubspec.yaml. See architecture specification for remaining scope.
