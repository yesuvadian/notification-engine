import 'dart:convert';
import 'package:http/http.dart' as http;
class NotificationApi {
  final Uri baseUrl;
  final String organizationId;
  final Future<String> Function() accessToken;
  final http.Client _client;
  NotificationApi({required this.baseUrl, required this.organizationId, required this.accessToken, http.Client? client}): _client=client??http.Client() {
    if(baseUrl.scheme!='https' && !(baseUrl.scheme=='http' && ['localhost','127.0.0.1','10.0.2.2'].contains(baseUrl.host))) throw ArgumentError('HTTPS required');
  }
  Future<dynamic> request(String method,String path,{Map<String,dynamic>? body}) async {
    final uri=baseUrl.resolve(path.replaceFirst(RegExp(r'^/'), ''));
    if(uri.origin!=baseUrl.origin) throw ArgumentError('Invalid endpoint');
    final req=http.Request(method,uri)..headers.addAll({'Authorization':'Bearer ${await accessToken()}','Content-Type':'application/json','X-Organization-Id':organizationId});
    if(body!=null) req.body=jsonEncode(body);
    final res=await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds:20))).timeout(const Duration(seconds:20));
    if(res.statusCode<200||res.statusCode>=300) throw NotificationApiException(res.statusCode);
    return res.body.isEmpty?null:jsonDecode(res.body);
  }
  Future<List<NotificationItem>> inbox() async {
    final data=await request('GET','/v1/notifications');
    return (data['items'] as List).map((x)=>NotificationItem.fromJson(Map<String,dynamic>.from(x))).toList();
  }
  Future<void> markRead(String id) async {await request('POST','/v1/notifications/${Uri.encodeComponent(id)}/read');}
  Future<int> unreadCount() async => (await request('GET','/v1/notifications/unread-count'))['count'] as int;
  void close()=>_client.close();
}
class NotificationApiException implements Exception {final int status; NotificationApiException(this.status); @override String toString()=> 'Notification request failed ($status)';}
class NotificationItem {
  final String id,title,body; final bool read; final Map<String,dynamic> design; final Map<String,dynamic>? action;
  NotificationItem.fromJson(Map<String,dynamic> j):id=j['id'] as String,title=j['title'] as String,body=j['body'] as String,read=j['read_at']!=null,design=Map<String,dynamic>.from(j['design']??{}),action=j['action']==null?null:Map<String,dynamic>.from(j['action']);
}
