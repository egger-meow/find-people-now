// =============================================================================
// EmailSender — the only thing index.ts depends on for actually delivering an
// email. This file is the stable part of the abstraction: it should NOT be
// deleted or modified when swapping providers, only implemented by a new
// sender file (see smtp_round_robin_sender.ts for the current, temporary
// implementation).
// =============================================================================

export interface EmailMessage {
  to: string;
  subject: string;
  html: string;
}

export interface EmailSender {
  send(message: EmailMessage): Promise<void>;
}
