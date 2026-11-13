export type ExtensionCompatibility = "unknown" | "headless-reviewed" | "requires-ui";
export type ExtensionsConfig = { enabled: boolean; entries: ExtensionConfigEntry[] };
export type ExtensionConfigEntry = { id: string; entryPath: string; name: string; enabled: boolean; version: string | null; compatibility: ExtensionCompatibility };
export type ExtensionDiagnostic = { stage: "validation" | "load" | "startup" | "runtime" | "cleanup"; severity: "warning" | "error"; code: string; message: string; occurredAt: string };
export type InventoryEntry = { id: string; name: string; configuredVersion: string | null; entryPath: string; enabled: boolean; compatibility: ExtensionCompatibility; entryState: "valid" | "missing" | "unreadable" | "duplicate"; diagnostics: ExtensionDiagnostic[] };
export type RuntimeEntry = { id: string; name: string; configuredVersion: string | null; loadState: "loaded" | "failed" | "skipped"; skipReason: "host-disabled" | "entry-disabled" | "not-adapted" | null; registeredTools: string[]; activeTools: string[]; registeredCommands: string[]; mobileInvocable: false; diagnostics: ExtensionDiagnostic[] };
export type ExtensionSnapshot = { id: string; hostId: string; sessionId: string; turnId: string; configRevision: string; revision: number; startedAt: string; completedAt: string | null; phase: "loading" | "ready" | "failed"; entries: RuntimeEntry[]; diagnostics: ExtensionDiagnostic[] };
export type SnapshotPair = { latestAttempt: ExtensionSnapshot | null; previousCompleted: ExtensionSnapshot | null };

// Error text from extension code is untrusted and may contain credentials or stacks.
// Only host-authored diagnostic messages cross the wire or go to storage/logs.
export function diagnostic(stage: ExtensionDiagnostic["stage"], code: string, message: string, severity: ExtensionDiagnostic["severity"] = "error"): ExtensionDiagnostic {
  return { stage, severity, code, message: message.slice(0, 1024), occurredAt: new Date().toISOString() };
}
export function addDiagnostic(target: ExtensionDiagnostic[], value: ExtensionDiagnostic): boolean {
  if (target.some(item => item.stage === value.stage && item.code === value.code && item.message === value.message)) return false;
  if (target.length >= 20) {
    target[19] = diagnostic(value.stage, "DIAGNOSTICS_TRUNCATED", "Additional diagnostics were omitted.", "warning");
    return false;
  }
  target.push(value); return true;
}
export function boundSnapshot(input: ExtensionSnapshot): ExtensionSnapshot {
  const snapshot = structuredClone(input);
  let truncated = false;
  for (const entry of snapshot.entries) {
    for (const field of ["registeredTools", "activeTools", "registeredCommands"] as const) {
      const source = entry[field];
      truncated ||= source.length > 200 || source.some(name => name.length > 256);
      entry[field] = [...new Set(source.map(name => name.slice(0, 256)))].slice(0, 200);
    }
    if (entry.diagnostics.length > 20) truncated = true;
    entry.diagnostics = entry.diagnostics.slice(0, 20).map(item => ({ ...item, message: item.message.slice(0, 1024) }));
  }
  snapshot.diagnostics = snapshot.diagnostics.slice(0, 20).map(item => ({ ...item, message: item.message.slice(0, 1024) }));
  // Include the sidecar envelope indentation used by the atomic JSON writer.
  const size = () => Buffer.byteLength(JSON.stringify({ snapshot }, null, 2), "utf8");
  // Preserve configured identities/statuses; discard verbose lists before entries.
  if (size() > 250 * 1024) {
    truncated = true;
    for (const entry of snapshot.entries) { entry.registeredTools = []; entry.activeTools = []; entry.registeredCommands = []; entry.diagnostics = entry.diagnostics.slice(0, 1); }
  }
  while (size() > 250 * 1024 && snapshot.entries.length) { snapshot.entries.pop(); truncated = true; }
  if (truncated) {
    snapshot.diagnostics = snapshot.diagnostics.slice(0, 19);
    addDiagnostic(snapshot.diagnostics, diagnostic("runtime", "SNAPSHOT_TRUNCATED", "Snapshot exceeded its display budget; some details were omitted.", "warning"));
  }
  return snapshot;
}
