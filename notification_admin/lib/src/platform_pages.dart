import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'common.dart';
import 'designer.dart';
import 'organization_step.dart';
import 'platform_api.dart';
import 'workspace.dart';

/// Opens an organization's workspace. The console passes its own navigation; the default pushes a route.
typedef OpenOrganization = void Function(BuildContext context, String productCode, String organizationId, String name);

void defaultOpenOrganization(NotificationPlatformApi api, BuildContext context, String productCode, String orgId, String name) =>
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
            appBar: AppBar(title: Text(name)),
            body: OrganizationWorkspace(api: api, productCode: productCode, organizationId: orgId, organizationName: name))));

// =========================================================================== D1 products

/// D1: products, which channels each supports and turns on for new organizations, backend tokens and login issuers.
class ProductsPage extends StatelessWidget {
  final NotificationPlatformApi api;
  const ProductsPage({super.key, required this.api});

  @override
  Widget build(BuildContext context) => Loaded<List<Json>>(
        load: api.products,
        builder: (context, products, reload) => ListView(children: [
          PageHeader('Products',
              subtitle: 'Channels each product supports and turns on for new organizations, backend tokens and login issuers. '
                  'Providers are platform level, under Channels.',
              actions: [FilledButton.icon(onPressed: () => _create(context, reload), icon: const Icon(Icons.add), label: const Text('New product'))]),
          for (final p in products) _ProductCard(api: api, product: p, reload: reload),
        ]),
      );

  Future<void> _create(BuildContext context, Future<void> Function() reload) async {
    final code = TextEditingController(), name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New product'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(key: const ValueKey('product-code'), controller: code, decoration: const InputDecoration(labelText: 'Code (e.g. ass)')),
          TextField(key: const ValueKey('product-name'), controller: name, decoration: const InputDecoration(labelText: 'Name')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok == true && context.mounted && await runAction(context, () => api.createProduct(code.text.trim(), name.text.trim()), done: 'Product created')) {
      await reload();
    }
  }
}

class _ProductCard extends StatefulWidget {
  final NotificationPlatformApi api;
  final Json product;
  final Future<void> Function() reload;
  const _ProductCard({required this.api, required this.product, required this.reload});
  @override
  State<_ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<_ProductCard> {
  late Map<String, Json> defaults;

  @override
  void initState() {
    super.initState();
    defaults = {
      for (final c in kChannels) c: {'channel': c, 'supported': c == 'IN_APP', 'default_enabled': c == 'IN_APP'},
      for (final d in (widget.product['defaults'] as List? ?? [])) (d as Map)['channel'] as String: Map<String, dynamic>.from(d),
    };
  }

  String get code => widget.product['code'] as String;

  Future<void> save() async {
    await runAction(context, () async {
      await widget.api.saveProductChannels(code, defaults.values.toList());
    }, done: 'Channel defaults saved');
  }

  Future<void> tokens() => showDialog(context: context, builder: (_) => _TokensDialog(api: widget.api, productCode: code));
  Future<void> issuers() => showDialog(context: context, builder: (_) => _IssuersDialog(api: widget.api, productCode: code));

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final active = p['status'] != 'SUSPENDED';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${p['name']}', style: Theme.of(context).textTheme.titleMedium)),
            statusChip(code),
            if (!active) statusChip('Suspended', color: Colors.red),
          ]),
          Text('${p['organizations'] ?? 0} organizations · ${(p['issuers'] as List? ?? []).length} login issuers',
              style: Theme.of(context).textTheme.bodySmall),
          Table(columnWidths: const {0: IntrinsicColumnWidth()}, children: [
            const TableRow(children: [Text('Channel'), Text('Supported'), Text('On for new orgs')]),
            for (final c in kChannels)
              TableRow(children: [
                Padding(padding: const EdgeInsets.only(right: 16, top: 12), child: Text(chLabel(c))),
                Switch(
                    key: ValueKey('$code-$c-supported'),
                    value: defaults[c]!['supported'] == true,
                    onChanged: c == 'IN_APP'
                        ? null
                        : (v) => setState(() {
                              defaults[c]!['supported'] = v;
                              if (!v) defaults[c]!['default_enabled'] = false;
                            })),
                Switch(
                    key: ValueKey('$code-$c-default'),
                    value: defaults[c]!['default_enabled'] == true,
                    onChanged: c == 'IN_APP' || defaults[c]!['supported'] != true
                        ? null
                        : (v) => setState(() => defaults[c]!['default_enabled'] = v)),
              ]),
          ]),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: save, child: const Text('Save channels')),
            OutlinedButton(onPressed: tokens, child: const Text('Tokens')),
            OutlinedButton(onPressed: issuers, child: const Text('Issuers')),
            TextButton(
                onPressed: () async {
                  if (await runAction(context, () => widget.api.setProductActive(code, !active), done: active ? 'Product suspended' : 'Product activated')) {
                    await widget.reload();
                  }
                },
                child: Text(active ? 'Suspend' : 'Activate')),
          ]),
        ]),
      ),
    );
  }
}

