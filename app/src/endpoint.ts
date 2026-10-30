import type Anthropic from "@anthropic-ai/sdk";
import type { MessagesAPI } from "./agent";

type MessageParam = Anthropic.Beta.Messages.BetaMessageParam;
type Message = Anthropic.Beta.Messages.BetaMessage;

/** An error answer from an OpenAI-compatible endpoint (not retried, unlike a tool call that isn't valid JSON). */
export class EndpointError extends Error {}

type ChatMessage =
  | { role: "system" | "user"; content: string }
  | { role: "assistant"; content: string | null; tool_calls?: ToolCall[] }
  | { role: "tool"; tool_call_id: string; content: string };
type ToolCall = { id: string; type: "function"; function: { name: string; arguments: string } };

type Request = {
  model: string;
  max_tokens: number;
  system?: string;
  tools?: Array<{ name: string; description?: string; input_schema: unknown }>;
  messages: MessageParam[];
};

/** `/v1/<path>` under the endpoint's address, whether or not that already ends in /v1. */
export function endpointUrl(base: string, path: string): string {
  const root = base.replace(/\/+$/, "");
  return `${root}${root.endsWith("/v1") ? "" : "/v1"}/${path}`;
}

/** Servers without keys (a local vLLM, say) get no Authorization header. */
const auth = (apiKey: string): Record<string, string> => (apiKey ? { authorization: `Bearer ${apiKey}` } : {});

const blocks = (message: MessageParam) =>
  (typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content) as Array<Record<string, any>>;

const resultText = (content: unknown): string =>
  typeof content === "string" ? content
  : Array.isArray(content) ? content.map((b) => (b?.type === "text" ? b.text : "")).join("\n")
  : "";

/** The Messages-format conversation as chat completions messages. Thinking blocks are left out. */
export function toChatMessages(system: string | undefined, messages: readonly MessageParam[]): ChatMessage[] {
  const out: ChatMessage[] = system ? [{ role: "system", content: system }] : [];
  let calls = new Set<string>();
  for (const message of messages) {
    const parts = blocks(message);
    if (message.role === "assistant") {
      const text = parts.filter((b) => b.type === "text").map((b) => b.text).join("\n");
      const toolCalls: ToolCall[] = parts
        .filter((b) => b.type === "tool_use")
        .map((b) => ({ id: b.id, type: "function", function: { name: b.name, arguments: JSON.stringify(b.input ?? {}) } }));
      calls = new Set(toolCalls.map((c) => c.id));
      out.push({ role: "assistant", content: text || null, ...(toolCalls.length ? { tool_calls: toolCalls } : {}) });
      continue;
    }
    const texts: string[] = [];
    for (const b of parts) {
      if (b.type === "tool_result") {
        const content = (b.is_error ? "Error: " : "") + resultText(b.content);
        // A result must directly follow the call it answers; anything else goes in as plain text.
        if (calls.has(b.tool_use_id)) out.push({ role: "tool", tool_call_id: b.tool_use_id, content });
        else texts.push(content);
      } else if (b.type === "text") texts.push(b.text);
    }
    calls = new Set();
    if (texts.length) out.push({ role: "user", content: texts.join("\n\n") });
  }
  return out;
}

function toMessage(data: any, model: string): Message {
  const choice = data?.choices?.[0];
  if (!choice?.message) throw new EndpointError(`unexpected answer: ${JSON.stringify(data).slice(0, 200)}`);
  const content: Array<Record<string, unknown>> = [];
  if (typeof choice.message.content === "string" && choice.message.content.trim())
    content.push({ type: "text", text: choice.message.content, citations: null });
  for (const call of choice.message.tool_calls ?? []) {
    // Not an EndpointError: the agent asks again, as for a tool call that isn't valid JSON from Claude.
    const input = call.function?.arguments ? JSON.parse(call.function.arguments) : {};
    content.push({ type: "tool_use", id: call.id || `toolu_${crypto.randomUUID()}`, name: call.function?.name, input });
  }
  const stop_reason = choice.finish_reason === "length" ? "max_tokens" : content.some((b) => b.type === "tool_use") ? "tool_use" : "end_turn";
  return {
    id: data.id ?? `msg_${crypto.randomUUID()}`,
    type: "message",
    role: "assistant",
    model: data.model ?? model,
    content,
    stop_reason,
    stop_sequence: null,
    usage: { input_tokens: data.usage?.prompt_tokens ?? 0, output_tokens: data.usage?.completion_tokens ?? 0 },
  } as unknown as Message;
}

/**
 * The agent's Messages API over an OpenAI-compatible chat completions endpoint (e.g. a LiteLLM proxy).
 * Only the plain fields of a local-model request are used: thinking settings are left out.
 */
export function chatCompletionsAPI(options: { url: string; apiKey: string; timeout?: number }): MessagesAPI {
  const send = async (params: Request, signal?: AbortSignal): Promise<Message> => {
    const timeout = AbortSignal.timeout(options.timeout ?? 10 * 60 * 1000);
    const body = {
      model: params.model,
      max_tokens: params.max_tokens,
      messages: toChatMessages(params.system, params.messages),
      ...(params.tools?.length
        ? { tools: params.tools.map((t) => ({ type: "function", function: { name: t.name, description: t.description ?? "", parameters: t.input_schema } })) }
        : {}),
    };
    let response: Response;
    try {
      response = await fetch(endpointUrl(options.url, "chat/completions"), {
        method: "POST",
        headers: { "content-type": "application/json", ...auth(options.apiKey) },
        body: JSON.stringify(body),
        signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      });
    } catch (error) {
      if (signal?.aborted) throw error;
      throw new EndpointError(`can't reach ${options.url} (${error instanceof Error ? error.message : error})`);
    }
    if (!response.ok) {
      const detail = (await response.text().catch(() => "")).slice(0, 300);
      throw new EndpointError(
        response.status === 401 || response.status === 403 ? `the API key was rejected (${response.status}); check LLM_API_KEY in .env`
        : `the model server answered ${response.status}: ${detail}`,
      );
    }
    return toMessage(await response.json(), params.model);
  };
  const api = {
    beta: {
      messages: {
        stream: (params: Request, requestOptions?: { signal?: AbortSignal }) => {
          const message = send(params, requestOptions?.signal);
          message.catch(() => {}); // Handled by whoever awaits finalMessage().
          return { finalMessage: () => message };
        },
      },
    },
  };
  return api as unknown as MessagesAPI;
}

/** The model ids the endpoint serves (throws EndpointError when the key is rejected or it can't be reached). */
export async function listModels(url: string, apiKey: string): Promise<string[]> {
  let response: Response;
  try {
    response = await fetch(endpointUrl(url, "models"), { headers: auth(apiKey), signal: AbortSignal.timeout(20_000) });
  } catch (error) {
    throw new EndpointError(`can't reach ${url} (${error instanceof Error ? error.message : error})`);
  }
  if (response.status === 401 || response.status === 403) throw new EndpointError("the API key was rejected");
  if (!response.ok) throw new EndpointError(`the server answered ${response.status}`);
  const data = (await response.json()) as { data?: { id: string }[] };
  return data.data?.map((m) => m.id) ?? [];
}
