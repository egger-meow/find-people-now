# App legal links

The OTP login screen shows a short notice with tappable Terms and Privacy links. The account screen keeps Terms, Privacy, and account/data handling entries visible. The existing account deletion button and confirmation continue to perform deletion.

`app/lib/legal/legal_links.dart` is the only URL map. Until a public site exists, it links to the existing draft documents in this repository. Once reviewed documents are published, build with `--dart-define=LEGAL_BASE_URL=https://<production-domain>`; the app then opens `/terms`, `/privacy`, and `/account-deletion`. Publish all three paths before setting the base URL. The account deletion page should describe the in-app deletion route and data handling, using the same reviewed policy content.

The current policies are draft v0.2 with no publication date. No acceptance version or timestamp is recorded. Before formal release, review and publish the documents, assign immutable version identifiers, then add server-backed `accepted_terms_version`, `accepted_privacy_version`, and `accepted_at` fields (or an append-only acceptance table) with an authenticated RPC that records acceptance after the user can open the published versions. The OTP notice communicates the condition for continuing, but an OTP request or verification alone is not an auditable acceptance record.