class _TokensDialog extends StatefulWidget {
  final NotificationPlatformApi api;
  final String productCode;
  const _TokensDialog({required this.api, required this.productCode});
  @override
  State<_TokensDialog> createState() => _TokensDialogState();
}

class _TokensDialogState extends State<_TokensDialog> {
  int key = 0;
  String? created;
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Backend tokens · ${widget.productCode}'),
        content: SizedBox(
          width: 480,
          height: 320,
          child: Column(children: [
            if (created != null)
              Card(
                  child: ListTile(
                      title: const Text('Copy this token now. It is shown once.'),
                      subtitle: SelectableText(created!, key: const ValueKey('new-token')))),
            Expanded(
              child: Loaded<List<Json>>(
                key: ValueKey(key),
                load: () => widget.api.productTokens(widget.productCode),
                builder: (context, rows, _) => ListView(children: [
                  if (rows.isEmpty) const ListTile(title: Text('No tokens')),
                  for (final t in rows)
                    ListTile(
                      title: Text('${t['label'] ?? 'token'}'),
                      subtitle: Text(t['revoked_at'] != null ? 'Revoked' : 'Expires ${t['expires_at']}'),
                      trailing: t['revoked_at'] != null
                          ? null
                          : TextButton(
                              onPressed: () async {
                                if (await runAction(context, () => widget.api.revokeToken(t['id'] as String), done: 'Token revoked')) {
                                  setState(() => key++);
                                }
                              },
                              child: const Text('Revoke')),
                    ),
                ]),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton(
              onPressed: () async {
                try {
                  final t = await widget.api.createProductToken(widget.productCode);
                  setState(() {
                    created = t['token'] as String;
                    key++;
                  });
                } catch (e) {
                  if (context.mounted) toast(context, errorText(e));
                }
              },
              child: const Text('Create token')),
        ],
      );
}

class _IssuersDialog extends StatefulWidget {
  final NotificationPlatformApi api;
  final String productCode;
  const _IssuersDialog({required this.api, required this.productCode});
  @override
  State<_IssuersDialog> createState() => _IssuersDialogState();
}

class _IssuersDialogState extends State<_IssuersDialog> {
  final issuer = TextEditingController(), jwks = TextEditingController(), audience = TextEditingController(text: 'authenticated');
  int key = 0;
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Login issuers · ${widget.productCode}'),
        content: SizedBox(
          width: 480,
          height: 360,
          child: Column(children: [
            Expanded(
              child: Loaded<List<Json>>(
                key: ValueKey(key),
                load: () => widget.api.productIssuers(widget.productCode),
                builder: (context, rows, _) => ListView(children: [
                  for (final i in rows)
                    ListTile(title: Text('${i['issuer']}'), subtitle: Text(i['jwks_url'] == null ? 'Supabase Auth' : 'JWKS ${i['jwks_url']}')),
                ]),
              ),
            ),
            TextField(key: const ValueKey('issuer'), controller: issuer, decoration: const InputDecoration(labelText: 'Issuer (https)')),
            TextField(controller: jwks, decoration: const InputDecoration(labelText: 'JWKS URL (empty = this Supabase project)')),
            TextField(controller: audience, decoration: const InputDecoration(labelText: 'Audience')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton(
              onPressed: () async {
                final ok = await runAction(
                    context,
                    () => widget.api.saveIssuer(widget.productCode, {
                          'issuer': issuer.text.trim(),
                          if (jwks.text.trim().isNotEmpty) 'jwks_url': jwks.text.trim(),
                          'audience': audience.text.trim(),
                        }),
                    done: 'Issuer saved');
                if (ok) setState(() => key++);
              },
              child: const Text('Save issuer')),
        ],
      );
}

// =========================================================================== D2 organizations

String newUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// D2: organizations of a product. Manage opens the organization workspace; New organization provisions it with
/// its notification preferences and member app settings.
class OrganizationsPage extends StatefulWidget {
  final NotificationPlatformApi api;
  final String productCode;
  final OpenOrganization? onOpen;
  const OrganizationsPage({super.key, required this.api, required this.productCode, this.onOpen});
  @override
  State<OrganizationsPage> createState() => _OrganizationsPageState();
}

class _OrganizationsPageState extends State<OrganizationsPage> {
  String search = '';
  String? status;
  int key = 0;

  void open(Json o) => (widget.onOpen ?? (c, p, id, n) => defaultOpenOrganization(widget.api, c, p, id, n))(
      context, widget.productCode, o['organization_id'] as String, o['name'] as String);

  Future<void> setActive(Json o, bool active) async {
    String? reason;
    if (!active) {
      reason = await askReason(context,
          title: 'Suspend ${o['name']}?',
          message: 'Notifications stop for this organization. Nothing is deleted; you can reactivate it any time.',
          confirm: 'Suspend');
      if (reason == null) return;
    }
    if (!mounted) return;
    if (await runAction(context, () => widget.api.setOrganizationActive(widget.productCode, o['organization_id'] as String, active, reason: reason),
        done: active ? 'Organization reactivated' : 'Organization suspended')) {
      setState(() => key++);
    }
  }

  Future<void> create() async {
    final created = await showDialog<bool>(
        context: context, builder: (_) => NewOrganizationDialog(api: widget.api, productCode: widget.productCode));
    if (created == true) setState(() => key++);
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        PageHeader('Organizations',
            subtitle: 'Manage opens the organization workspace: rules, templates and overrides, channels, preferences, log and audit.',
            actions: [FilledButton.icon(onPressed: create, icon: const Icon(Icons.add), label: const Text('New organization'))]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('org-search'),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search organizations'),
                onSubmitted: (v) => setState(() {
                  search = v.trim();
                  key++;
                }),
              ),
            ),
            const SizedBox(width: 12),
            SegmentedButton<String?>(
              segments: const [
                ButtonSegment(value: null, label: Text('All')),
                ButtonSegment(value: 'active', label: Text('Active')),
                ButtonSegment(value: 'inactive', label: Text('Inactive')),
              ],
              selected: {status},
              onSelectionChanged: (s) => setState(() {
                status = s.first;
                key++;
              }),
            ),
          ]),
        ),
        Expanded(
          child: Loaded<List<Json>>(
            key: ValueKey('$key-${widget.productCode}'),
            load: () => widget.api.organizations(widget.productCode, search: search, status: status),
            builder: (context, rows, _) => ListView(children: [
              if (rows.isEmpty) const Card(child: ListTile(title: Text('No organizations found.'))),
              for (final o in rows)
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: ListTile(
                    title: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text('${o['name']}'),
                      if (o['active'] != true) statusChip('Suspended', color: Colors.red),
                      if (o['managed'] != true) statusChip('Not provisioned by console'),
                    ]),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${o['users']} members · ${o['sent_7d']} deliveries in 7 days'),
                      Wrap(children: [for (final c in (o['channels'] as List? ?? [])) channelChip(c as String)]),
                    ]),
                    trailing: Wrap(spacing: 8, children: [
                      FilledButton(onPressed: () => open(o), child: const Text('Manage')),
                      OutlinedButton(onPressed: () => setActive(o, o['active'] != true), child: Text(o['active'] == true ? 'Suspend' : 'Reactivate')),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ]);
}

/// Stand-alone "New organization" dialog (the console wizard uses [NotificationOrganizationStep] directly).
class NewOrganizationDialog extends StatefulWidget {
  final NotificationPlatformApi api;
  final String productCode;
  const NewOrganizationDialog({super.key, required this.api, required this.productCode});
  @override
  State<NewOrganizationDialog> createState() => _NewOrganizationDialogState();
}

class _NewOrganizationDialogState extends State<NewOrganizationDialog> {
  final name = TextEditingController(), orgId = TextEditingController(text: newUuid());
  final setup = NotificationSetup();
  late Future<(List<String>, Set<String>)> meta = _meta();
  bool busy = false;

  Future<(List<String>, Set<String>)> _meta() async {
    final groups = (await widget.api.groups(widget.productCode)).map((g) => g['group'] as String).toList();
    final product = (await widget.api.products()).firstWhere((p) => p['code'] == widget.productCode, orElse: () => {});
    final supported = {
      for (final d in (product['defaults'] as List? ?? [])) if ((d as Map)['supported'] == true) d['channel'] as String,
      'IN_APP'
    };
    for (final g in groups) {
      for (final d in (product['defaults'] as List? ?? [])) {
        if ((d as Map)['default_enabled'] == true && d['supported'] == true) setup.toggle(g, d['channel'] as String, true);
      }
    }
    return (groups, supported);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('New organization · ${widget.productCode}'),
        content: SizedBox(
          width: 720,
          child: FutureBuilder<(List<String>, Set<String>)>(
            future: meta,
            builder: (context, s) {
              if (s.hasError) return Text(errorText(s.error!));
              if (!s.hasData) return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
              return SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  TextField(key: const ValueKey('org-name'), controller: name, decoration: const InputDecoration(labelText: 'Organization name')),
                  TextField(
                      key: const ValueKey('org-id'),
                      controller: orgId,
                      decoration: const InputDecoration(labelText: 'Organization id (the product\'s organization UUID)')),
                  const SizedBox(height: 16),
                  NotificationOrganizationStep(setup: setup, groups: s.data!.$1, supported: s.data!.$2),
                ]),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final m = await meta;
                    setState(() => busy = true);
                    if (!context.mounted) return;
                    final ok = await runAction(
                        context,
                        () => provisionNotifications(widget.api,
                            productCode: widget.productCode,
                            organizationId: orgId.text.trim(),
                            organizationName: name.text.trim(),
                            setup: setup,
                            groups: m.$1),
                        done: 'Organization created');
                    if (!mounted) return;
                    setState(() => busy = false);
                    if (ok && context.mounted) Navigator.pop(context, true);
                  },
            child: const Text('Create organization'),
          ),
        ],
      );
}

// =========================================================================== D3 platform channels

/// D3: one provider per channel for the whole platform. Credentials are write-only (Vault).
class PlatformChannelsPage extends StatelessWidget {
  final NotificationPlatformApi api;
  const PlatformChannelsPage({super.key, required this.api});

