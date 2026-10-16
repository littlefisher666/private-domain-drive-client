import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../app/theme/cupertino_desktop.dart';
import '../../domain/file_item.dart';

/// 重命名编辑框按 (path, isAlias) 匹配条目；链接与真实条目可能共用路径。
bool isRenamingTarget(({String path, bool isAlias})? target, FileItem item) =>
    target != null && target.path == item.path && target.isAlias == item.isAlias;

/// 行内重命名编辑框：提交回调返回是否成功，失败时保持编辑状态。
class InlineRenameField extends StatefulWidget {
  const InlineRenameField({
    super.key,
    required this.item,
    required this.onSubmit,
    required this.onCancel,
  });

  final FileItem item;
  final Future<bool> Function(FileItem item, String name) onSubmit;
  final VoidCallback onCancel;

  @override
  State<InlineRenameField> createState() => _InlineRenameFieldState();
}

class _InlineRenameFieldState extends State<InlineRenameField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.item.name);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    _submitting = true;
    final succeeded = await widget.onSubmit(widget.item, _controller.text);
    if (!mounted || succeeded) return;
    setState(() => _submitting = false);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onCancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        enabled: !_submitting,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        onTapOutside: (_) => _submit(),
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: CupertinoDesktopTokens.blue),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: CupertinoDesktopTokens.blue),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(
              color: CupertinoDesktopTokens.blue,
              width: 1.5,
            ),
          ),
        ),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }
}
