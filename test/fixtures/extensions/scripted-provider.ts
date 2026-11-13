import { createServer } from "node:http";

// Scripted local transport, not a live model. Alternates a tool call and final text.
export async function scriptedProvider() {
  let requests = 0;
  const server = createServer(async (request, response) => {
    for await (const _ of request) { /* consume request */ }
    requests += 1;
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    const tool = requests % 2 === 1;
    const chunk = (delta: unknown, finish: string | null = null) => response.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
    chunk(tool ? { role: "assistant", tool_calls: [{ index: 0, id: "fixture_call", type: "function", function: { name: "fixture_tool", arguments: "{}" } }] } : { role: "assistant", content: "done" });
    chunk({}, tool ? "tool_calls" : "stop"); response.end("data: [DONE]\n\n");
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  return { baseUrl: `http://127.0.0.1:${port}/v1`, requests: () => requests, close: () => new Promise<void>((resolve, reject) => { server.closeAllConnections(); server.close(error => error ? reject(error) : resolve()); }) };
}
