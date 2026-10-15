import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The one renderer for the app's legal documents.
///
/// WHY THIS IS ITS OWN WIDGET
/// --------------------------
/// There are two documents and they must not read as two designs: the combined
/// Terms & Privacy Policy that the registration checkbox accepts (`/terms`)
/// and the standalone Terms of Service that the About screen and the profile
/// menu open (`/terms-of-service`). Before this existed each screen would have
/// carried its own copy of the markup rules, and the second copy is always the
/// one that drifts — a carriage return here, a bold span there, and the two
/// legal pages stop looking like one product.
///
/// The markup is deliberately the smallest thing that will do: `# ` for the
/// title, `## ` for a section, `- ` for a bullet, `1. ` for a numbered item,
/// and `**bold**` inside a line. Anything richer belongs in a document format,
/// not in a string literal in a Dart file.
///
/// EVERY amount of copy here is public: both documents are reachable without
/// signing in from the profile menu, and the same text is mirrored to the
/// public GitHub-hosted pages in `docs/` that Play Console points at.
class LegalDocument extends StatelessWidget {
  final String text;

  const LegalDocument({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final blocks = text.split('\n').map(_buildBlock).toList();
    return Container(
      color: AppTheme.surface,
      child: Scrollbar(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
          children: blocks,
        ),
      ),
    );
  }
}

/// Minimal inline renderer for **bold** spans (the only markup the legal text
/// uses inside a line).
List<InlineSpan> _inlineSpans(String line, TextStyle base, TextStyle bold) {
  final spans = <InlineSpan>[];
  final regex = RegExp(r'\*\*(.+?)\*\*');
  var start = 0;
  for (final m in regex.allMatches(line)) {
    if (m.start > start) {
      spans.add(TextSpan(text: line.substring(start, m.start), style: base));
    }
    spans.add(TextSpan(text: m.group(1)!.replaceAll('**', ''), style: bold));
    start = m.end;
  }
  if (start < line.length) {
    spans.add(TextSpan(text: line.substring(start), style: base));
  }
  return spans;
}

/// One rendered block of a legal document (heading, bullet, numbered item or
/// paragraph).
Widget _buildBlock(String rawLine) {
  final line = rawLine.trimRight();
  if (line.startsWith('# ')) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child:
          Text(line.substring(2), style: AppTheme.heading.copyWith(fontSize: 22)),
    );
  }
  if (line.startsWith('## ')) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(line.substring(3), style: AppTheme.sectionHeader),
    );
  }
  if (line.startsWith('- ')) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7),
            child: SizedBox(
              width: 6,
              height: 6,
              child: DecoratedBox(
                decoration:
                    BoxDecoration(color: AppTheme.teal, shape: BoxShape.circle),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: _inlineSpans(
                  line.substring(2),
                  AppTheme.bodyMedium.copyWith(
                      color: AppTheme.textPrimary, height: 1.6),
                  AppTheme.bodyStrong,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  final numbered = RegExp(r'^(\d+)\.\s+(.*)$').firstMatch(line);
  if (numbered != null) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text('${numbered.group(1)}.',
                style: AppTheme.bodyStrong.copyWith(height: 1.6)),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: _inlineSpans(
                  numbered.group(2)!,
                  AppTheme.bodyMedium.copyWith(
                      color: AppTheme.textPrimary, height: 1.6),
                  AppTheme.bodyStrong,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  if (line.isEmpty) return const SizedBox(height: 8);
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text.rich(
      TextSpan(
        children: _inlineSpans(
          line,
          AppTheme.bodyMedium.copyWith(
              color: AppTheme.textPrimary, height: 1.65),
          AppTheme.bodyStrong,
        ),
      ),
    ),
  );
}