  @override
  Widget build(BuildContext context) => Loaded<List<Json>>(
        load: api.channels,
        builder: (context, rows, reload) => ListView(children: [
          const PageHeader('Channels and providers',
              subtitle: 'One provider per channel for every product and organization. Products and organizations only turn channels on.'),
          for (final c in rows) _ChannelCard(api: api, row: c, reload: reload),
        ]),
      );
}

const providerTypes = {
  'SMS': ['http', 'msg91', 'twilio', 'mock'],
  'WHATSAPP': ['http', 'meta', 'mock'],
  'PUSH': ['fcm', 'mock'],
};

/// Non-secret settings each provider type needs, and the credential keys it reads from the secret.
const providerFields = {
  'http': ['url', 'method', 'message_id_path', 'success_path'],
  'msg91': ['template_id'],
  'twilio': ['from', 'messaging_service_sid'],
  'meta': ['phone_number_id'],
  'fcm': <String>[],
  'mock': <String>[],
};
const secretFields = {
  'http': ['api_key'],
  'msg91': ['authkey'],
  'twilio': ['account_sid', 'auth_token'],
  'meta': ['access_token'],
  'fcm': ['service_account_json'],
  'mock': <String>[],
};

class _ChannelCard extends StatefulWidget {
  final NotificationPlatformApi api;
  final Json row;
  final Future<void> Function() reload;
  const _ChannelCard({required this.api, required this.row, required this.reload});
  @override
  State<_ChannelCard> createState() => _ChannelCardState();
}

class _ChannelCardState extends State<_ChannelCard> {
  late String provider;
  final fields = <String, TextEditingController>{};
  final secrets = <String, TextEditingController>{};
  final headers = TextEditingController(), body = TextEditingController(), testTo = TextEditingController();

