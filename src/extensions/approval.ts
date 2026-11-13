import type { ExtensionFactory, InlineExtension } from "@earendil-works/pi-coding-agent";

export const HOST_APPROVAL_PATH = "<inline:host-approval>";
export function hostApprovalExtension(approve: ((name: string, input: unknown) => Promise<boolean>) | undefined, started: () => void): InlineExtension {
  const factory: ExtensionFactory = pi => {
    pi.on("session_start", () => { started(); });
    pi.on("tool_call", async event => {
      try {
        if (await approve?.(event.toolName, event.input) === true) return;
      } catch { /* Approval service failures deny execution. */ }
      return { block: true, reason: "Tool call denied by host approval policy" };
    });
  };
  return { name: "host-approval", hidden: true, factory };
}
