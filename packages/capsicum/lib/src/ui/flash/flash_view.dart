import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../provider/preferences_provider.dart';
import '../widget/content_parser.dart';
import 'as_ui.dart';
import 'flash_runtime.dart';

/// [FlashRuntime] が保持するコンポーネントツリーを描画する (#830)。
///
/// children が id 参照なので、描画は「id → レジストリ引き → 再帰」で行う。
/// 循環参照（スクリプトが自分を子に入れる等）でも無限再帰しないよう、
/// 描画経路上の id を [_seen] で持ち回って打ち切る。
class FlashView extends StatefulWidget {
  const FlashView({super.key, required this.runtime});

  final FlashRuntime runtime;

  @override
  State<FlashView> createState() => _FlashViewState();
}

class _FlashViewState extends State<FlashView> {
  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(FlashView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_onChanged);
      widget.runtime.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in widget.runtime.rootChildren)
          _AsUiNode(runtime: widget.runtime, id: id, seen: const {}),
      ],
    );
  }
}

class _AsUiNode extends ConsumerWidget {
  const _AsUiNode({
    required this.runtime,
    required this.id,
    required this.seen,
  });

  final FlashRuntime runtime;
  final String id;
  final Set<String> seen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (seen.contains(id)) return const SizedBox.shrink();
    final component = runtime.component(id);
    if (component == null || component.hidden) return const SizedBox.shrink();

    final nextSeen = {...seen, id};
    switch (component.type) {
      case 'container':
        return _Container(
          runtime: runtime,
          component: component,
          seen: nextSeen,
        );
      case 'text':
        return _Text(component: component);
      case 'mfm':
        return _Mfm(runtime: runtime, component: component);
      case 'button':
        return _Button(runtime: runtime, component: component);
      case 'buttons':
        return _Buttons(runtime: runtime, component: component, seen: nextSeen);
      case 'postFormButton':
        return _PostFormButton(component: component);
      default:
        // FlashRuntime が束縛していない型はそもそも実行時に落ちるため、
        // ここへ来るのは想定外。黙って消さずに痕跡を残す。
        return _Unsupported(type: component.type);
    }
  }
}

/// `align` は本家の Align（left / center / right）。
CrossAxisAlignment _crossAxisAlignment(Object? align) => switch (align) {
  'center' => CrossAxisAlignment.center,
  'right' => CrossAxisAlignment.end,
  _ => CrossAxisAlignment.start,
};

Color? _parseColor(Object? value) {
  if (value is! String) return null;
  final hex = value.startsWith('#') ? value.substring(1) : value;
  final normalized = switch (hex.length) {
    3 => 'FF${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}',
    6 => 'FF$hex',
    8 => hex,
    _ => null,
  };
  if (normalized == null) return null;
  final parsed = int.tryParse(normalized, radix: 16);
  return parsed == null ? null : Color(parsed);
}

class _Container extends StatelessWidget {
  const _Container({
    required this.runtime,
    required this.component,
    required this.seen,
  });

  final FlashRuntime runtime;
  final AsUiComponent component;
  final Set<String> seen;

  @override
  Widget build(BuildContext context) {
    final props = component.props;
    final padding = (props['padding'] as num?)?.toDouble();
    final borderWidth = (props['borderWidth'] as num?)?.toDouble();
    final borderColor = _parseColor(props['borderColor']);
    final borderRadius = (props['borderRadius'] as num?)?.toDouble();
    final rounded = props['rounded'] == true;

    return Container(
      width: double.infinity,
      padding: padding == null ? null : EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: _parseColor(props['bgColor']),
        border: borderWidth != null && borderWidth > 0
            ? Border.all(
                width: borderWidth,
                color: borderColor ?? Theme.of(context).colorScheme.outline,
              )
            : null,
        borderRadius: BorderRadius.circular(borderRadius ?? (rounded ? 12 : 0)),
      ),
      child: Column(
        crossAxisAlignment: _crossAxisAlignment(props['align']),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final child in component.children)
            _AsUiNode(runtime: runtime, id: child, seen: seen),
        ],
      ),
    );
  }
}

class _Text extends StatelessWidget {
  const _Text({required this.component});

  final AsUiComponent component;

  @override
  Widget build(BuildContext context) {
    final text = component.text ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final size = (component.props['size'] as num?)?.toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontSize: size,
          fontWeight: component.props['bold'] == true ? FontWeight.bold : null,
          color: _parseColor(component.props['color']),
        ),
      ),
    );
  }
}

