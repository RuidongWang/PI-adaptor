import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { HostError } from "../errors.js";
import type { AttachmentRecord, BlobStore } from "../media/blob-store.js";
import { messageText } from "../pi/session-catalog.js";
import { publicAssistantMessage } from "../providers/runtime.js";

/** Keep history responses well below the client's 1 MiB advertised receive budget. */
export const HISTORY_RESPONSE_MAX_BYTES = 512 * 1024;
export const HISTORY_TEXT_PREVIEW_BYTES = 8 * 1024;
export const HISTORY_TEXT_CHUNK_BYTES = 64 * 1024;
export const LIVE_EVENT_PAYLOAD_BYTES = 256 * 1024;
export const SNAPSHOT_QUEUE_TEXT_BYTES = 1024;
export const SNAPSHOT_ACTIVE_ITEMS_BYTES = 128 * 1024;
export const SNAPSHOT_HISTORY_LIMIT = 100;
export const HISTORY_PAGE_MAX_ITEMS = 200;

function imageExtension(mimeType: string): string {
  return mimeType === "image/png" ? "png" : mimeType === "image/webp" ? "webp" : "jpg";
}

export function textPreview(text: string, maxBytes: number): string {
  const prefix = Buffer.from(text.slice(0, maxBytes + 1), "utf8");
  if (prefix.length <= maxBytes) return text;
  let end = maxBytes;
  // If the cut is in the middle of a UTF-8 character, move back to its start.
  while ((prefix[end]! & 0xc0) === 0x80) end--;
  return prefix.subarray(0, end).toString("utf8") + "\n…";
}

export async function projectContent(
  sessionId: string,
  itemId: string,
  content: unknown,
  role: string,
  blobs: BlobStore
): Promise<{
  text: string;
  attachments: AttachmentRecord[];
  content: unknown;
}> {
  if (typeof content === "string") {
    return { text: content, attachments: [], content };
  }
  if (!Array.isArray(content)) {
    return { text: "", attachments: [], content };
  }
  const attachments: AttachmentRecord[] = [];
  const projected: unknown[] = [];
  for (const [index, part] of content.entries()) {
    const block = part as { type?: string; text?: string; data?: string; mimeType?: string };
    if (
      block.type === "image" &&
      typeof block.data === "string" &&
      typeof block.mimeType === "string"
    ) {
      try {
        const attachment = await blobs.importImageBase64({
          sessionId,
          dataBase64: block.data,
          mimeType: block.mimeType,
          fileName: `${itemId}-${index}.${imageExtension(block.mimeType)}`,
          kind: role === "user" ? "input" : "output"
        });
        attachments.push(attachment);
        projected.push({
          type: "image",
          attachmentId: attachment.id,
          mimeType: attachment.mimeType
        });
      } catch {
        projected.push(block);
      }
    } else {
      projected.push(block);
    }
  }
  return {
    text: messageText(projected),
    attachments,
    content: projected
  };
}

export async function itemFromEntry(
  entry: SessionEntry,
  sessionId: string,
  blobs: BlobStore
) {
  if (entry.type !== "message") return null;
  const message = (entry.message.role === "assistant" ? publicAssistantMessage(entry.message) : entry.message) as {
    role?: string;
    content?: unknown;
    toolName?: string;
    isError?: boolean;
    timestamp?: number;
  };
  const role = message.role ?? "assistant";
  const projected = await projectContent(sessionId, entry.id, message.content, role, blobs);
  const tool = role === "toolResult";
  return {
    id: entry.id,
    itemType: tool ? "tool" : "message",
    kind: tool ? "tool" : "message",
    role,
    text: projected.text,
    status: tool && message.isError ? "failed" : "completed",
    turnId: null,
    toolName: tool ? (message.toolName ?? null) : null,
    attachments: projected.attachments,
    content: { ...message, content: projected.content }
  };
}

export function historyItemPreview(
  item: NonNullable<Awaited<ReturnType<typeof itemFromEntry>>>
): Record<string, unknown> {
  const text = textPreview(item.text, HISTORY_TEXT_PREVIEW_BYTES);
  return {
    ...item,
    text,
    content: { role: item.role, timestamp: item.content.timestamp },
    ...(text !== item.text ? { textByteLength: Buffer.byteLength(item.text, "utf8") } : {})
  };
}

export async function historyPage(
  blobs: BlobStore,
  sessionId: string,
  entries: SessionEntry[],
  beforeItemId: string | undefined,
  limit: number,
  baseBytes: number
): Promise<{ items: Record<string, unknown>[]; hasMore: boolean }> {
  const messages = entries.filter((entry) => entry.type === "message");
  let end = messages.length;
  if (beforeItemId !== undefined) {
    end = messages.findIndex((entry) => entry.id === beforeItemId);
    if (end < 0) {
      throw new HostError("NOT_FOUND", "history item no longer exists", { field: "beforeItemId" });
    }
  }
  if (baseBytes > HISTORY_RESPONSE_MAX_BYTES) {
    throw new HostError("PAYLOAD_TOO_LARGE", "session snapshot state exceeds the response budget", {
      maxBytes: HISTORY_RESPONSE_MAX_BYTES
    });
  }
  const items: Record<string, unknown>[] = [];
  let bytes = baseBytes;
  let start = end;
  while (start > 0 && items.length < limit) {
    const projected = await itemFromEntry(messages[start - 1]!, sessionId, blobs);
    if (!projected) break;
    let item: Record<string, unknown> = projected;
    let itemBytes = Buffer.byteLength(JSON.stringify(item), "utf8") + (items.length > 0 ? 1 : 0);
    if (bytes + itemBytes > HISTORY_RESPONSE_MAX_BYTES && items.length === 0) {
      item = historyItemPreview(projected);
      itemBytes = Buffer.byteLength(JSON.stringify(item), "utf8");
    }
    if (bytes + itemBytes > HISTORY_RESPONSE_MAX_BYTES) {
      if (items.length === 0) {
        throw new HostError("PAYLOAD_TOO_LARGE", "history item exceeds the response budget", {
          field: "items",
          maxBytes: HISTORY_RESPONSE_MAX_BYTES
        });
      }
      break;
    }
    items.push(item);
    bytes += itemBytes;
    start -= 1;
  }
  items.reverse();
  return { items, hasMore: start > 0 };
}
