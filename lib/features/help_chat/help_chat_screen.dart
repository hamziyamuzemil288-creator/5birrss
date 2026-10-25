import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_deep_links.dart';

// Task 14: the chat NEVER shows personal/direct contact details. Escalation
// goes to the in-app Appeal Page via server-provided deep links — the old
// Call/Message/Email buttons and their contact constants were removed.

class _Msg {
  final String role; // 'user' | 'assistant'
  final String content;
  final bool handoff; // true → escalation bubble (links come from the server)
  final List<String> options; // tappable quick replies (ticket flow)
  final List<({String label, String route})>
      links; // tappable in-app deep links
  final String logId; // chat_logs row for this assistant reply
  const _Msg(
    this.role,
    this.content, {
    this.handoff = false,
    this.options = const [],
    this.links = const [],
    this.logId = '',
  });
}

class HelpChatScreen extends StatefulWidget {
  const HelpChatScreen({super.key});

  @override
  State<HelpChatScreen> createState() => _HelpChatScreenState();
}

class _HelpChatScreenState extends State<HelpChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _messages = [
    const _Msg(
        'assistant',
        'Hi! 👋 I\'m the Aliob assistant.\n\n'
        'I can help you with:\n'
        '• Signing up, verifying your ID, or an account that was turned down\n'
        '• Prices — why a fare differs by vehicle type or by city, and what '
        'the platform fee covers\n'
        '• Finding a provider — browsing providers and seeing their photos\n'
        '• Buying, orders, escrow and payments, wallet recharges, and points\n'
        '• Booking a ride, and where your pickup point is\n'
        '• Reporting a problem, or appealing a decision\n\n'
        'Just describe what you need in your own words — you don\'t need to '
        'pick a category first. If something needs a person, I\'ll take you '
        'to the appeal form with your details attached.',
        options: [
          'Why is the price different for a bajaj?',
          'How do I see a provider\'s photos?',
          'How do I recharge my wallet?',
          'I want to report an issue',
        ]),
  ];
  bool _sending = false;
  final Set<String> _rated = {}; // chat_logs ids already given feedback

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    _controller.clear();
    await _sendUserMessage(text);
  }

  /// Sends one of the assistant's suggested options as a user message.
  Future<void> _sendOption(String text) async {
    if (_sending) return;
    await _sendUserMessage(text);
  }

  Future<void> _sendUserMessage(String text) async {
    setState(() {
      _messages.add(_Msg('user', text));
      _sending = true;
      // Quick-reply options are one-shot: they disappear once used.
      final idx = _messages.indexWhere((m) => m.options.isNotEmpty);
      if (idx >= 0) {
        _messages[idx] = _Msg(_messages[idx].role, _messages[idx].content,
            handoff: _messages[idx].handoff);
      }
    });
    _scrollToEnd();    String reply;
    bool handoff = false;
    String logId = '';
    var links = const <({String label, String route})>[];
    var suggestions = const <String>[];
    try {
      // Skip the local greeting so history starts with a user turn.
      final history = _messages
          .skip(1)
          .map((m) => {'role': m.role, 'content': m.content})
          .toList();
      final res = await Supabase.instance.client.functions
          .invoke('repo-chat', body: {'messages': history});
      final data = res.data as Map?;
      reply = data?['reply'] as String? ??
          'Sorry, something went wrong. Please try again.';
      handoff = data?['handoff'] == true;
      logId = data?['log_id'] as String? ?? '';
      // Quick replies from the server (greeting, help menu, fallback). The
      // server decides WHICH questions are worth offering; this screen only
      // checks that they are short, non-empty text a person could have typed.
      final rawSuggestions = data?['suggestions'];
      if (rawSuggestions is List) {
        suggestions = rawSuggestions
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty && s.length <= 80)
            .take(4)
            .toList();
      }
      final rawLinks = data?['links'];
      final knownRoutes = kKnownRoutes.map((k) => k.route).toSet();
      if (rawLinks is List) {
        links = rawLinks
            .whereType<Map>()
            .map((m) => (
                  label: m['label'] as String? ?? '',
                  route: m['route'] as String? ?? '',
                ))
            .where((l) =>
                l.label.isNotEmpty && knownRoutes.contains(l.route))
            .toList();
      }
    } on FunctionException catch (e) {
      reply = e.status == 429
          ? "You've reached today's help limit. Please try again tomorrow."
          : 'Sorry, help is unavailable right now. Please try again.';
    } catch (_) {
      reply = 'Sorry, something went wrong. Please try again.';
    }

    if (!mounted) return;
    setState(() {
      _messages.add(_Msg('assistant', reply,
          handoff: handoff,
          links: links,
          options: suggestions,
          logId: logId));
      _sending = false;
    });
    _scrollToEnd();
    // Intent is tagged server-side on the assistant row; the client-mirrored
    // user row stays untagged so the feedback summary groups cleanly.
    _logTurn(text, reply, null, logId);
  }

  /// Best-effort local mirror of the conversation into chat_logs. The Edge
  /// Function logs the assistant row server-side (returning its id so this
  /// screen can attach feedback to the exact reply); the user's question is
  /// logged client-side so late client failures never lose the question.
  Future<void> _logTurn(
      String question, String answer, String? intent, String answerLogId) async {
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentUser?.id;
      if (uid == null) return;
      await client.from('chat_logs').insert({
        'user_id': uid,
        'role': 'user',
        'content': question,
        'intent': intent,
      });
      if (answerLogId.isNotEmpty) {
        // Server already logged the answer; nothing more to write.
        return;
      }
      await client.from('chat_logs').insert({
        'user_id': uid,
        'role': 'assistant',
        'content': answer,
        'intent': intent,
      });
    } catch (_) {
      // Logging must never break the chat flow.
    }
  }

  /// Thumbs up/down on an assistant reply → chat_logs.helpful.
  Future<void> _rate(String logId, bool helpful) async {
    if (logId.isEmpty) return;
    try {
      await Supabase.instance.client
          .from('chat_logs')
          .update({'helpful': helpful})
          .eq('id', logId);
    } catch (_) {
      // Non-fatal.
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Tappable quick-reply chip shown under the latest assistant message.
  Widget _optionChip(String label) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 13)),
      onPressed: _sending ? null : () => _sendOption(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length + (_sending ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == _messages.length) {
                  return const Padding(
                    padding: EdgeInsets.all(8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final m = _messages[i];
                final isUser = m.role == 'user';
                final isLast = i == _messages.length - 1;
                return Column(
                  crossAxisAlignment: isUser
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment:
                          isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.8,
                        ),
                        decoration: BoxDecoration(
                          color: isUser
                              ? scheme.primaryContainer
                              : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SelectableText(m.content),
                            if (m.links.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: m.links
                                    .map((l) => ActionChip(
                                          label: Text(l.label,
                                              style: const TextStyle(
                                                  fontSize: 13)),
                                          onPressed: () =>
                                              GoRouter.of(context).push(l.route),
                                        ))
                                    .toList()),
                            ],
                            // Task 14: no Call/Message/Email buttons — an
                            // escalation bubble relies on the server-provided
                            // in-app deep links above (Submit an appeal).
                          ],
                        ),
                      ),
                    ),
                    // Quick replies render under the latest assistant message
                    // so the conversation can't be derailed from old bubbles.
                    if (!isUser && isLast && m.options.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children:
                            m.options.map((o) => _optionChip(o)).toList(),
                      ),
                    ],
                    // Feedback thumbs on the latest assistant reply (feeds
                    // the chat_logs self-improvement loop). Hidden once used.
                    if (!isUser &&
                        isLast &&
                        m.logId.isNotEmpty &&
                        !_rated.contains(m.logId)) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Helpful?',
                              style: TextStyle(fontSize: 12)),
                          const SizedBox(width: 4),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Yes',
                            onPressed: () {
                              _rated.add(m.logId);
                              _rate(m.logId, true);
                              setState(() {});
                            },
                            icon: const Icon(Icons.thumb_up_alt_outlined,
                                size: 18),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'No',
                            onPressed: () {
                              _rated.add(m.logId);
                              _rate(m.logId, false);
                              setState(() {});
                            },
                            icon: const Icon(Icons.thumb_down_alt_outlined,
                                size: 18),
                          ),
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Ask a question…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