  String get channel => widget.row['channel'] as String;
  Json get cfg => Map<String, dynamic>.from(widget.row['provider_config'] as Map? ?? {});

  @override
  void initState() {
    super.initState();
    provider = (cfg['provider'] as String?) ?? providerTypes[channel]!.first;
    for (final f in providerFields.values.expand((e) => e).toSet()) {
      fields[f] = TextEditingController(text: cfg[f]?.toString() ?? '');
    }
    for (final f in secretFields.values.expand((e) => e).toSet()) {
      secrets[f] = TextEditingController();
    }
    headers.text = cfg['headers'] == null ? '' : _pretty(cfg['headers']);
    body.text = cfg['body'] == null ? '' : _pretty(cfg['body']);
  }

  static String _pretty(Object v) => const JsonCodecLite().encode(v);

  Json buildConfig() {
    final c = <String, dynamic>{'provider': provider};
    for (final f in providerFields[provider]!) {
      final v = fields[f]!.text.trim();
      if (v.isNotEmpty) c[f] = v;
    }
    if (provider == 'http') {
      if (headers.text.trim().isNotEmpty) c['headers'] = const JsonCodecLite().decode(headers.text);
      if (body.text.trim().isNotEmpty) c['body'] = const JsonCodecLite().decode(body.text);
    }
    return c;
  }

