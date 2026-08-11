import 'package:flutter/material.dart';

import '../errors/user_error_message.dart';
import '../theme/app_theme.dart';
import 'app_button.dart';
import 'app_card.dart';

class AppErrorState extends StatelessWidget {
  const AppErrorState({
    super.key,
    this.message = userSafeUnexpectedErrorMessage,
    this.onRetry,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: AppCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.sentiment_dissatisfied_rounded,
                color: Theme.of(context).colorScheme.primary,
                size: 32,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(message, textAlign: TextAlign.center),
              if (onRetry != null) ...[
                const SizedBox(height: AppSpacing.md),
                AppButton(label: '再試一次', onPressed: onRetry),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
