import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';

const _channelLabels = {'IN_APP': 'In-app', 'PUSH': 'Push', 'SMS': 'SMS', 'WHATSAPP': 'WhatsApp'};
const _channelHelp = {
  'IN_APP': 'Bell and inbox in the app',
  'PUSH': 'Alerts on this phone',
  'SMS': 'Text messages to your phone number',
  'WHATSAPP': 'WhatsApp messages to your phone number',
};

/// Channels that need the member's one-time consent before anything is sent.
const consentChannels = {'SMS', 'WHATSAPP'};

String channelLabel(String c) => _channelLabels[c] ?? c;

/// C1: the member's notification settings.
///
/// Lists the channels the organization has on. When the organization controls them (managed organizations),
/// every channel shows "Set by your organization" and the only action is the one-time consent SMS and WhatsApp
/// need. Otherwise members switch channels on and off themselves (0.2 behaviour).
class NotificationPreferencesPage extends StatefulWidget {
  final NotificationApi api;

  /// Shown under the list, e.g. "Phone number wrong? Edit it in your profile".
  final Widget? footer;

  /// Organization name used in the consent text.
  final String organizationName;

  const NotificationPreferencesPage(
      {super.key, required this.api, this.footer, this.organizationName = 'your organization'});

  @override
  State<NotificationPreferencesPage> createState() => _PreferencesState();
}

class _PreferencesState extends State<NotificationPreferencesPage> {
  List<ChannelPreference>? items;
  bool locked = false;
  Object? error;
  String? busyChannel;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(NotificationPreferencesPage old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api) load();
  }

  Future<void> load() async {
    setState(() {
      error = null;
      items = null;
    });
    try {
      final prefs = await widget.api.preferences();
      if (!mounted) return;
      setState(() {
        items = prefs;
        locked = prefs.isNotEmpty && prefs.every((p) => p.locked);
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> save(ChannelPreference p) async {
    setState(() => busyChannel = p.channel);
    try {
      final saved = await widget.api.setPreferences([p]);
      if (mounted) setState(() => items = saved);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e is NotificationApiException && e.code == 'preferences_locked'
                ? 'This channel is set by ${widget.organizationName}'
                : 'Could not save. Try again.')));
      }
    } finally {
      if (mounted) setState(() => busyChannel = null);
    }
  }

  Future<void> askConsent(ChannelPreference p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Allow ${channelLabel(p.channel)} messages?'),
        content: Text('${widget.organizationName} will send bills, receipts and alerts on ${channelLabel(p.channel)}. '
            'You can turn this off any time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow')),
        ],
      ),
    );
    if (ok == true) await save(p.copyWith(consent: true, enabled: true));
  }

  Widget trailing(ChannelPreference p) {
    if (busyChannel == p.channel) {
      return const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (consentChannels.contains(p.channel) && !p.consent) {
      return OutlinedButton(onPressed: () => askConsent(p), child: const Text('Allow'));
    }
    if (p.locked) {
      if (consentChannels.contains(p.channel)) {
        return TextButton(onPressed: () => save(p.copyWith(consent: false)), child: const Text('Withdraw consent'));
      }
      return Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock_outline, size: 16),
        const SizedBox(width: 4),
        Text(p.channel == 'IN_APP' ? 'Always on' : 'Set by your organization',
            style: Theme.of(context).textTheme.bodySmall),
      ]);
    }
    return Switch(
        value: p.enabled,
        onChanged: (v) => save(p.copyWith(enabled: v, consent: consentChannels.contains(p.channel) ? p.consent : v)));
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(child: TextButton(onPressed: load, child: const Text('Could not load settings. Retry')));
    }
    final list = items;
    if (list == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        if (locked)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('${widget.organizationName} chooses how you are notified.',
                style: Theme.of(context).textTheme.bodyMedium),
          ),
        for (final p in list)
          Card(
            child: ListTile(
              key: ValueKey('pref-${p.channel}'),
              title: Text(channelLabel(p.channel)),
              subtitle: Text(consentChannels.contains(p.channel) && !p.consent
                  ? 'Waiting for your consent'
                  : _channelHelp[p.channel] ?? ''),
              trailing: trailing(p),
            ),
          ),
        if (list.isEmpty) const ListTile(title: Text('No channels are on for your organization')),
        if (widget.footer != null) widget.footer!,
      ]),
    );
  }
}