  Json? buildSecret() {
    final s = <String, dynamic>{};
    for (final f in secretFields[provider]!) {
      final v = secrets[f]!.text.trim();
      if (v.isEmpty) continue;
      if (f == 'service_account_json') {
        s.addAll(Map<String, dynamic>.from(const JsonCodecLite().decode(v) as Map));
      } else {
        s[f] = v;
      }
    }
    return s.isEmpty ? null : s;
  }

  Future<void> save() async {
    final ok = await runAction(context, () async {
      final secret = buildSecret();
      if (secret != null) await widget.api.saveChannelSecret(channel, secret);
      await widget.api.saveChannel(channel, buildConfig());
    }, done: '${chLabel(channel)} provider saved');
    if (ok) {
      for (final c in secrets.values) {
        c.clear();
      }
      await widget.reload();
    }
  }

  Future<void> test() async {
    try {
      final r = await widget.api.testChannel(channel,
          phone: channel == 'PUSH' ? null : testTo.text.trim(), deviceToken: channel == 'PUSH' ? testTo.text.trim() : null);
      if (mounted) toast(context, 'Test send: ${r['outcome']} via ${r['provider']}${r['error'] == null ? '' : ' (${r['error']})'}');
    } catch (e) {
      if (mounted) toast(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = widget.row['configured'] == true;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(chLabel(channel), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 8),
            statusChip(configured ? 'Configured · ${cfg['provider']}' : 'Not configured (mock)', color: configured ? Colors.green : null),
            const Spacer(),
            if (widget.row['hasSecret'] == true) statusChip('Credentials stored'),
          ]),
          DropdownButton<String>(
            key: ValueKey('$channel-provider'),
            value: provider,
            items: providerTypes[channel]!.map((p) => DropdownMenuItem(value: p, child: Text(p == 'http' ? 'HTTP (any provider)' : p))).toList(),
            onChanged: (v) => setState(() => provider = v!),
          ),
          for (final f in providerFields[provider]!)
            TextField(key: ValueKey('$channel-$f'), controller: fields[f], decoration: InputDecoration(labelText: f)),
          if (provider == 'http') ...[
            TextField(key: ValueKey('$channel-headers'), controller: headers, maxLines: 2, decoration: const InputDecoration(labelText: 'Headers JSON, e.g. {"Authorization": "Bearer {{secret.api_key}}"}')),
            TextField(key: ValueKey('$channel-body'), controller: body, maxLines: 3, decoration: const InputDecoration(labelText: 'Body template JSON')),
          ],
          for (final f in secretFields[provider]!)
            TextField(
                key: ValueKey('$channel-secret-$f'),
                controller: secrets[f],
                obscureText: f != 'service_account_json',
                maxLines: f == 'service_account_json' ? 3 : 1,
                decoration: InputDecoration(labelText: '$f (write-only, saved to Vault)', hintText: widget.row['hasSecret'] == true ? 'stored' : null)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: TextField(
                    key: ValueKey('$channel-test-to'),
                    controller: testTo,
                    decoration: InputDecoration(labelText: channel == 'PUSH' ? 'Test device token' : 'Test phone (E.164)'))),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: test, child: const Text('Send test')),
            const SizedBox(width: 8),
            FilledButton(onPressed: save, child: const Text('Save')),
          ]),
        ]),
      ),
    );
  }
}

