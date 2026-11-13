import { chmod, mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";

export async function readJsonFile<T>(path: string, fallback: T): Promise<T> {
  try {
    const raw = await readFile(path, "utf8");
    return JSON.parse(raw) as T;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return fallback;
    throw error;
  }
}

export async function writeJsonFileAtomic(
  path: string,
  value: unknown,
  mode = 0o600
): Promise<void> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temp = join(dirname(path), `.${randomUUID()}.tmp`);
  let renamed = false;
  try {
    const handle = await open(temp, "wx", mode);
    try {
      await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    await chmod(temp, mode);
    await rename(temp, path);
    renamed = true;
  } finally {
    if (!renamed) {
      // A failed write must not leave a temp file that may contain metadata.
      await rm(temp, { force: true }).catch(() => undefined);
    }
  }
  // The rename committed the new value. A directory-sync failure after this
  // point means durability is uncertain, not that the write failed outright;
  // surface that distinct state to the caller.
  const dir = await open(dirname(path), "r");
  try {
    await dir.sync();
  } catch (error) {
    throw new JsonCommitUncertainError(path, error);
  } finally {
    await dir.close();
  }
}

/** The new file is in place, but its directory entry may not be durable. */
export class JsonCommitUncertainError extends Error {
  constructor(readonly path: string, readonly cause: unknown) {
    super(`json write committed but directory sync failed: ${path}`);
    this.name = "JsonCommitUncertainError";
  }
}

export async function removeFileIfExists(path: string): Promise<void> {
  try {
    await rm(path, { force: true });
  } catch {
    // Cleanup is best-effort; callers surface the operation result separately.
  }
}