/// C2: full inbox page. Paged with infinite scroll, grouped by day (organization setting), unread filter,
/// mark all read and pull to refresh. Tapping an item marks it read and calls [onAction] with its action.
class NotificationInboxPage extends StatefulWidget {
  final NotificationApi api;
  final Future<void> Function(Map<String, dynamic> action)? onAction;
  final int pageSize;

  /// Called after items are marked read, so a bell badge can refresh.
  final VoidCallback? onChanged;

  /// Defaults to the organization's member settings; pass to skip that request.
  final MemberSettings? settings;

  const NotificationInboxPage(
      {super.key, required this.api, this.onAction, this.pageSize = 30, this.onChanged, this.settings});

  @override
  State<NotificationInboxPage> createState() => NotificationInboxPageState();
}

class NotificationInboxPageState extends State<NotificationInboxPage> {
  final items = <NotificationItem>[];
  String? cursor;
  bool loading = false, done = false, unreadOnly = false;
  Object? error;
  MemberSettings settings = const MemberSettings();
  int _generation = 0;
  final scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    scroll.addListener(() {
      if (scroll.position.pixels > scroll.position.maxScrollExtent - 300) loadMore();
    });
    _init();
  }

  Future<void> _init() async {
    if (widget.settings != null) {
      settings = widget.settings!;
    } else {
      try {
        final s = await widget.api.memberSettings();
        if (mounted) setState(() => settings = s);
      } catch (_) {
        // Older engines have no /v1/settings; keep the defaults.
      }
    }
    await refresh();
  }

  @override
  void didUpdateWidget(NotificationInboxPage old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api) _init();
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    _generation++;
    setState(() {
      items.clear();
      cursor = null;
      done = false;
      error = null;
      loading = false;
    });
    await loadMore();
  }

  Future<void> loadMore() async {
    if (loading || done) return;
    final g = _generation;
    setState(() => loading = true);
    try {
      final page = await widget.api.inboxPage(limit: widget.pageSize, cursor: cursor, unreadOnly: unreadOnly);
      if (!mounted || g != _generation) return;
      setState(() {
        items.addAll(page.items);
        cursor = page.nextCursor;
        done = page.nextCursor == null;
      });
    } catch (e) {
      if (mounted && g == _generation) setState(() => error = e);
    } finally {
      if (mounted && g == _generation) setState(() => loading = false);
    }
  }

  Future<void> markAll() async {
    try {
      await widget.api.markAllRead();
      widget.onChanged?.call();
      await refresh();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not mark all read')));
    }
  }

  Future<void> open(NotificationItem n) async {
    try {
      if (!n.read) {
        await widget.api.markRead(n.id);
        widget.onChanged?.call();
        if (!mounted) return;
        final i = items.indexWhere((x) => x.id == n.id);
        if (i >= 0) {
          setState(() => items[i] = NotificationItem.fromJson({
                'id': n.id, 'title': n.title, 'body': n.body, 'read_at': DateTime.now().toIso8601String(),
                'design': n.design, 'action': n.action, 'created_at': n.createdAt?.toIso8601String(), 'purpose': n.purpose
              }));
        }
      }
      if (n.action != null && widget.onAction != null) await widget.onAction!(n.action!);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Notification action failed')));
    }
  }

  static String dayLabel(DateTime d, DateTime now) {
    final day = DateTime(d.year, d.month, d.day), today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]}${d.year == now.year ? '' : ' ${d.year}'}';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final rows = <Widget>[];
    String? lastDay;
    for (final n in items) {
      if (settings.groupByDay && n.createdAt != null) {
        final label = dayLabel(n.createdAt!.toLocal(), now);
        if (label != lastDay) {
          rows.add(Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(label, style: Theme.of(context).textTheme.labelMedium)));
          lastDay = label;
        }
      }
      rows.add(ListTile(
        key: ValueKey('n-${n.id}'),
        leading: Icon(n.read ? Icons.notifications_none : Icons.notifications_active,
            color: n.read ? null : Theme.of(context).colorScheme.primary),
        title: Text(n.title, style: TextStyle(fontWeight: n.read ? FontWeight.normal : FontWeight.w600)),
        subtitle: Text(n.body),
        trailing: n.createdAt == null
            ? null
            : Text(TimeOfDay.fromDateTime(n.createdAt!.toLocal()).format(context),
                style: Theme.of(context).textTheme.bodySmall),
        onTap: () => open(n),
      ));
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          SegmentedButton<bool>(
            segments: const [ButtonSegment(value: false, label: Text('All')), ButtonSegment(value: true, label: Text('Unread'))],
            selected: {unreadOnly},
            onSelectionChanged: (s) {
              unreadOnly = s.first;
              refresh();
            },
          ),
          const Spacer(),
          TextButton(onPressed: items.any((n) => !n.read) ? markAll : null, child: const Text('Mark all read')),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: refresh,
          child: ListView(controller: scroll, physics: const AlwaysScrollableScrollPhysics(), children: [
            ...rows,
            if (items.isEmpty && !loading && error == null)
              ListTile(title: Text(unreadOnly ? 'No unread notifications' : 'No notifications')),
            if (error != null) Center(child: TextButton(onPressed: loadMore, child: const Text('Could not load. Retry'))),
            if (loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            if (!done && !loading && error == null && items.isNotEmpty)
              Center(child: TextButton(onPressed: loadMore, child: const Text('Load older'))),
          ]),
        ),
      ),
    ]);
  }
}

