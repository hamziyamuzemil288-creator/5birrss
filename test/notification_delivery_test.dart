// Push notifications are a chain: channel selection, a token row, a payload
// with routing data, and a tap target. These tests pin the pure links in that
// chain and the SQL/Edge Function shape that the deploy applies. They do not
// pretend to replace a real device: FCM delivery and the Android tray are
// verified manually on a phone in the final report.
import 'dart:io';

import 'package:birr5/core/services/notification_service.dart';
import 'package:birr5/features/user/user_notifications_screen.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show Importance;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Android channels', () {
    test('important events get the high-importance channel', () {
      expect(notificationChannelIdFor('ORDER_RECEIVED', {}), 'aliob_orders');
      expect(
        notificationChannelIdFor('ORDER_STATUS', {'event': 'checkout_approved'}),
        'aliob_orders',
      );
      expect(notificationChannelIdFor('RIDE_REQUEST', {}), 'aliob_rides');
      expect(
        notificationChannelIdFor('ORDER_STATUS', {'event': 'driver_arriving'}),
        'aliob_rides',
      );
      expect(
        notificationChannelIdFor('PAYMENT_VERIFIED', {}),
        'aliob_payments',
      );
      expect(notificationChannelIdFor('SECURITY', {}), 'aliob_account');
    });

    test('a valid server channel wins, and an unknown one falls back safely',
        () {
      expect(
        notificationChannelIdFor('ORDER_RECEIVED', {'android_channel': 'aliob_rides'}),
        'aliob_rides',
      );
      expect(
        notificationChannelIdFor('ORDER_RECEIVED',
            {'android_channel': 'not_a_real_channel'}),
        'aliob_orders',
      );
    });

    test('promotions are quiet and general messages are the lowest fallback',
        () {
      final promo = notificationChannelFor('ADMIN_MESSAGE', {'event': 'promotion'});
      expect(promo.id, 'aliob_promotions');
      expect(promo.importance, Importance.low);
      expect(promo.playSound, isFalse);

      final general = notificationChannelFor('SOMETHING_ELSE', {});
      expect(general.id, 'aliob_messages');
    });
  });

  group('notification tap routing', () {
    test('an order notification opens the order waiting/tracking screen', () {
      expect(
        notificationTargetPath({
          'data': {'event': 'checkout_approved', 'order_id': 'order-1'},
        }),
        '/user/orders/order-1/delivery',
      );
    });

    test('a ride goes to its ride, and assignment goes to the order', () {
      expect(
        notificationTargetPath({
          'data': {'event': 'ride_started', 'ride_id': 'ride-1'},
        }),
        '/user/ride-active',
      );
      expect(
        notificationTargetPath({
          'data': {'event': 'delivery_assigned', 'order_id': 'order-2'},
        }),
        '/vehicle/delivery-jobs',
      );
    });

    test('admin checkout and availability targets use the recipient role', () {
      expect(
        notificationTargetPath(
          {
            'data': {
              'event': 'checkout_request',
              'order_id': 'order-3',
              'recipient_role': 'admin',
            },
          },
        ),
        '/admin/checkout-requests',
      );
      expect(
        notificationTargetPath(
          {
            'data': {
              'event': 'availability_response',
              'availability_request_id': 'req-1',
              'recipient_role': 'admin',
            },
          },
        ),
        '/admin/availability',
      );
      expect(
        notificationTargetPath(
          {
            'data': {
              'event': 'availability_response',
              'availability_request_id': 'req-2',
              'accepted': 'true',
            },
          },
        ),
        '/user/cart',
      );
    });

    test('the test notification opens the inbox, and unknown data is dropped',
        () {
      expect(
        notificationTargetPath({
          'data': {'event': 'test_notification'},
        }),
        '/admin-notifications',
      );
      expect(notificationTargetPath({'data': {}}), isNull);
    });
  });

  group('guest token rows', () {
    test('a guest session is still a real user_id row, not an email row', () {
      final row = NotificationService.tokenRowFor(
        userId: 'guest-uuid',
        token: 'fcm-token',
      );
      expect(row['user_id'], 'guest-uuid');
      expect(row['token'], 'fcm-token');
      expect(row['is_active'], isTrue);
      expect(row.containsKey('email'), isFalse);
    });

    test('the guest session opens by registering the device token', () {
      final source =
          File('lib/core/services/guest_session.dart').readAsStringSync();
      expect(source, contains('registerToken'));
      expect(source, contains('ensure'));
    });
  });

  group('server payload contract', () {
    final sql = File(
      'supabase/migrations/20261111000002_notification_delivery_hardening.sql',
    ).readAsStringSync();
    final sender =
        File('supabase/functions/fcm-dispatch/index.ts').readAsStringSync();
    final testFunction =
        File('supabase/functions/notification-test/index.ts').readAsStringSync();
    final workflow =
        File('.github/workflows/deploy-supabase.yml').readAsStringSync();

    test('the database trigger names the channel and the audience', () {
      expect(sql, contains("'android_channel', v_channel"));
      expect(sql, contains("'recipient_role', v_role"));
      expect(sql, contains('public.notification_android_channel'));
      expect(sql, contains('public.notification_recipient_role'));
      expect(sql, contains("'aliob_orders'"));
      expect(sql, contains("'aliob_rides'"));
    });

    test('the sender writes channel, icon and brand colour for the tray', () {
      expect(sender, contains('channel_id: channel'));
      expect(sender, contains('icon: SMALL_ICON'));
      expect(sender, contains('color: BRAND_COLOR'));
      expect(sender, contains('default_sound: true'));
      expect(sender, contains('default_vibrate_timings: true'));
      expect(sender, contains('data.recipient_role ='));
      expect(sender, contains('.update({ is_active: false })'));
    });

    test('the test button has a real authenticated function and a deploy step',
        () {
      expect(testFunction, contains('admin.auth.getUser(token)'));
      expect(testFunction, contains("from(\"notifications\")"));
      expect(testFunction, contains('tray_expected'));
      expect(workflow, contains('supabase functions deploy notification-test'));
    });
  });
}