// =========================================================================== D4/D5 platform templates

/// D4: platform templates with versions and usage. Open goes to the designer (D5).
class PlatformTemplatesPage extends StatefulWidget {
  final NotificationPlatformApi api;
  final String? productCode;
  const PlatformTemplatesPage({super.key, required this.api, this.productCode});
  @override
  State<PlatformTemplatesPage> createState() => _PlatformTemplatesPageState();
}

class _PlatformTemplatesPageState extends State<PlatformTemplatesPage> {
  int key = 0;

  Future<void> create() async {
    final code = TextEditingController(), name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New platform template'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(key: const ValueKey('tpl-code'), controller: code, decoration: const InputDecoration(labelText: 'Code (e.g. PAYMENT_CONFIRMATION)')),
          TextField(key: const ValueKey('tpl-name'), controller: name, decoration: const InputDecoration(labelText: 'Name')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok == true && mounted &&
        await runAction(context, () => widget.api.createTemplate(code.text.trim().toUpperCase(), name.text.trim(), productCode: widget.productCode),
            done: 'Template created')) {
      setState(() => key++);
    }
  }

  Future<void> openDesigner(Json t) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
            appBar: AppBar(title: Text('${t['code']}')),
            body: TemplateDesigner.platform(api: widget.api, template: t))));
    setState(() => key++);
  }

  @override
  Widget build(BuildContext context) => Loaded<List<Json>>(
        key: ValueKey(key),
        load: () => widget.api.templates(productCode: widget.productCode),
        builder: (context, rows, reload) => ListView(children: [
          PageHeader('Platform templates',
              subtitle: 'Versions are immutable: edit a draft, publish, retire. Publishing sets the version new organizations start on; '
                  'existing organizations keep theirs until you upgrade them from the organization workspace.',
              actions: [FilledButton.icon(onPressed: create, icon: const Icon(Icons.add), label: const Text('New template'))]),
          for (final t in rows) _TemplateCard(api: widget.api, t: t, onOpen: () => openDesigner(t), reload: reload),
        ]),
      );
}

class _TemplateCard extends StatelessWidget {
  final NotificationPlatformApi api;
  final Json t;
  final VoidCallback onOpen;
  final Future<void> Function() reload;
  const _TemplateCard({required this.api, required this.t, required this.onOpen, required this.reload});

