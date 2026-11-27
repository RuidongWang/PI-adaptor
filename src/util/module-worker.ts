import { Worker } from "node:worker_threads";

export function moduleWorker(moduleURL: string, workerData: unknown): Worker {
  const entry = moduleURL.endsWith(".ts") ? new URL(`data:text/javascript,${encodeURIComponent(
    `import { register } from ${JSON.stringify(import.meta.resolve("tsx/esm/api"))}; register(); await import(${JSON.stringify(moduleURL)});`
  )}`) : new URL(moduleURL);
  return new Worker(entry, { workerData, execArgv: [] });
}
