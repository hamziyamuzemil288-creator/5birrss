import 'package:supabase_flutter/supabase_flutter.dart';

/// The delivery half of an order: who is bringing it, where it is, and the
/// two buttons that end it.
///
/// Every method here is a thin door to a SECURITY DEFINER function — the
/// state machine, the escrow reveals and the notifications all live in the
/// database (migration 20261026000002), and this class deliberately does no
/// arithmetic and keeps no state of its own. The one piece of state it does
/// own is the live driver stream, which is the SAME stream the ride screens
/// use (`driver_status`, keyed by provider): one GPS channel in the product,
/// not a second one for deliveries.
class DeliveryService {
  DeliveryService._();
  static final DeliveryService instance = DeliveryService._();

  SupabaseClient get _client => Supabase.instance.client;

  /// The tracking payload for the caller (buyer, assigned driver or admin):
  /// delivery state, the drop-off point and the driver's live GPS. Refuses
  /// everyone else, and refuses before the payment is verified.
  Future<Map<String, dynamic>?> tracking(String orderId) async {
    final data =
        await _client.rpc('get_delivery_tracking', params: {'p_order_id': orderId});
    if (data is! Map) return null;
    return Map<String, dynamic>.from(data);
  }

  /// Live fixes for the assigned driver — the refresh signal the tracking map
  /// rides on. RLS scopes the row to the buyer of the delivery it is assigned
  /// to (`delivery_buyer_reads_driver_status`), so an empty stream means "no
  /// access or no driver", never "somebody else's location".
  Stream<List<Map<String, dynamic>>> watchDriverStatus(String providerId) {
    return _client
        .from('driver_status')
        .stream(primaryKey: ['provider_id'])
        .eq('provider_id', providerId);
  }

  /// The driver's "I am here". Records the arrival server-side, which is the
  /// moment the buyer's contact becomes readable to this driver.
  Future<void> markArrived(String orderId) async {
    await _client.rpc('delivery_mark_arrived', params: {'p_order_id': orderId});
  }

  /// The buyer's name and number, for the driver standing at the door. The
  /// server releases it only after arrival is recorded
  /// (`delivery_arrived_at`), so this returns null — not a number — until
  /// the driver has pressed "I am here".
  Future<Map<String, String>?> buyerContact(String orderId) async {
    final data = await _client.rpc('get_delivery_buyer_contact',
        params: {'p_order_id': orderId});
    if (data is! Map) return null;
    final row = Map<String, dynamic>.from(data);
    final phone = (row['buyer_phone'] as String?)?.trim();
    if (phone == null || phone.isEmpty) return null;
    final name = (row['buyer_name'] as String?)?.trim() ?? '';
    return {'name': name.isEmpty ? 'Buyer' : name, 'phone': phone};
  }

  /// The buyer's "I received it": marks the delivery DELIVERED. The order
  /// itself then completes through the existing order-transition path.
  Future<void> confirmReceived(String orderId) async {
    await _client.rpc('delivery_confirm_received',
        params: {'p_order_id': orderId});
  }

  /// Complete the order once the receipt is recorded — the existing Edge
  /// Function and its whitelist, not a second way to finish an order.
  Future<void> completeOrder(String orderId) async {
    final response = await _client.functions.invoke('order-transition', body: {
      'order_id': orderId,
      'new_status': 'COMPLETED',
      'note': 'Buyer confirmed the delivery',
    });
    if (response.status >= 400) {
      final error = response.data is Map
          ? (response.data['error'] as String? ?? 'Unknown error')
          : 'Unknown error';
      throw Exception(error);
    }
  }

  /// The driver's own delivery list.
  Future<List<Map<String, dynamic>>> myJobs() async {
    final data = await _client.rpc('my_delivery_jobs');
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Admin: the approved vehicle providers who can be assigned.
  Future<List<Map<String, dynamic>>> adminDrivers() async {
    final data = await _client.rpc('admin_delivery_drivers');
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Admin: attach a driver to a delivery order.
  Future<void> assignDriver(
      String orderId, String driverProviderId) async {
    await _client.rpc('assign_delivery_driver', params: {
      'p_order_id': orderId,
      'p_driver_provider_id': driverProviderId,
    });
  }
}