  @override
  Widget build(BuildContext context) {
    final versions = (t['versions'] as List? ?? []).map((v) => Map<String, dynamic>.from(v as Map)).toList();
    final byVersion = <int, Set<String>>{};
    final status = <int, String>{};
    for (final v in versions) {
      byVersion.putIfAbsent(v['version'] as int, () => {}).add(v['channel'] as String);
      status[v['version'] as int] = v['status'] as String;
    }
    final pinned = Map<String, dynamic>.from(t['pinnedOrganizations'] as Map? ?? {});
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${t['code']}', style: Theme.of(context).textTheme.titleMedium)),
            Text(t['product_id'] == null ? 'Shared' : 'Product only', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(width: 8),
            FilledButton(onPressed: onOpen, child: const Text('Open')),
          ]),
          Text('${t['name'] ?? ''} · new organizations start on ${t['latestPublished'] == null ? 'nothing yet' : 'v${t['latestPublished']}'} · '
              '${t['organizationsWithOverrides']} organizations with overrides'),
          Wrap(spacing: 6, children: [
            for (final v in (byVersion.keys.toList()..sort()).reversed)
              InputChip(
                key: ValueKey('${t['code']}-v$v'),
                label: Text('v$v ${status[v]!.toLowerCase()}${pinned['$v'] == null ? '' : ' · ${pinned['$v']} orgs'} · ${byVersion[v]!.map(chLabel).join(', ')}'),
                onPressed: status[v] == 'DRAFT'
                    ? () async {
                        if (await confirm(context,
                                title: 'Publish v$v?',
                                message: 'New organizations start on v$v. Existing organizations stay on their version until you upgrade them.',
                                action: 'Publish') &&
                            context.mounted &&
                            await runAction(context, () => api.publishVersion(t['id'] as String, v), done: 'v$v published')) {
                          await reload();
                        }
                      }
                    : status[v] == 'PUBLISHED'
                        ? () async {
                            if (await confirm(context,
                                    title: 'Retire v$v?',
                                    message: 'Only possible when no organization uses it.',
                                    action: 'Retire') &&
                                context.mounted &&
                                await runAction(context, () => api.retireVersion(t['id'] as String, v), done: 'v$v retired')) {
                              await reload();
                            }
                          }
                        : null,
              ),
          ]),
        ]),
      ),
    );
  }
}

// =========================================================================== D6 operations and audit

/// D6: queues, dead letters (replay), and the platform audit trail.
class OperationsPage extends StatefulWidget {
  final NotificationPlatformApi api;
  const OperationsPage({super.key, required this.api});
  @override
  State<OperationsPage> createState() => _OperationsPageState();
}

class _OperationsPageState extends State<OperationsPage> {
  int key = 0;
  @override
  Widget build(BuildContext context) => Loaded<Json>(
        key: ValueKey(key),
        load: widget.api.ops,
        builder: (context, ops, reload) {
          final dl = (ops['deadLetters'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
          return ListView(children: [
            PageHeader('Operations', actions: [IconButton(tooltip: 'Refresh', onPressed: reload, icon: const Icon(Icons.refresh))]),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                for (final q in (ops['queues'] as List).map((e) => Map<String, dynamic>.from(e as Map)))
                  SizedBox(
                    width: 200,
                    child: Card(
                        child: ListTile(
                            title: Text('${q['queue_name']}'),
                            subtitle: Text('${q['queue_length']} waiting · oldest ${q['oldest_msg_age_sec'] ?? 0}s'))),
                  ),
              ]),
            ),
            const PageHeader('Dead letters', subtitle: 'Replay re-checks consent and channel state and keeps the delivery id.'),
            if (dl.isEmpty) const ListTile(title: Text('No dead letters')),
            for (final d in dl)
              ListTile(
                title: Text('${(d['message'] as Map)['reason'] ?? 'Failed'}'),
                subtitle: Text('${d['enqueued_at']} · ${(d['message'] as Map)['source_queue'] ?? ''}'),
                trailing: (d['message'] as Map)['delivery_id'] == null
                    ? null
                    : OutlinedButton(
                        onPressed: () async {
                          if (await runAction(context, () => widget.api.replayDelivery((d['message'] as Map)['delivery_id'] as String), done: 'Replayed')) {
                            setState(() => key++);
                          }
                        },
                        child: const Text('Replay')),
              ),
          ]);
        },
      );
}

class PlatformAuditPage extends StatelessWidget {
  final NotificationPlatformApi api;
  const PlatformAuditPage({super.key, required this.api});
  @override
  Widget build(BuildContext context) => Loaded<List<Json>>(
        load: api.audit,
        builder: (context, rows, _) => ListView(children: [
          const PageHeader('Audit', subtitle: 'Super admin actions in the notification platform.'),
          for (final r in rows)
            ListTile(dense: true, title: Text('${r['action']}'), subtitle: Text('${r['created_at']} · ${r['actor']}')),
        ]),
      );
}

/// Pretty JSON encode and decode for the provider form.
class JsonCodecLite {
  const JsonCodecLite();
  String encode(Object v) => const JsonEncoder.withIndent('  ').convert(v);
  Object? decode(String s) => jsonDecode(s);
}