/// What the push helper needs from the app's push plugin (for example firebase_messaging).
/// The SDK stays free of Firebase; the app implements this in a few lines.
abstract class PushPlatform {
  /// Asks the OS for permission; returns true when granted.
  Future<bool> requestPermission();

  /// Current permission without asking.
  Future<bool> hasPermission();

  Future<String?> getToken();

  /// Stable id for this app installation.
  Future<String> installationId();

  /// `android`, `ios` or `web`.
  String get platform;

  String? get appVersion => null;

  /// Opens the system settings page for this app (used after a denial).
  Future<void> openSettings() async {}
}

/// C3: push permission flow driven by the organization's settings.
///
/// * [maybePrompt] shows the explanation first and then the OS prompt, only when the organization has push on and
///   the prompt timing matches [trigger] (`first_login` or `after_first_notification`).
/// * On grant the device is registered (which records push consent). [unregister] on logout or organization switch.
class NotificationPushHelper {
  final NotificationApi api;
  final PushPlatform push;
  MemberSettings? _settings;

  NotificationPushHelper({required this.api, required this.push, MemberSettings? settings}) : _settings = settings;

  Future<MemberSettings> settings() async => _settings ??= await api.memberSettings();

  /// Whether the explanation should be shown now.
  Future<bool> shouldPrompt(String trigger) async {
    final s = await settings();
    if (!s.pushEnabled || s.pushPrompt == 'off' || s.pushPrompt != trigger) return false;
    return !(await push.hasPermission());
  }

  /// Registers the device if permission is already granted (e.g. on app start). Returns true when registered.
  Future<bool> registerIfPermitted() async {
    if (!(await settings()).pushEnabled || !(await push.hasPermission())) return false;
    return _register();
  }

  Future<bool> _register() async {
    final token = await push.getToken();
    if (token == null) return false;
    await api.registerDevice(
        token: token, installationId: await push.installationId(), platform: push.platform, appVersion: push.appVersion);
    return true;
  }

  /// Explanation dialog, then the OS prompt. Returns true when push ended up registered.
  Future<bool> maybePrompt(BuildContext context, {required String trigger}) async {
    if (!await shouldPrompt(trigger)) return false;
    if (!context.mounted) return false;
    final s = await settings();
    if (!context.mounted) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.pushExplanation ?? 'Turn on notifications'),
        content: const Text("Turn on notifications so you don't miss approvals, payments and visitors. "
            'You can change this later in notification settings.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Turn on')),
        ],
      ),
    );
    if (go != true) return false;
    if (!await push.requestPermission()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Notifications are off for this app'),
          action: SnackBarAction(label: 'Settings', onPressed: () => push.openSettings()),
        ));
      }
      return false;
    }
    return _register();
  }

  Future<void> unregister() async => api.unregisterDevice(await push.installationId());
}
