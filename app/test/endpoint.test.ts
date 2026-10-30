import { test, expect } from "bun:test";
import { chatCompletionsAPI, EndpointError, toChatMessages } from "../src/endpoint";

test("the conversation becomes chat messages, tool results right after their calls", () => {
  const out = toChatMessages("system", [
    { role: "user", content: [{ type: "text", text: "hi" }] },
    {
      role: "assistant",
      content: [
        { type: "thinking", thinking: "hmm", signature: "" },
        { type: "text", text: "On it." },
        { type: "tool_use", id: "t1", name: "observe", input: {} },
      ],
    },
    {
      role: "user",
      content: [
        { type: "tool_result", tool_use_id: "t1", content: "{}", is_error: true },
        { type: "text", text: "[New message] stop" },
      ],
    },
  ] as any);
  expect(out).toEqual([
    { role: "system", content: "system" },
    { role: "user", content: "hi" },
    { role: "assistant", content: "On it.", tool_calls: [{ id: "t1", type: "function", function: { name: "observe", arguments: "{}" } }] },
    { role: "tool", tool_call_id: "t1", content: "Error: {}" },
    { role: "user", content: "[New message] stop" },
  ]);
});

test("a chat completions answer becomes a Messages answer", async () => {
  let seen: any;
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      seen = { auth: request.headers.get("authorization"), path: new URL(request.url).pathname, body: await request.json() };
      if (seen.auth !== "Bearer key") return new Response("no", { status: 401 });
      return Response.json({
        id: "c1",
        model: "test-model",
        choices: [{ finish_reason: "tool_calls", message: { content: null, tool_calls: [{ id: "x", type: "function", function: { name: "give", arguments: '{"item":"coal","count":5}' } }] } }],
        usage: { prompt_tokens: 10, completion_tokens: 3 },
      });
    },
  });
  try {
    const url = `http://localhost:${server.port}/proxy`;
    const request = {
      model: "test-model",
      max_tokens: 100,
      system: "s",
      tools: [{ name: "give", description: "d", input_schema: { type: "object" } }],
      messages: [{ role: "user", content: "give me coal" }],
    } as any;
    const message = await chatCompletionsAPI({ url, apiKey: "key" }).beta.messages.stream(request).finalMessage();
    expect(seen.path).toBe("/proxy/v1/chat/completions");
    expect(seen.body.tools[0]).toEqual({ type: "function", function: { name: "give", description: "d", parameters: { type: "object" } } });
    expect(message.stop_reason).toBe("tool_use");
    expect(message.content).toEqual([{ type: "tool_use", id: "x", name: "give", input: { item: "coal", count: 5 } }] as any);
    expect(message.usage.output_tokens).toBe(3);
    const rejected = chatCompletionsAPI({ url, apiKey: "wrong" }).beta.messages.stream(request).finalMessage();
    await expect(rejected).rejects.toBeInstanceOf(EndpointError);
  } finally {
    server.stop(true);
  }
});
