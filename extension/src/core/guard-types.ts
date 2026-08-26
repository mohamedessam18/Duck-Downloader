/** The view of Guard that UI surfaces need. Never carries the PIN hash. */
export interface GuardStatus {
  enabled: boolean;
  configured: boolean;
  cooldownHours: number;
  pendingUnlock: boolean;
  msUntilUnlock: number | null;
  blockMessage: string;
  customDomains: string[];
  safeSearch: boolean;
  feedFilter: boolean;
}