/// MFM テキスト。既存の [ContentRenderer] をそのまま使う。
///
/// Flash の主役はここで、実在の Play はほぼ全部 `Ui:C:mfm` で装飾テキストを
/// 出している。アニメーション MFM の ticker を持つため、[_TextBlockState] と
/// 同じく生成入力が変わったときだけ作り直して dispose する (#628 と同型)。
class _Mfm extends ConsumerStatefulWidget {
  const _Mfm({required this.runtime, required this.component});

  final FlashRuntime runtime;
  final AsUiComponent component;

  @override
  ConsumerState<_Mfm> createState() => _MfmState();
}

class _MfmState extends ConsumerState<_Mfm> {
  ContentRenderer? _renderer;
  TextStyle? _baseStyle;
  double? _emojiSize;
  bool? _animate;

  @override
  void dispose() {
    _renderer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.component.text ?? '';
    if (text.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final size = (widget.component.props['size'] as num?)?.toDouble();
    final baseStyle = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
          fontSize: size,
          fontWeight: widget.component.props['bold'] == true
              ? FontWeight.bold
              : null,
          color: _parseColor(widget.component.props['color']),
        );
    final emojiSize = ref.watch(emojiSizeProvider);
    final animate = ref.watch(mfmAnimationEnabledProvider);

    if (_renderer == null ||
        _baseStyle != baseStyle ||
        _emojiSize != emojiSize ||
        _animate != animate) {
      _renderer?.dispose();
      _renderer = ContentRenderer(
        baseStyle: baseStyle,
        resolveEmoji: (shortcode) =>
            'https://${widget.runtime.host}/emoji/$shortcode.webp',
        emojiSize: emojiSize,
        animateMfm: animate,
      );
      _baseStyle = baseStyle;
      _emojiSize = emojiSize;
      _animate = animate;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text.rich(_renderer!.renderMfm(text)),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.runtime, required this.component});

  final FlashRuntime runtime;
  final AsUiComponent component;

  @override
  Widget build(BuildContext context) {
    final props = component.props;
    final disabled = props['disabled'] == true;
    final onClick = props['onClick'];
    final label = Text(component.text ?? '');
    final onPressed = disabled || onClick == null
        ? null
        : () => runtime.invoke(onClick);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: props['primary'] == true
          ? FilledButton(onPressed: onPressed, child: label)
          : OutlinedButton(onPressed: onPressed, child: label),
    );
  }
}

class _Buttons extends StatelessWidget {
  const _Buttons({
    required this.runtime,
    required this.component,
    required this.seen,
  });

  final FlashRuntime runtime;
  final AsUiComponent component;
  final Set<String> seen;

  @override
  Widget build(BuildContext context) {
    // `buttons` は children と違い、id 参照ではなく button 定義の配列で来る。
    final raw = component.props['buttons'];
    if (raw is! List) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        for (final (index, button) in raw.indexed)
          if (button is Map<String, Object?>)
            _Button(
              runtime: runtime,
              component: AsUiComponent(
                id: '${component.id}:$index',
                type: 'button',
                props: button,
              ),
            ),
      ],
    );
  }
}

/// 押すと投稿フォームを開くボタン。実在の Play はほぼ全部これで
/// 「結果を投稿する」導線を出している。
class _PostFormButton extends StatelessWidget {
  const _PostFormButton({required this.component});

  final AsUiComponent component;

  @override
  Widget build(BuildContext context) {
    final form = component.props['form'];
    final text = form is Map<String, Object?> ? form['text'] as String? : null;
    final label = Text(component.text ?? '投稿する');

    void open() {
      // cw / visibility / localOnly は ComposeScreen が extra で受けないため
      // 現状は本文のみ引き渡す。必要になったら route 側を拡張する。
      context.push('/compose', extra: {'initialText': text ?? ''});
    }

    // 投稿導線は Play の主目的の出口なので、囲む container の align によらず
    // 常に中央に置く（意図的に本家の align 準拠から外している・#830）。root
    // 直下（Column が stretch）でも container 内（start / center）でも、Align
    // が幅いっぱいの帯を取ってボタンを中央へ寄せる。
    return Align(
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: component.props['primary'] == true
            ? FilledButton.icon(
                onPressed: open,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: label,
              )
            : OutlinedButton.icon(
                onPressed: open,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: label,
              ),
      ),
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported({required this.type});

  final String type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        'このパーツは未対応です ($type)',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}
