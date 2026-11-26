import 'dart:convert';

import 'package:http/http.dart' as http;

/// Client for the notification engine API.
///
/// 0.1.x usage keeps working unchanged. New in 0.2.0 (all additive):
/// * [productCode]: send `X-Product-Code`, required when [accessToken] returns a
///   Supabase/OIDC JWT instead of an engine token.
/// * [inboxPage], [markAllRead], [markManyRead], device registration and
///   preferences.
/// * [NotificationApiException] carries the server error [NotificationApiException.code].
///
/// New in 0.3.0 (additive): [memberSettings], [ChannelPreference.locked],
/// [extraHeaders] (used by the super admin console) and [NotificationApi.forOrganization].
class NotificationApi {
  final Uri baseUrl;
  final String organizationId;
  final Future<String> Function() accessToken;

  /// Product code registered in the engine. Required with JWT authentication.
  final String? productCode;

  /// Per-request timeout.
  final Duration timeout;

  /// Headers added to every request (for example `X-Platform-Admin: true` from the super admin console).
  final Map<String, String> extraHeaders;

  final http.Client _client;

  NotificationApi({
    required this.baseUrl,
    required this.organizationId,
    required this.accessToken,
    http.Client? client,
    this.productCode,
    this.timeout = const Duration(seconds: 20),
    this.extraHeaders = const {},
  }) : _client = client ?? http.Client() {
    if (baseUrl.scheme != 'https' &&
        !(baseUrl.scheme == 'http' &&
            ['localhost', '127.0.0.1', '10.0.2.2'].contains(baseUrl.host))) {
      throw ArgumentError('HTTPS required');
    }
  }

  Future<dynamic> request(String method, String path,
      {Map<String, dynamic>? body}) async {
    final uri = baseUrl.resolve(path.replaceFirst(RegExp(r'^/'), ''));
    if (uri.origin != baseUrl.origin) throw ArgumentError('Invalid endpoint');
    final req = http.Request(method, uri)
      ..headers.addAll({
        'Authorization': 'Bearer ${await accessToken()}',
        'Content-Type': 'application/json',
        'X-Organization-Id': organizationId,
        if (productCode != null) 'X-Product-Code': productCode!,
        ...extraHeaders,
      });
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(
            await _client.send(req).timeout(timeout))
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw NotificationApiException.fromResponse(res.statusCode, res.body);
    }
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

  /// Newest notifications first. [limit] defaults to the server default (50).
  Future<List<NotificationItem>> inbox({int? limit, bool unreadOnly = false}) async =>
      (await inboxPage(limit: limit, unreadOnly: unreadOnly)).items;

  /// One page of the inbox; pass [NotificationPage.nextCursor] as [cursor] for the next page.
  Future<NotificationPage> inboxPage(
      {int? limit, String? cursor, bool unreadOnly = false}) async {
    final query = <String, String>{
      if (limit != null) 'limit': '$limit',
      if (cursor != null) 'before': cursor,
      if (unreadOnly) 'unread': 'true',
    };
    final path = Uri(path: 'v1/notifications', queryParameters: query.isEmpty ? null : query).toString();
    return NotificationPage.fromJson(Map<String, dynamic>.from(await request('GET', path)));
  }

  Future<void> markRead(String id) async {
    await request('POST', '/v1/notifications/${Uri.encodeComponent(id)}/read');
  }

  /// Marks the given notifications read; returns how many changed.
  Future<int> markManyRead(List<String> ids) async =>
      ((await request('POST', '/v1/notifications/mark-read', body: {'ids': ids}))['updated'] as num?)?.toInt() ?? 0;

  /// Marks the whole inbox read; returns how many changed.
  Future<int> markAllRead() async =>
      ((await request('POST', '/v1/notifications/mark-read', body: {'all': true}))['updated'] as num?)?.toInt() ?? 0;

  Future<int> unreadCount() async =>
      (await request('GET', '/v1/notifications/unread-count'))['count'] as int;

  /// Registers this installation's FCM token for push (call after the OS permission is granted).
  Future<void> registerDevice(
      {required String token,
      required String installationId,
      String? platform,
      String? appVersion}) async {
    await request('POST', '/v1/devices/register', body: {
      'token': token,
      'installationId': installationId,
      if (platform != null) 'platform': platform,
      if (appVersion != null) 'appVersion': appVersion,
    });
  }

  /// Call on logout or tenant switch.
  Future<void> unregisterDevice(String installationId) async {
    await request('POST', '/v1/devices/unregister', body: {'installationId': installationId});
  }

  /// Channels enabled for the organization with the user's choice and consent.
  Future<List<ChannelPreference>> preferences() async {
    final data = await request('GET', '/v1/preferences');
    return (data['items'] as List)
        .map((x) => ChannelPreference.fromJson(Map<String, dynamic>.from(x)))
        .toList();
  }

  Future<List<ChannelPreference>> setPreferences(List<ChannelPreference> items) async {
    final data = await request('POST', '/v1/preferences',
        body: {'items': items.map((e) => e.toJson()).toList()});
    return (data['items'] as List)
        .map((x) => ChannelPreference.fromJson(Map<String, dynamic>.from(x)))
        .toList();
  }

