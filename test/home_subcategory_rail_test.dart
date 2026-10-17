// The chips above Fresh Finds on Home, and the order they come out in.
//
// WHY THIS IS A TEST AND NOT A COMMENT
// ------------------------------------
// `ranked_categories` ranks every active category — the three mothers and
// their leaves — by this week's completed work. Home used to print that list
// verbatim, so the rail repeated the three big cards above it. It now names
// the SMALL categories, and the only reason the order is not alphabetical is
// the rule in subcategoryRailOrder: leaves are taken one per mother per round,
// in the MOTHERS' ranked order.
//
// That rule is invisible on screen when it is right and looks plausible when
// it is wrong — an alphabetical rail of real categories still renders. So the
// failure mode is silent, which is exactly what a test is for.
import 'package:birr5/features/user/user_home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// One row of `ranked_categories`, with only the column the rail reads.
Map<String, dynamic> row(String id) => {'category_id': id, 'name': id};

/// A mother's id -> its leaves' ids, as the categories read returns it.
Map<String, String> tree(Map<String, List<String>> mothers) => {
      for (final entry in mothers.entries)
        for (final leaf in entry.value) leaf: entry.key,
    };

void main() {
  // Deliberately interleaved, the way the server returns them: mothers and
  // leaves mixed, ordered by this week's work. `shops` traded most, then
  // `services`.
  final ranked = [
    row('shops'), // 0 — busiest mother
    row('services'), // 1
    row('food'), // 2
    row('electronics'), // 3
    row('construction'), // 4
    row('watches'), // 5
  ];
  final motherOf = tree({
    'shops': ['food', 'electronics'],
    'services': ['construction', 'watches'],
  });

  group('the rail names small categories, never the mother cards', () {
    test('mothers are dropped and leaves are kept, in mother order', () {
      final rail = subcategoryRailOrder(ranked, motherOf);
      expect(rail.map((r) => r['category_id']),
          ['food', 'construction', 'electronics', 'watches']);
    });

    test('one leaf per mother per round keeps the rail mixed', () {
      // The first two chips are the busiest trade's first specialty and the
      // next trade's first specialty — not the busiest trade's first two.
      final rail = subcategoryRailOrder(ranked, motherOf);
      expect(rail[0]['category_id'], 'food');
      expect(rail[1]['category_id'], 'construction');
    });

    test('a leaf with no known mother is dropped', () {
      final rail = subcategoryRailOrder(
        [...ranked, row('lost-leaf')],
        motherOf,
      );
      expect(rail.map((r) => r['category_id']), isNot(contains('lost-leaf')));
      expect(rail, hasLength(4));
    });

    test('the cap is honoured, and a mother with one leaf stops after it', () {
      final rail = subcategoryRailOrder(ranked, motherOf, maxChips: 3);
      expect(rail.map((r) => r['category_id']),
          ['food', 'construction', 'electronics']);
    });

    test('nothing to show is an empty rail, not the mothers back again', () {
      expect(subcategoryRailOrder(const [], motherOf), isEmpty);
      expect(subcategoryRailOrder(ranked, const {}), isEmpty);
      expect(subcategoryRailOrder(ranked, motherOf, maxChips: 0), isEmpty);
    });

    test('a leaf list longer than the cap never repeats a chip', () {
      // Six leaves under one mother and a cap of four: the rail takes the
      // first four and stops, rather than looping back to the top.
      final many = tree({'shops': ['a', 'b', 'c', 'd', 'e', 'f']});
      final rows = [row('shops'), for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) row(id)];
      final rail = subcategoryRailOrder(rows, many, maxChips: 4);
      expect(rail.map((r) => r['category_id']), ['a', 'b', 'c', 'd']);
    });
  });
}
