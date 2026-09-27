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
    this.retryLabel = '再試一次',
  });

  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: AppCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '出了點問題',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              Image.asset(
                'assets/mascot/error_06.png',
                height: 88,
                fit: BoxFit.contain,
                semanticLabel: '眼冒金星的街街貓',
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(message, textAlign: TextAlign.center),
              if (onRetry != null) ...[
                const SizedBox(height: AppSpacing.md),
                AppButton(label: retryLabel, onPressed: onRetry),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