  /// Organization-level settings for the member app (inbox, push prompt, whether preferences are locked).
  Future<MemberSettings> memberSettings() async =>
      MemberSettings.fromJson(Map<String, dynamic>.from(await request('GET', '/v1/settings')));

  /// Same credentials and client, another organization (the client is shared, so close only one of them).
  NotificationApi forOrganization(String organizationId, {String? productCode}) => NotificationApi(
      baseUrl: baseUrl,
      organizationId: organizationId,
      accessToken: accessToken,
      client: _client,
      productCode: productCode ?? this.productCode,
      timeout: timeout,
      extraHeaders: extraHeaders);

  void close() => _client.close();
}

class NotificationApiException implements Exception {
  final int status;

  /// Server error code such as `unauthorized`, `organization_required`, `idempotency_conflict`.
  final String? code;
  final String? message;
  final String? correlationId;

  NotificationApiException(this.status, {this.code, this.message, this.correlationId});

  factory NotificationApiException.fromResponse(int status, String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        return NotificationApiException(status,
            code: j['error'] is String ? j['error'] as String : null,
            message: j['message'] is String ? j['message'] as String : null,
            correlationId: j['correlationId'] is String ? j['correlationId'] as String : null);
      }
    } catch (_) {}
    return NotificationApiException(status);
  }

  @override
  String toString() => code == null
      ? 'Notification request failed ($status)'
      : 'Notification request failed ($status $code)';
}

class NotificationItem {
  final String id, title, body;
  final bool read;
  final Map<String, dynamic> design;
  final Map<String, dynamic>? action;
  final DateTime? createdAt;
  final String? purpose;

  NotificationItem.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        title = j['title'] as String,
        body = j['body'] as String,
        read = j['read_at'] != null,
        design = Map<String, dynamic>.from(j['design'] ?? {}),
        action = j['action'] == null ? null : Map<String, dynamic>.from(j['action']),
        createdAt = j['created_at'] is String ? DateTime.tryParse(j['created_at'] as String) : null,
        purpose = j['purpose'] as String?;
}

class NotificationPage {
  final List<NotificationItem> items;
  final String? nextCursor;
  NotificationPage(this.items, this.nextCursor);
  factory NotificationPage.fromJson(Map<String, dynamic> j) => NotificationPage(
      (j['items'] as List)
          .map((x) => NotificationItem.fromJson(Map<String, dynamic>.from(x)))
          .toList(),
      j['nextCursor'] as String?);
}

class ChannelPreference {
  final String channel;
  final bool enabled;
  final bool consent;

  /// True when the organization controls this channel and the member cannot switch it off.
  final bool locked;
  final DateTime? consentAt;
  ChannelPreference(
      {required this.channel, required this.enabled, required this.consent, this.locked = false, this.consentAt});
  factory ChannelPreference.fromJson(Map<String, dynamic> j) => ChannelPreference(
      channel: j['channel'] as String,
      enabled: j['enabled'] as bool? ?? true,
      consent: j['consent'] as bool? ?? false,
      locked: j['locked'] as bool? ?? false,
      consentAt: j['consentAt'] is String ? DateTime.tryParse(j['consentAt'] as String) : null);
  ChannelPreference copyWith({bool? enabled, bool? consent}) => ChannelPreference(
      channel: channel, enabled: enabled ?? this.enabled, consent: consent ?? this.consent, locked: locked, consentAt: consentAt);

  /// Locked channels send only consent, so a member can never switch them off.
  Map<String, dynamic> toJson() => locked ? {'channel': channel, 'consent': consent} : {'channel': channel, 'enabled': enabled, 'consent': consent};
}

/// Member app settings provisioned by the platform super admin for the organization.
class MemberSettings {
  /// False for organizations set up before the super admin console (members manage their own channels).
  final bool managed;
  final bool preferencesLocked;
  final int? inboxRetentionDays;
  final bool unreadBadge;
  final bool groupByDay;
  final bool pushEnabled;

  /// `off`, `after_first_notification` or `first_login`.
  final String pushPrompt;
  final String? pushExplanation;

  const MemberSettings({
    this.managed = false,
    this.preferencesLocked = false,
    this.inboxRetentionDays,
    this.unreadBadge = true,
    this.groupByDay = true,
    this.pushEnabled = false,
    this.pushPrompt = 'off',
    this.pushExplanation,
  });

  factory MemberSettings.fromJson(Map<String, dynamic> j) {
    final inbox = Map<String, dynamic>.from(j['inbox'] ?? {});
    final push = Map<String, dynamic>.from(j['push'] ?? {});
    return MemberSettings(
      managed: j['managed'] as bool? ?? false,
      preferencesLocked: j['preferencesLocked'] as bool? ?? false,
      inboxRetentionDays: (inbox['retentionDays'] as num?)?.toInt(),
      unreadBadge: inbox['unreadBadge'] as bool? ?? true,
      groupByDay: inbox['groupByDay'] as bool? ?? true,
      pushEnabled: push['enabled'] as bool? ?? false,
      pushPrompt: push['prompt'] as String? ?? 'off',
      pushExplanation: push['explanation'] as String?,
    );
  }
}
