/**
 * PROTOTYPE — Pi extension for the Conn behavioral-parity spike.
 *
 * It connects outbound to a Conn-owned Unix-socket broker, exposes supported
 * Pi controls, registers one structured-question tool, and gates only a
 * uniquely named synthetic approval command.
 */

import type {
	ExtensionAPI,
	ExtensionContext,
	ToolCallEvent,
} from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { randomUUID } from "node:crypto";
import { connect, type Socket } from "node:net";

type Command = {
	id?: string;
	type?: string;
	message?: string;
	provider?: string;
	modelId?: string;
	level?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
	requestId?: string;
	answer?: string;
	decision?: "approve" | "deny";
};

type PendingAttention = {
	kind: "question" | "approval";
	resolve: (value: string) => void;
};

const brokerSocket = process.env.CONN_PI_BROKER_SOCKET;
const instanceId = randomUUID();

export default function connParityExtension(pi: ExtensionAPI) {
	let context: ExtensionContext | undefined;
	let socket: Socket | undefined;
	let reconnectTimer: NodeJS.Timeout | undefined;
	let shuttingDown = false;
	let buffer = "";
	let lastEvent = "extension_loaded";
	let activeToolCount = 0;
	const attention = new Map<string, PendingAttention>();

	const state = () => ({
		sessionId: context?.sessionManager.getSessionId() ?? null,
		sessionFile: context?.sessionManager.getSessionFile() ?? null,
		sessionName: context?.sessionManager.getSessionName() ?? null,
		cwd: context?.cwd ?? null,
		isIdle: context?.isIdle() ?? true,
		hasPendingMessages: context?.hasPendingMessages() ?? false,
		lastEvent,
		activeToolCount,
		model: context?.model
			? {
					provider: context.model.provider,
					id: context.model.id,
					name: context.model.name,
				}
			: null,
		thinkingLevel: pi.getThinkingLevel(),
		pendingAttentionCount: attention.size,
		pid: process.pid,
	});

	const send = (value: unknown) => {
		if (socket?.writable) socket.write(`${JSON.stringify(value)}\n`);
	};

	const respond = (
		command: Command,
		success: boolean,
		extra: Record<string, unknown> = {},
	) => {
		send({
			role: "bridge",
			type: "response",
			id: command.id ?? null,
			success,
			...extra,
			state: state(),
		});
	};

	const scheduleReconnect = () => {
		if (shuttingDown || reconnectTimer || !brokerSocket) return;
		reconnectTimer = setTimeout(() => {
			reconnectTimer = undefined;
			connectBroker();
		}, 200);
	};

	const connectBroker = () => {
		if (shuttingDown || !brokerSocket || socket) return;
		const candidate = connect(brokerSocket);
		socket = candidate;
		candidate.setEncoding("utf8");
		candidate.on("connect", () => {
			send({
				role: "bridge",
				type: "register",
				protocol: 1,
				pid: process.pid,
				instanceId,
				state: state(),
			});
		});
		candidate.on("data", (chunk) => {
			buffer += chunk;
			for (;;) {
				const newline = buffer.indexOf("\n");
				if (newline < 0) break;
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				if (!line.trim()) continue;
				void handle(JSON.parse(line) as Command);
			}
		});
		const disconnected = () => {
			if (socket === candidate) socket = undefined;
			candidate.destroy();
			scheduleReconnect();
		};
		candidate.on("error", disconnected);
		candidate.on("close", disconnected);
	};

	const requestAttention = (
		kind: "question" | "approval",
		prompt: string,
	): Promise<string> => {
		if (!socket?.writable) {
			return Promise.reject(new Error("Conn broker is unavailable"));
		}
		const id = `attention-${randomUUID()}`;
		return new Promise((resolve) => {
			attention.set(id, { kind, resolve });
			send({
				role: "bridge",
				type: "attention",
				pid: process.pid,
				request: {
					id,
					kind,
					prompt,
					choices: kind === "approval" ? ["approve", "deny"] : [],
				},
				state: state(),
			});
		});
	};

	const resolveAttention = (command: Command) => {
		const pending = command.requestId
			? attention.get(command.requestId)
			: undefined;
		if (!pending) throw new Error("attention request is not current");
		if (pending.kind === "question") {
			if (!command.answer) throw new Error("answer is required");
			pending.resolve(command.answer);
		} else {
			if (!["approve", "deny"].includes(command.decision ?? "")) {
				throw new Error("approve or deny is required");
			}
			pending.resolve(command.decision!);
		}
		attention.delete(command.requestId!);
		send({
			role: "bridge",
			type: "attention_resolved",
			pid: process.pid,
			requestId: command.requestId,
			state: state(),
		});
	};

	const handle = async (command: Command) => {
		try {
			switch (command.type) {
				case "registered":
					return;
				case "get_state":
					respond(command, true);
					return;
				case "list_models":
					respond(command, true, {
						models:
							context?.modelRegistry.getAll().map((model) => ({
								provider: model.provider,
								id: model.id,
								name: model.name,
								reasoning: model.reasoning,
							})) ?? [],
					});
					return;
				case "set_model": {
					const model = context?.modelRegistry.find(
						command.provider ?? "",
						command.modelId ?? "",
					);
					if (!model) throw new Error("model is not available");
					if (!(await pi.setModel(model))) throw new Error("model has no usable auth");
					respond(command, true);
					return;
				}
				case "set_thinking":
					if (!command.level) throw new Error("thinking level is required");
					pi.setThinkingLevel(command.level);
					respond(command, true);
					return;
				case "follow_up":
					if (!command.message) throw new Error("message is required");
					if (context?.isIdle() ?? true) {
						pi.sendUserMessage(command.message);
					} else {
						pi.sendUserMessage(command.message, { deliverAs: "followUp" });
					}
					respond(command, true);
					return;
				case "steer":
					if (!command.message) throw new Error("message is required");
					if (!context || context.isIdle()) throw new Error("session is idle");
					pi.sendUserMessage(command.message, { deliverAs: "steer" });
					respond(command, true);
					return;
				case "interrupt":
					if (!context || context.isIdle()) throw new Error("session is idle");
					context.abort();
					respond(command, true);
					return;
				case "answer":
				case "decide":
					resolveAttention(command);
					respond(command, true);
					return;
				default:
					throw new Error(`unsupported command: ${command.type ?? "<missing>"}`);
			}
		} catch (error) {
			respond(command, false, {
				error: error instanceof Error ? error.message : String(error),
			});
		}
	};

	const observe = (eventName: string) => (_event: unknown, ctx: ExtensionContext) => {
		context = ctx;
		lastEvent = eventName;
		send({
			role: "bridge",
			type: "event",
			pid: process.pid,
			event: eventName,
			state: state(),
		});
	};

	pi.registerTool({
		name: "conn_parity_question",
		label: "Ask through Conn",
		description:
			"Ask the user one structured question through Conn and return the answer.",
		promptSnippet: "Ask the user a question through Conn.",
		parameters: Type.Object({
			prompt: Type.String({ description: "The question to ask the user" }),
		}),
		async execute(_toolCallId, params) {
			const answer = await requestAttention("question", params.prompt);
			return {
				content: [{ type: "text", text: answer }],
				details: { answeredThroughConn: true },
			};
		},
	});

	pi.on("tool_call", async (event: ToolCallEvent) => {
		if (
			isToolCallEventType("bash", event) &&
			event.input.command.includes("conn-pi-parity-approval-marker")
		) {
			const decision = await requestAttention(
				"approval",
				"Allow the isolated Conn parity marker command?",
			);
			if (decision !== "approve") {
				return { block: true, reason: "Denied through Conn parity controller" };
			}
		}
	});

	pi.on("session_start", (event, ctx) => {
		context = ctx;
		lastEvent = `session_start:${event.reason}`;
		connectBroker();
	});
	pi.on("session_info_changed", observe("session_info_changed"));
	pi.on("agent_start", observe("agent_start"));
	pi.on("turn_start", observe("turn_start"));
	pi.on("turn_end", observe("turn_end"));
	pi.on("agent_end", observe("agent_end"));
	pi.on("agent_settled", observe("agent_settled"));
	pi.on("model_select", observe("model_select"));
	pi.on("thinking_level_select", observe("thinking_level_select"));
	pi.on("tool_execution_start", (_event, ctx) => {
		context = ctx;
		lastEvent = "tool_execution_start";
		activeToolCount += 1;
		send({
			role: "bridge",
			type: "event",
			pid: process.pid,
			event: lastEvent,
			state: state(),
		});
	});
	pi.on("tool_execution_end", (_event, ctx) => {
		context = ctx;
		lastEvent = "tool_execution_end";
		activeToolCount = Math.max(0, activeToolCount - 1);
		send({
			role: "bridge",
			type: "event",
			pid: process.pid,
			event: lastEvent,
			state: state(),
		});
	});
	pi.on("session_shutdown", (_event, ctx) => {
		context = ctx;
		lastEvent = "session_shutdown";
		shuttingDown = true;
		if (reconnectTimer) clearTimeout(reconnectTimer);
		send({
			role: "bridge",
			type: "event",
			pid: process.pid,
			event: lastEvent,
			state: state(),
		});
		for (const pending of attention.values()) {
			pending.resolve(
				pending.kind === "approval" ? "deny" : "Conn disconnected before answering",
			);
		}
		attention.clear();
		socket?.end();
		socket = undefined;
	});
}
