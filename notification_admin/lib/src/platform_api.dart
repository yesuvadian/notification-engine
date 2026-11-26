import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:notification_sdk/notification_sdk.dart';

typedef Json = Map<String, dynamic>;

/// Client for the engine's platform super admin API (`/v1/platform/*`, spec §51).
///
/// [accessToken] returns the super admin's token from the console's login: a JWT from a trusted platform issuer
/// (sent with `X-Platform-Admin: true`) or an opaque platform token. [organization] gives an SDK client for the
/// organization workspace (`/v1/admin/*` as super admin).
class NotificationPlatformApi {
  final Uri baseUrl;
  final Future<String> Function() accessToken;
  final Duration timeout;
  final http.Client _client;

  NotificationPlatformApi({
    required this.baseUrl,
    required this.accessToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client() {
    if (baseUrl.scheme != 'https' &&
        !(baseUrl.scheme == 'http' && ['localhost', '127.0.0.1', '10.0.2.2'].contains(baseUrl.host))) {
      throw ArgumentError('HTTPS required');
    }
  }

  static const platformHeaders = {'X-Platform-Admin': 'true'};

  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query}) async {
    var uri = baseUrl.resolve(path.replaceFirst(RegExp(r'^/'), ''));
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: query);
    if (uri.origin != baseUrl.origin) throw ArgumentError('Invalid endpoint');
    final req = http.Request(method, uri)
      ..headers.addAll({
        'Authorization': 'Bearer ${await accessToken()}',
        'Content-Type': 'application/json',
        ...platformHeaders,
      });
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _client.send(req).timeout(timeout)).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw NotificationApiException.fromResponse(res.statusCode, res.body);
    }
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

  List<Json> _list(dynamic v) => (v as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  Json _map(dynamic v) => Map<String, dynamic>.from(v as Map);

  /// SDK client acting on one organization as super admin (organization workspace).
  NotificationApi organization(String productCode, String organizationId) => NotificationApi(
      baseUrl: baseUrl,
      organizationId: organizationId,
      accessToken: accessToken,
      productCode: productCode,
      client: _client,
      timeout: timeout,
      extraHeaders: platformHeaders);

  // ---------------------------------------------------------------- overview and products
  Future<Json> overview() async => _map(await request('GET', '/v1/platform/overview'));
  Future<List<Json>> products() async => _list(await request('GET', '/v1/platform/products'));
  Future<Json> createProduct(String code, String name) async =>
      _map(await request('POST', '/v1/platform/products', body: {'code': code, 'name': name}));
  Future<void> setProductActive(String code, bool active) =>
      request('POST', '/v1/platform/products/$code/status', body: {'active': active});

  /// items: `{channel, supported, default_enabled}`.
  Future<List<Json>> saveProductChannels(String code, List<Json> items) async =>
      _list(await request('PUT', '/v1/platform/products/$code/channels', body: {'items': items}));
  Future<List<Json>> productTokens(String code) async => _list(await request('GET', '/v1/platform/products/$code/tokens'));

  /// Returns the new token once (`token`), with `id`, `label`, `expires_at`.
  Future<Json> createProductToken(String code, {String label = 'console', int ttlDays = 90}) async =>
      _map(await request('POST', '/v1/platform/products/$code/tokens', body: {'label': label, 'ttlDays': ttlDays}));
  Future<void> revokeToken(String id) => request('DELETE', '/v1/platform/tokens/$id');
  Future<List<Json>> productIssuers(String code) async => _list(await request('GET', '/v1/platform/products/$code/issuers'));
  Future<Json> saveIssuer(String code, Json issuer) async =>
      _map(await request('POST', '/v1/platform/products/$code/issuers', body: issuer));

  // ---------------------------------------------------------------- organizations
  Future<List<Json>> groups(String productCode) async =>
      _list(await request('GET', '/v1/platform/groups', query: {'product': productCode}));
  Future<List<Json>> organizations(String productCode, {String? search, String? status}) async =>
      _list(await request('GET', '/v1/platform/organizations', query: {
        'product': productCode,
        if (search != null && search.isNotEmpty) 'search': search,
        if (status != null) 'status': status,
      }));

  /// [preferences]: group -> channels. [settings]: member app settings (inbox_retention_days, push_prompt, ...).
  Future<Json> createOrganization({
    required String productCode,
    required String organizationId,
    required String organizationName,
    Map<String, List<String>> preferences = const {},
    Json settings = const {},
  }) async =>
      _map(await request('POST', '/v1/platform/organizations', body: {
        'productCode': productCode,
        'organizationId': organizationId,
        'organizationName': organizationName,
        'preferences': preferences,
        'settings': settings,
      }));
  Future<void> setOrganizationActive(String productCode, String organizationId, bool active, {String? reason}) =>
      request('POST', '/v1/platform/organizations/status', body: {
        'productCode': productCode,
        'organizationId': organizationId,
        'active': active,
        if (reason != null) 'reason': reason,
      });

  // ---------------------------------------------------------------- platform channels
  Future<List<Json>> channels() async => _list(await request('GET', '/v1/platform/channels'));
  Future<Json> saveChannel(String channel, Json providerConfig) async =>
      _map(await request('PUT', '/v1/platform/channels/$channel', body: {'provider_config': providerConfig}));

  /// Write-only: the value is stored in Vault and never returned.
  Future<String> saveChannelSecret(String channel, Json value) async =>
      (await request('PUT', '/v1/platform/channels/$channel/secret', body: {'value': value}))['secret_name'] as String;
  Future<Json> testChannel(String channel, {String? phone, String? deviceToken}) async =>
      _map(await request('POST', '/v1/platform/channels/$channel/test', body: {
        if (phone != null) 'phone': phone,
        if (deviceToken != null) 'deviceToken': deviceToken,
      }));

  // ---------------------------------------------------------------- templates
  Future<List<Json>> templates({String? productCode}) async =>
      _list(await request('GET', '/v1/platform/templates', query: productCode == null ? null : {'product': productCode}));
  Future<Json> createTemplate(String code, String name, {String? productCode, String? description}) async =>
      _map(await request('POST', '/v1/platform/templates', body: {
        'code': code,
        'name': name,
        if (productCode != null) 'productCode': productCode,
        if (description != null) 'description': description,
      }));
  Future<Json> saveDraft(String templateId, String channel, Json content, {String locale = 'en'}) async =>
      _map(await request('POST', '/v1/platform/templates/$templateId/versions',
          body: {'channel': channel, 'locale': locale, 'content': content}));
  Future<Json> publishVersion(String templateId, int version) async =>
      _map(await request('POST', '/v1/platform/templates/$templateId/versions/$version/publish', body: {}));
  Future<void> retireVersion(String templateId, int version) =>
      request('POST', '/v1/platform/templates/$templateId/versions/$version/retire', body: {});

  // ---------------------------------------------------------------- operations
  Future<Json> ops() async => _map(await request('GET', '/v1/platform/ops'));
  Future<void> replayDelivery(String id) => request('POST', '/v1/platform/deliveries/$id/replay', body: {});
  Future<List<Json>> audit({bool platformOnly = true}) async =>
      _list(await request('GET', '/v1/platform/audit', query: {if (platformOnly) 'platformOnly': 'true'}));

  void close() => _client.close();
}

