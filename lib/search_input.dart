import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';

class SearchInput extends StatefulWidget {
  const SearchInput({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSearch,
    this.onChanged,
    this.suggestions,
    this.onCancel,
    this.autofocus = false,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSearch;
  final ValueChanged<String>? onChanged;
  final Future<List<String>> Function(String)? suggestions;
  final VoidCallback? onCancel;
  final bool autofocus;
  @override
  State<SearchInput> createState() => _SearchInputState();
}

class _SearchInputState extends State<SearchInput> {
  static const _televisionLimit = 4;

  final _focus = FocusNode();
  final _submitFocus = FocusNode();
  final _clearFocus = FocusNode();
  final _optionFocus = <FocusNode>[];
  Timer? _timer;
  Completer<Iterable<String>>? _pending;
  int _generation = 0;
  bool _selected = false;
  bool _television = false;
  List<String> _suggestions = const [];
  final _cache = <String, List<String>>{};

  static final _remoteConfirmKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  };
  static final _hardwareEnterKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
  };

  List<String> get _televisionOptions {
    if (_suggestions.length <= _televisionLimit) return _suggestions;
    return _suggestions.sublist(0, _televisionLimit);
  }

  void _cancel() {
    _timer?.cancel();
    widget.onCancel?.call();
    _generation++;
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.complete(const []);
    }
  }

  @override
  void didUpdateWidget(SearchInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.suggestions == null) {
      _cancel();
      _suggestions = const [];
    }
  }

  @override
  void dispose() {
    _cancel();
    for (final node in _optionFocus) {
      node.dispose();
    }
    _optionFocus.clear();
    _submitFocus.dispose();
    _clearFocus.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<Iterable<String>> _options(TextEditingValue value) async {
    _cancel();
    final query = value.text.trim();
    if (query.isEmpty ||
        query.length > 100 ||
        widget.suggestions == null ||
        !value.composing.isCollapsed) {
      return const [];
    }
    if (_cache.containsKey(query)) return _cache[query]!;
    final generation = _generation;
    final pending = Completer<Iterable<String>>();
    _pending = pending;
    _timer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final result = (await widget.suggestions!(
          query,
        )).where((s) => s.trim().isNotEmpty).toSet().take(10).toList();
        if (generation == _generation && mounted) {
          if (_cache.length >= 32) _cache.remove(_cache.keys.first);
          _cache[query] = result;
          if (!pending.isCompleted) pending.complete(result);
        }
      } catch (_) {}
      if (!pending.isCompleted) pending.complete(const []);
    });
    return pending.future;
  }

  Future<List<String>> _televisionQuery(String query) async {
    final cached = _cache[query];
    if (cached != null) return cached;
    final found = await widget.suggestions!(query);
    final result = <String>[];
    for (final item in found) {
      final text = item.trim();
      if (text.isEmpty) continue;
      if (result.contains(text)) continue;
      result.add(text);
      if (result.length >= 10) break;
    }
    if (_cache.length >= 32) _cache.remove(_cache.keys.first);
    _cache[query] = result;
    return result;
  }

  void _scheduleTelevisionSuggestions(String value) {
    _timer?.cancel();
    _generation++;
    final query = value.trim();
    if (widget.suggestions == null || query.isEmpty || query.length > 100) {
      if (_suggestions.isEmpty) return;
      setState(() {
        _suggestions = const [];
      });
      return;
    }
    final cached = _cache[query];
    if (cached != null) {
      setState(() {
        _suggestions = cached;
      });
      return;
    }
    final generation = _generation;
    _timer = Timer(const Duration(milliseconds: 300), () async {
      List<String> result = const [];
      try {
        result = await _televisionQuery(query);
      } catch (_) {}
      if (!mounted) return;
      if (generation != _generation) return;
      setState(() {
        _suggestions = result;
      });
    });
  }

  void _changed(String value) {
    widget.onChanged?.call(value);
    if (_television) _scheduleTelevisionSuggestions(value);
    setState(() {});
  }

  void _clear() {
    _cancel();
    widget.controller.clear();
    widget.onChanged?.call('');
    setState(() {
      _suggestions = const [];
    });
  }

  void _confirm(String value, VoidCallback submitted) {
    _selected = false;
    submitted();
    if (!_selected) _submit(value);
  }

  KeyEventResult _confirmKey(
    KeyEvent event,
    TextEditingController controller,
    VoidCallback submitted,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final remote = _remoteConfirmKeys.contains(key);
    final enter =
        defaultTargetPlatform == TargetPlatform.android &&
        _hardwareEnterKeys.contains(key);
    if (!remote && !enter) return KeyEventResult.ignored;
    _confirm(controller.text, submitted);
    return KeyEventResult.handled;
  }

  bool _televisionConfirmKey(LogicalKeyboardKey key) {
    if (_remoteConfirmKeys.contains(key)) return true;
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    return _hardwareEnterKeys.contains(key);
  }

  bool _focusOn(FocusNode node) {
    if (node.context == null) return false;
    node.requestFocus();
    return true;
  }

  FocusNode _optionNode(int index) {
    while (_optionFocus.length <= index) {
      _optionFocus.add(FocusNode());
    }
    return _optionFocus[index];
  }

  KeyEventResult _moved(bool moved) {
    return moved ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  KeyEventResult _televisionConfirm() {
    final focused = _optionFocus.indexWhere((node) => node.hasFocus);
    if (focused >= 0 && focused < _suggestions.length) {
      _submit(_suggestions[focused]);
      return KeyEventResult.handled;
    }
    if (_clearFocus.hasFocus) {
      _clear();
      return KeyEventResult.handled;
    }
    _submitField();
    return KeyEventResult.handled;
  }

  KeyEventResult _televisionKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_televisionConfirmKey(key)) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      return _televisionConfirm();
    }
    final down = key == LogicalKeyboardKey.arrowDown;
    final up = key == LogicalKeyboardKey.arrowUp;
    if (!down && !up) return KeyEventResult.ignored;
    final options = _televisionOptions;
    if (_focus.hasFocus) {
      if (options.isEmpty) {
        if (!down) return KeyEventResult.ignored;
        return _moved(_focusOn(_submitFocus));
      }
      final index = down ? 0 : options.length - 1;
      return _moved(_focusOn(_optionNode(index)));
    }
    final focused = _optionFocus.indexWhere((item) => item.hasFocus);
    if (focused >= 0 && focused < options.length) {
      final next = down ? focused + 1 : focused - 1;
      if (next >= 0 && next < options.length) {
        return _moved(_focusOn(_optionNode(next)));
      }
      return _moved(_focusOn(down ? _submitFocus : _focus));
    }
    if (!down && (_submitFocus.hasFocus || _clearFocus.hasFocus)) {
      if (options.isEmpty) return _moved(_focusOn(_focus));
      return _moved(_focusOn(_optionNode(options.length - 1)));
    }
    return KeyEventResult.ignored;
  }

  void _submitField() {
    _submit(widget.controller.text);
  }

  void _submit(String value) {
    _cancel();
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _focus.unfocus();
    widget.onSearch(value.trim());
  }

  Widget _highlight(String value) {
    final query = widget.controller.text.trim().toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (query.isNotEmpty) {
      final match = value.toLowerCase().indexOf(query, start);
      if (match < 0) break;
      if (match > start) {
        spans.add(TextSpan(text: value.substring(start, match)));
      }
      spans.add(
        TextSpan(
          text: value.substring(match, match + query.length),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      start = match + query.length;
    }
    if (start < value.length) spans.add(TextSpan(text: value.substring(start)));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _televisionOptionTile(BuildContext context, int index, String value) {
    final colors = Theme.of(context).colorScheme;
    final node = _optionNode(index);
    final focused = node.hasFocus;
    final background = focused
        ? colors.primaryContainer
        : colors.surfaceContainerHighest.withValues(alpha: .35);
    final border = focused ? colors.primary : Colors.transparent;
    final icon = focused ? colors.primary : colors.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Focus(
        focusNode: node,
        onFocusChange: (hasFocus) {
          if (mounted) setState(() {});
          if (!hasFocus) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && node.hasFocus) {
              Scrollable.ensureVisible(context);
            }
          });
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _submit(value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border, width: 2),
            ),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 18, color: icon),
                const SizedBox(width: 10),
                Expanded(child: _highlight(value)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _televisionOptionTiles(BuildContext context) {
    final options = _televisionOptions;
    final tiles = <Widget>[];
    for (var index = 0; index < options.length; index++) {
      tiles.add(_televisionOptionTile(context, index, options[index]));
    }
    return tiles;
  }

  Widget _televisionAction(
    BuildContext context,
    FocusNode node,
    String label,
    VoidCallback onPressed,
  ) {
    final colors = Theme.of(context).colorScheme;
    final focused = node.hasFocus;
    final background = focused ? colors.primaryContainer : Colors.transparent;
    final border = focused ? colors.primary : colors.outlineVariant;
    final style = TextStyle(fontSize: 17, color: colors.onSurface);
    return Focus(
      focusNode: node,
      onFocusChange: (hasFocus) {
        if (mounted) setState(() {});
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border, width: 2),
          ),
          child: Text(label, style: style),
        ),
      ),
    );
  }

  Widget _televisionView(BuildContext context) {
    final options = _televisionOptions;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _televisionKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: widget.controller,
            focusNode: _focus,
            autofocus: widget.autofocus,
            textInputAction: TextInputAction.search,
            onChanged: _changed,
            onSubmitted: _submit,
            decoration: InputDecoration(
              hintText: widget.hint,
              prefixIcon: const Icon(Icons.search_rounded),
            ),
          ),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 10),
            ..._televisionOptionTiles(context),
          ],
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _televisionAction(context, _clearFocus, '清空', _clear),
              const SizedBox(width: 10),
              _televisionAction(context, _submitFocus, '搜索', _submitField),
            ],
          ),
        ],
      ),
    );
  }

  Widget _autocompleteView(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => RawAutocomplete<String>(
      textEditingController: widget.controller,
      focusNode: _focus,
      optionsBuilder: _options,
      onSelected: (value) {
        _selected = true;
        _submit(value);
      },
      fieldViewBuilder: (context, controller, focus, submitted) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) => _confirmKey(event, controller, submitted),
        child: TextField(
          controller: controller,
          focusNode: focus,
          autofocus: widget.autofocus,
          textInputAction: TextInputAction.search,
          onChanged: _changed,
          onSubmitted: (value) => _confirm(value, submitted),
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (controller.text.isNotEmpty)
                  IconButton(
                    tooltip: '清空搜索',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: _clear,
                  ),
                IconButton(
                  tooltip: '搜索',
                  icon: const Icon(Icons.arrow_forward_rounded),
                  onPressed: () => _submit(controller.text),
                ),
              ],
            ),
          ),
        ),
      ),
      optionsViewBuilder: (context, selected, options) {
        final values = options.toList();
        final available =
            MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom;
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: constraints.maxWidth,
              height: min(
                min(300.0, max(96.0, available * .45)),
                values.length * 48.0,
              ),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemExtent: 48,
                itemCount: values.length,
                itemBuilder: (context, index) => ListTile(
                  key: ValueKey('search-suggestion-$index'),
                  selected: AutocompleteHighlightedOption.of(context) == index,
                  leading: const Icon(Icons.search, size: 18),
                  title: _highlight(values[index]),
                  onTap: () => selected(values[index]),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    _television = AppLayout.isTelevision(context);
    if (_television) return _televisionView(context);
    return _autocompleteView(context);
  }
}
