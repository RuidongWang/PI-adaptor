import { readdir, rm } from "node:fs/promises";

/**
 * Remove a legacy provider-secret directory left by older builds.
 *
 * Host no longer persists provider API keys (transient per-turn instead), so
 * startup migrates old installations by deleting the whole directory. Only the
 * number of removed entries is reported: names and contents must never reach a
 * log, response or error body.
 */
export async function purgeSecretDirectory(directory: string): Promise<number> {
  let entries: string[];
  try {
    entries = await readdir(directory);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return 0;
    throw error;
  }
  await rm(directory, { recursive: true, force: true });
  return entries.length;
}
