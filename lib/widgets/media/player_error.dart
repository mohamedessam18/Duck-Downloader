import 'package:flutter/material.dart';

import 'media_colors.dart';

class PlayerError extends StatelessWidget {
  const PlayerError({
    super.key,
    required this.message,
    required this.onDelete,
    this.onDismiss,
    this.onRetry,
  });

  final String message;
  final VoidCallback onDelete;
  final VoidCallback? onDismiss;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: mediaGold.withValues(alpha: .18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, height: 1.5),
          ),
          const SizedBox(height: 18),
          if (onDismiss != null || onRetry != null)
            Row(
              children: [
                if (onDismiss != null) ...[
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white24),
                      ),
                      onPressed: onDismiss,
                      child: const Text('Dismiss'),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                if (onRetry != null)
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: mediaGold,
                        foregroundColor: const Color(0xFF151515),
                      ),
                      onPressed: onRetry,
                      child: const Text('Retry'),
                    ),
                  ),
              ],
            ),
          if (onDismiss != null || onRetry != null) const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: mediaGold,
              foregroundColor: const Color(0xFF151515),
            ),
            onPressed: onDelete,
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