/// Admin calls on one organization (the workspace), on top of the SDK client.
extension OrganizationAdmin on NotificationApi {
  Future<List<Json>> adminList(String resource, {Map<String, String>? query}) async {
    final path = Uri(path: 'v1/admin/$resource', queryParameters: query).toString();
    return (await request('GET', path) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Json> orgPreferences() async => Map<String, dynamic>.from(await request('GET', '/v1/admin/org-preferences'));
  Future<Json> addOrgPreferences(List<Json> items) async =>
      Map<String, dynamic>.from(await request('POST', '/v1/admin/org-preferences', body: {'items': items}));
  Future<Json> orgSettings() async => Map<String, dynamic>.from(await request('GET', '/v1/admin/org-settings'));
  Future<Json> saveOrgSettings(Json patch) async =>
      Map<String, dynamic>.from(await request('PUT', '/v1/admin/org-settings', body: patch));
  Future<void> setChannelEnabled(String channel, bool enabled) =>
      request('POST', '/v1/admin/channels', body: {'channel': channel, 'enabled': enabled});
  Future<Json> testOrgChannel(String channel, {String? userId, String? phone}) async =>
      Map<String, dynamic>.from(await request('POST', '/v1/admin/channels/$channel/test',
          body: {if (userId != null) 'userId': userId, if (phone != null) 'phone': phone}));
  Future<Json> createRule(Json rule) async => Map<String, dynamic>.from(await request('POST', '/v1/admin/rules', body: rule));
  Future<Json> updateRule(String id, Json patch) async =>
      Map<String, dynamic>.from(await request('PUT', '/v1/admin/rules/$id', body: patch));
  Future<void> deleteRule(String id) => request('DELETE', '/v1/admin/rules/$id');
  Future<Json> bindChannel(String ruleId, String channel, String templateId, {int? version}) async =>
      Map<String, dynamic>.from(await request('POST', '/v1/admin/rule-channels', body: {
        'rule_id': ruleId,
        'channel': channel,
        'template_id': templateId,
        if (version != null) 'template_version': version,
      }));
  Future<void> unbindChannel(String ruleId, String channel) => request('DELETE', '/v1/admin/rule-channels/$ruleId/$channel');
  Future<Json> effectiveTemplate(String templateId, String channel, {String locale = 'en'}) async =>
      Map<String, dynamic>.from(await request('GET', '/v1/admin/templates/$templateId/effective?channel=$channel&locale=$locale'));
  Future<Json> publishOverride(String templateId, int baseVersion, String channel, Json patch, {String locale = 'en'}) async =>
      Map<String, dynamic>.from(await request('POST', '/v1/admin/overrides', body: {
        'template_id': templateId,
        'base_version': baseVersion,
        'channel': channel,
        'locale': locale,
        'patch': patch,
      }));
  Future<void> resetOverride(String overrideId) => request('DELETE', '/v1/admin/overrides/$overrideId');
  Future<Json> upgradeTemplate(String templateId, {int? version}) async =>
      Map<String, dynamic>.from(await request('POST', '/v1/admin/templates/$templateId/upgrade',
          body: {if (version != null) 'version': version}));
  Future<void> retryDelivery(String id) => request('POST', '/v1/admin/deliveries/$id/retry', body: {});
  Future<List<Json>> deliveryAttempts(String id) async =>
      (await request('GET', '/v1/admin/deliveries/$id/attempts') as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  Future<List<Json>> eventVariables(String eventCode, {int version = 1}) async =>
      ((await request('GET', '/v1/admin/events/$eventCode/variables?version=$version'))['variables'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
}
