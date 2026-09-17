import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Left product rail. Navigation chrome only — does not own spatial state.
class AppRail extends StatelessWidget {
  const AppRail({
    super.key,
    required this.onOpen,
    required this.onOpenEq,
    required this.onExport,
    required this.onEnterIsland,
    required this.buildId,
    this.compact = false,
    this.native = false,
    this.backend = '',
  });

  final VoidCallback onOpen;
  final VoidCallback onOpenEq;
  final VoidCallback onExport;
  final VoidCallback onEnterIsland;
  final String buildId;
  final bool compact;
  final bool native;
  final String backend;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? YinweiLayout.railCompactWidth : YinweiLayout.railWidth,
      decoration: const BoxDecoration(
        color: YinweiColors.shellRail,
        border: Border(right: BorderSide(color: YinweiColors.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 10 : 18,
              16,
              compact ? 10 : 18,
              18,
            ),
            child: compact
                ? const Icon(
                    Icons.graphic_eq_rounded,
                    size: 20,
                    color: YinweiColors.textPrimary,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '音围',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontSize: 15,
                              letterSpacing: 0.2,
                            ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Yinwei',
                        style: TextStyle(
                          fontSize: 12,
                          color: YinweiColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
          ),
          _RailItem(
            icon: Icons.spatial_audio_rounded,
            label: 'Spatial',
            selected: true,
            compact: compact,
          ),
          _RailItem(
            icon: CupertinoIcons.folder,
            label: 'Open',
            compact: compact,
            onTap: onOpen,
          ),
          _RailItem(
            icon: Icons.graphic_eq_rounded,
            label: 'EQ',
            compact: compact,
            onTap: onOpenEq,
          ),
          _RailItem(
            icon: CupertinoIcons.square_arrow_down,
            label: 'Export',
            compact: compact,
            onTap: onExport,
          ),
          _RailItem(
            icon: Icons.crop_landscape_rounded,
            label: 'Island',
            compact: compact,
            onTap: onEnterIsland,
          ),
          const Spacer(),
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 8 : 16,
              8,
              compact ? 8 : 16,
              16,
            ),
            child: compact
                ? Column(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: native
                              ? YinweiColors.success
                              : YinweiColors.textSecondary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '音围 Yinwei',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: YinweiColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      const Text(
                        'Spatial Audio',
                        style: TextStyle(
                          fontSize: 11,
                          color: YinweiColors.textTertiary,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: native
                                  ? YinweiColors.success
                                  : YinweiColors.textSecondary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              backend.isEmpty ? buildId : backend,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                color: YinweiColors.textTertiary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        buildId,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: YinweiColors.accent,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.compact,
    this.selected = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool compact;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final child = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 12,
        vertical: 3,
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 0 : 10,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1C1C1F) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: compact
            ? Icon(
                icon,
                size: 18,
                color: selected
                    ? YinweiColors.textPrimary
                    : YinweiColors.textSecondary,
              )
            : Row(
                children: [
                  Icon(
                    icon,
                    size: 17,
                    color: selected
                        ? YinweiColors.textPrimary
                        : YinweiColors.textSecondary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected
                            ? YinweiColors.textPrimary
                            : YinweiColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );

    if (onTap == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    );
  }
}
