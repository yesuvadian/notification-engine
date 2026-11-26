import 'package:flutter/material.dart';
import 'package:notification_sdk/notification_sdk.dart';

import 'common.dart';
import 'platform_api.dart';
import 'platform_pages.dart';
import 'workspace.dart';

/// One menu entry the console shows for the notifications module.
class NotificationMenuItem {
  final String id;
  final String label;
  final IconData icon;
  final WidgetBuilder builder;
  const NotificationMenuItem(this.id, this.label, this.icon, this.builder);
}

/// Entry point for a super admin console (astute_console): menu pages, the per-organization tab,
/// and an overview card. The console passes the signed-in super admin's access token; no service,
/// product or worker token is ever held by Flutter.
class NotificationAdminModule {
  final NotificationPlatformApi api;

  /// Product currently selected at console login (code in ntf_products).
  final String productCode;

  /// How the console opens an organization; defaults to pushing [OrganizationWorkspace].
  final OpenOrganization? onOpenOrganization;

  NotificationAdminModule({required this.api, required this.productCode, this.onOpenOrganization});

  factory NotificationAdminModule.connect({
    required String baseUrl,
    required Future<String> Function() accessToken,
    required String productCode,
    OpenOrganization? onOpenOrganization,
  }) =>
      NotificationAdminModule(
          api: NotificationPlatformApi(baseUrl: Uri.parse(baseUrl), accessToken: accessToken),
          productCode: productCode,
          onOpenOrganization: onOpenOrganization);

  /// Pages for one product's organizations (shown inside that product in the console).
  List<NotificationMenuItem> get productMenu => [
        NotificationMenuItem('ntf-organizations', 'Organizations', Icons.apartment,
            (_) => OrganizationsPage(api: api, productCode: productCode, onOpen: onOpenOrganization)),
      ];

  /// Engine-wide pages (shown under the console's own "Notification Engine" entry, not inside a product).
  List<NotificationMenuItem> get engineMenu => [
        NotificationMenuItem('ntf-products', 'Products', Icons.widgets_outlined, (_) => ProductsPage(api: api)),
        NotificationMenuItem('ntf-channels', 'Channels', Icons.cell_tower, (_) => PlatformChannelsPage(api: api)),
        NotificationMenuItem('ntf-templates', 'Templates', Icons.article_outlined, (_) => PlatformTemplatesPage(api: api, productCode: productCode.isEmpty ? null : productCode)),
        NotificationMenuItem('ntf-operations', 'Operations', Icons.monitor_heart_outlined, (_) => OperationsPage(api: api)),
        NotificationMenuItem('ntf-audit', 'Audit', Icons.history, (_) => PlatformAuditPage(api: api)),
      ];

  /// Every page (product pages first).
  List<NotificationMenuItem> get menu => [...productMenu, ...engineMenu];

  /// True when the signed-in user is a platform super admin of the engine (401/403 means not).
  Future<bool> canAdminister() async {
    try {
      await api.overview();
      return true;
    } on NotificationApiException catch (e) {
      if (e.status == 401 || e.status == 403) return false;
      rethrow;
    }
  }

  /// The "Notifications" tab inside the console's organization workspace.
  Widget organizationTab(String organizationId, String organizationName) => OrganizationWorkspace(
      api: api, productCode: productCode, organizationId: organizationId, organizationName: organizationName);

  /// Small card for the console overview: organizations, products, queue backlog and dead letters.
  Widget overviewCard() => NotificationOverviewCard(api: api);
}

class NotificationOverviewCard extends StatelessWidget {
  final NotificationPlatformApi api;
  const NotificationOverviewCard({super.key, required this.api});

  @override
  Widget build(BuildContext context) => Card(
        child: SizedBox(
          height: 140,
          child: Loaded<Json>(
            load: api.overview,
            builder: (context, o, reload) {
              String n(String k) => '${o[k] ?? 0}';
              final queues = (o['queues'] as List? ?? []).cast<Map>();
              final backlog = queues.fold<int>(0, (t, q) => t + ((q['queue_length'] as num?)?.toInt() ?? 0));
              final dlq = queues.where((q) => '${q['queue_name']}'.contains('dlq')).fold<int>(0, (t, q) => t + ((q['queue_length'] as num?)?.toInt() ?? 0));
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Notifications', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Wrap(spacing: 24, runSpacing: 8, children: [
                    _stat(context, 'Organizations', n('organizations')),
                    _stat(context, 'Products', n('products')),
                    _stat(context, 'Queued', '${backlog - dlq}'),
                    _stat(context, 'Dead letters', '$dlq'),
                  ]),
                ]),
              );
            },
          ),
        ),
      );

  Widget _stat(BuildContext context, String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, key: ValueKey('ov-$label'), style: Theme.of(context).textTheme.headlineSmall),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}
