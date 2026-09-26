import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

enum LegalDocument { terms, privacy, accountDeletion }

/// Set at build time once the public site publishes the reviewed documents.
/// Until then, the existing repository documents are the single source of text.
class LegalLinks {
  static const _baseUrl = String.fromEnvironment('LEGAL_BASE_URL');
  static const _draftBase =
      'https://github.com/egger-meow/find-people-now/blob/main/docs';

  static Uri uri(LegalDocument document) {
    if (_baseUrl.isNotEmpty) {
      final path = switch (document) {
        LegalDocument.terms => '/terms',
        LegalDocument.privacy => '/privacy',
        LegalDocument.accountDeletion => '/account-deletion',
      };
      return Uri.parse('${_baseUrl.replaceFirst(RegExp(r'/$'), '')}$path');
    }
    return Uri.parse(switch (document) {
      LegalDocument.terms => '$_draftBase/TERMS_OF_SERVICE.md',
      LegalDocument.privacy => '$_draftBase/PRIVACY_POLICY.md',
      LegalDocument.accountDeletion => '$_draftBase/PRIVACY_POLICY.md#五你的權利',
    });
  }

  static Future<void> open(BuildContext context, LegalDocument document) async {
    if (!await launchUrl(uri(document), mode: LaunchMode.externalApplication) &&
        context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('無法開啟文件，請稍後再試')));
    }
  }
}
