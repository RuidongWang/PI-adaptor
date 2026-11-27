import { parentPort, workerData } from "node:worker_threads";
import { moduleWorker } from "../util/module-worker.js";
import { PiAgentDriver, type AgentDriver, type AgentEvent, type AgentTurnRequest } from "./driver.js";
import type { ExtensionSnapshot } from "../extensions/types.js";

type Call =
  { method: "approve"; name: string; input: unknown } | { method: "prepare" } |
  { method: "publish"; snapshot: ExtensionSnapshot } | { method: "readOnly"; reason: string };
type Message = (Call & { id: number }) | { method: "event"; event: AgentEvent } | { method: "done" };
type Input = { agentDir: string; request: Omit<AgentTurnRequest, "onEvent" | "onSessionReadOnly" | "extensions" | "requestApproval">; extensionIdentity?: { hostId: string; configRevision: string } };

export class WorkerAgentDriver implements AgentDriver {
  readonly appendsPrompt = true;
  constructor(private readonly agentDir: string) {}

  start(request: AgentTurnRequest) {
    const { onEvent, onSessionReadOnly, extensions, requestApproval, ...data } = request;
    const input: Input = { agentDir: this.agentDir, request: data, ...(extensions ? { extensionIdentity: {
      hostId: extensions.hostId, configRevision: extensions.registry.configRevision
    } } : {}) };
    const worker = moduleWorker(import.meta.url, input);
    let done = false;
    const wait = new Promise<void>((resolve, reject) => {
      worker.on("error", reject);
      worker.on("exit", () => done ? resolve() : reject(new Error("Agent worker stopped before completion")));
      worker.on("message", async (message: Message) => {
        if (message.method === "done") { done = true; void worker.terminate(); return; }
        if (message.method === "event") { onEvent(message.event); return; }
        try {
          const result = message.method === "approve" ? await requestApproval?.(message.name, message.input) === true
            : message.method === "prepare" ? await extensions!.registry.prepare()
            : message.method === "publish" ? await extensions!.publish(message.snapshot)
            : await onSessionReadOnly?.(message.reason);
          worker.postMessage({ id: message.id, result });
        } catch { worker.postMessage({ id: message.id, failed: true }); }
      });
    });
    return { turnId: request.turnId, wait: () => wait, abort: async () => { worker.postMessage({ abort: true }); await wait; } };
  }
}

if (parentPort && workerData?.request && workerData?.agentDir) {
  const port = parentPort;
  const input = workerData as Input;
  let sequence = 0;
  const pending = new Map<number, (reply: { result?: unknown; failed?: boolean }) => void>();
  function call<Result>(message: Call): Promise<Result> {
    const id = ++sequence;
    return new Promise((resolve, reject) => {
      pending.set(id, reply => reply.failed ? reject(new Error("Host callback failed")) : resolve(reply.result as Result));
      port.postMessage({ id, ...message });
    });
  }
  const handle = new PiAgentDriver(input.agentDir).start({ ...input.request,
    onEvent: event => port.postMessage({ method: "event", event }),
    onSessionReadOnly: reason => call({ method: "readOnly", reason }),
    requestApproval: (name, args) => call({ method: "approve", name, input: args }),
    ...(input.extensionIdentity ? { extensions: { hostId: input.extensionIdentity.hostId,
      registry: { configRevision: input.extensionIdentity.configRevision, prepare: () => call({ method: "prepare" }) },
      publish: snapshot => call({ method: "publish", snapshot }) } } : {})
  });
  port.on("message", reply => {
    if (reply.abort) { void handle.abort(); return; }
    pending.get(reply.id)?.(reply);
    pending.delete(reply.id);
  });
  await handle.wait();
  port.postMessage({ method: "done" });
  port.close();
}
