import 'package:flutter_test/flutter_test.dart';
import 'package:notification_sdk/notification_sdk.dart';
void main(){test('parses unread item',(){final item=NotificationItem.fromJson({'id':'1','title':'Approval','body':'Review'});expect(item.read,false);expect(item.design,isEmpty);});}
