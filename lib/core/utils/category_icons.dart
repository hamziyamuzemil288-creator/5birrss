import 'package:flutter/material.dart';

/// The glyph for a category, decided by its `marketplace_sector`.
///
/// ONE definition, because every surface that draws a category has to agree
/// about it: the home rail's "Top categories this week" chips and the rows of
/// the group screen and the category screen those chips and cards open. The
/// rule had two homes before this file — the private copy on the home screen
/// and the generic `Icons.category_outlined` the group screen used for every
/// row — so the same food category wore a fork on Home and a shopping-bag
/// glyph one tap later.
///
/// A sector with no mapping falls back to the generic category glyph rather
/// than guessing from the category's name: a wrong icon reads as a different
/// trade, and no icon reads as "no opinion". A null/empty sector (an admin can
/// seed a category without one) takes the same fallback.
IconData categoryIconForSector(String? marketplaceSector) {
  switch ((marketplaceSector ?? '').trim().toUpperCase()) {
    case 'FOOD':
      return Icons.restaurant_outlined;
    case 'RETAIL':
      return Icons.storefront_outlined;
    case 'ACCOMMODATION':
      return Icons.hotel_outlined;
    case 'SERVICES':
      return Icons.design_services_outlined;
    case 'TRANSPORT':
      return Icons.directions_car_outlined;
    default:
      return Icons.category_outlined;
  }
}
