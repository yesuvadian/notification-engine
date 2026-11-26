import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:notification_sdk/notification_sdk.dart';

void main() => runApp(MaterialApp(title: 'Notification Demo', theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true), home: const Demo()));

class Demo extends StatefulWidget {
  const Demo({super.key});
  @override
  State<Demo> createState() => _DemoState();
}
class _DemoState extends State<Demo> {
  final user = TextEditingController();
  final admin = TextEditingController();
  final project = TextEditingController();
  final org = TextEditingController();
  NotificationApi? userApi, adminApi;
  String status = 'Loading configuration…';
  bool ready = false, busy = false;
  int tab = 0, revision = 0;
  @override
  void initState() { super.initState(); load(); }
  Future<void> load() async {
    try {
      final c = jsonDecode(await rootBundle.loadString('assets/config.json')) as Map<String,dynamic>;
      if (!mounted) return;
      project.text = c['supabase_project_id'] as String;
      org.text = c['organization_id'] as String;
      setState(() { ready = true; status = 'Enter the scoped DEV tokens from the cloud seed script.'; });
    } catch(e) { if(mounted) setState(() { status = 'Configuration error: $e'; }); }
  }
  Future<void> connect() async {
    final p = project.text.trim();
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(p) || org.text.trim().isEmpty || user.text.trim().isEmpty || admin.text.trim().isEmpty) {
      setState(() => status = 'Enter a valid project reference, organization ID and both tokens.'); return;
    }
    setState(() { busy = true; status = 'Checking user and admin access…'; });
    final url = Uri.parse('https://$p.supabase.co/functions/v1/notification/');
    final u = user.text.trim(), a = admin.text.trim();
    final ua = NotificationApi(baseUrl: url, organizationId: org.text.trim(), accessToken: () async => u);
    final aa = NotificationApi(baseUrl: url, organizationId: org.text.trim(), accessToken: () async => a);
    try {
      final count = await ua.unreadCount();
      await aa.request('GET','/v1/admin/templates');
      if (!mounted) { ua.close(); aa.close(); return; }
      setState(() { userApi = ua; adminApi = aa; status = 'Connected. Unread: $count'; busy = false; tab = 0; });
      user.clear(); admin.clear();
    } catch(e) { ua.close(); aa.close(); if(mounted) setState(() { busy = false; status = 'Connection failed: $e. Check deployment, token expiry and schema exposure.'; }); }
  }
  void disconnect() { userApi?.close(); adminApi?.close(); setState(() { userApi = null; adminApi = null; status = 'Disconnected'; }); }
  @override
  void dispose() { userApi?.close(); adminApi?.close(); user.dispose(); admin.dispose(); project.dispose(); org.dispose(); super.dispose(); }
  Widget field(TextEditingController c, String label, {bool secret = false}) => Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: c, obscureText: secret, autocorrect: false, enableSuggestions: false, decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())));
  @override
  Widget build(BuildContext context) {
    final u = userApi, a = adminApi;
    if(u == null || a == null) return Scaffold(appBar: AppBar(title: const Text('Notification DEV setup')), body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: ListView(padding: const EdgeInsets.all(24), shrinkWrap: true, children: [Text(status), const SizedBox(height: 20), field(project,'Supabase project reference'), field(org,'Organization ID'), field(user,'DEV user token',secret:true), field(admin,'DEV admin token',secret:true), FilledButton(onPressed: ready && !busy ? connect : null, child: const Text('Connect and test API')), if(busy) const LinearProgressIndicator(), const SizedBox(height: 12), const Text('Local testing only. Tokens are held in memory, not saved. Never enter a service-role or worker token here.')]))));
    return Scaffold(appBar: AppBar(title: const Text('Notification DEV demo'), actions: [NotificationBell(key: ValueKey('bell-$revision'),api:u,onPressed:()=>setState(()=>tab=0)), IconButton(tooltip:'Refresh',onPressed:()=>setState(()=>revision++),icon:const Icon(Icons.refresh)), TextButton(onPressed:disconnect,child:const Text('Disconnect'))]), body: IndexedStack(index:tab,children:[NotificationInbox(key:ValueKey('inbox-$revision'),api:u,onAction:(action) async { if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Demo action: $action'))); }), NotificationAdmin(api:a)]), bottomNavigationBar: NavigationBar(selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),destinations:const [NavigationDestination(icon:Icon(Icons.inbox),label:'Inbox'),NavigationDestination(icon:Icon(Icons.admin_panel_settings),label:'Super Admin')]));
  }
}
