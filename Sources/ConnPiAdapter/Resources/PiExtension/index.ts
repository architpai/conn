import type {
	ExtensionAPI,
	ExtensionContext,
	MessageEndEvent,
	SessionStartEvent,
	ToolCallEvent,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { randomUUID } from "node:crypto";
import { watch, type FSWatcher } from "node:fs";
import { lstat, readFile, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { connect, type Socket } from "node:net";
import { dirname, join } from "node:path";

export const CONN_PI_EXTENSION_PROTOCOL = 1;
export const CONN_PI_EXTENSION_VERSION = "0.2.1";
export const CONN_PI_SUPPORTED_VERSION = "0.82.1";
export const CONN_PI_MAXIMUM_FRAME_BYTES = 64 * 1024;
export const CONN_PI_RECONNECT_LIMIT = 6;

export type OptionalFeatures = {
	questionsEnabled: boolean;
	approvalsEnabled: boolean;
};

export type RuntimeDescriptor = {
	protocolVersion: number;
	generation: string;
	socketPath: string;
	authenticationSecret: string;
	issuedAt: number;
	expiresAt: number;
	features: OptionalFeatures;
};

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
	timer: NodeJS.Timeout;
};

const runtimeDescriptorPath =
	process.env.CONN_PI_RUNTIME_DESCRIPTOR ??
	join(homedir(), "Library", "Application Support", "Conn", "pi-runtime", "runtime.json");
const applicationSupportPath = join(homedir(), "Library", "Application Support");
const instanceId = randomUUID();

export function reconnectDelay(
	attempt: number,
	randomValue: number,
): number {
	const base = Math.min(200 * 2 ** attempt, 2_000);
	const boundedRandom = Math.max(0, Math.min(1, randomValue));
	return Math.round(base * (0.75 + boundedRandom * 0.5));
}

export function parseRuntimeDescriptor(
	value: unknown,
	now = Date.now(),
): RuntimeDescriptor | undefined {
	if (!value || typeof value !== "object") return undefined;
	const candidate = value as Partial<RuntimeDescriptor>;
	if (
		candidate.protocolVersion !== CONN_PI_EXTENSION_PROTOCOL ||
		typeof candidate.generation !== "string" ||
		candidate.generation.length > 64 ||
		typeof candidate.socketPath !== "string" ||
		!candidate.socketPath.startsWith("/") ||
		Buffer.byteLength(candidate.socketPath) > 100 ||
		typeof candidate.authenticationSecret !== "string" ||
		candidate.authenticationSecret.length < 32 ||
		candidate.authenticationSecret.length > 512 ||
		typeof candidate.issuedAt !== "number" ||
		typeof candidate.expiresAt !== "number" ||
		candidate.issuedAt > now ||
		candidate.expiresAt <= now ||
		candidate.expiresAt - candidate.issuedAt > 300_000 ||
		!candidate.features ||
		typeof candidate.features.questionsEnabled !== "boolean" ||
		typeof candidate.features.approvalsEnabled !== "boolean"
	) {
		return undefined;
	}
	return candidate as RuntimeDescriptor;
}

export function approvalDisposition(
	approvalsEnabled: boolean,
	brokerWritable: boolean,
	toolName: string,
): "pass" | "ask" | "deny" {
	if (!approvalsEnabled || ["read", "ls", "find", "grep"].includes(toolName)) {
		return "pass";
	}
	return brokerWritable ? "ask" : "deny";
}

export function attentionMayRoute(
	kind: "question" | "approval",
	features: OptionalFeatures | undefined,
	brokerWritable: boolean,
): boolean {
	return brokerWritable &&
		(kind === "question"
			? features?.questionsEnabled === true
			: features?.approvalsEnabled === true);
}

export function parsePiPackageVersion(value: unknown): string | undefined {
	if (!value || typeof value !== "object") return undefined;
	const packageMetadata = value as { name?: unknown; version?: unknown };
	return packageMetadata.name === "@earendil-works/pi-coding-agent" &&
		typeof packageMetadata.version === "string"
		? packageMetadata.version
		: undefined;
}

async function runtimePiVersion(): Promise<string | undefined> {
	try {
		let cursor = dirname(await realpath(process.argv[1] ?? ""));
		for (let depth = 0; depth < 8; depth += 1) {
			try {
				const metadata = JSON.parse(
					await readFile(join(cursor, "package.json"), "utf8"),
				);
				const version = parsePiPackageVersion(metadata);
				if (version) return version;
			} catch {
				// Continue toward the package root.
			}
			const parent = dirname(cursor);
			if (parent === cursor) break;
			cursor = parent;
		}
	} catch {
		// An unqualified runtime remains inert.
	}
	return undefined;
}

async function loadRuntimeDescriptor(): Promise<RuntimeDescriptor | undefined> {
	try {
		const metadata = await lstat(runtimeDescriptorPath);
		if (
			!metadata.isFile() ||
			metadata.isSymbolicLink() ||
			metadata.uid !== process.getuid?.() ||
			(metadata.mode & 0o077) !== 0 ||
			metadata.size > CONN_PI_MAXIMUM_FRAME_BYTES
		) {
			return undefined;
		}
		const data = await readFile(runtimeDescriptorPath, "utf8");
		return parseRuntimeDescriptor(JSON.parse(data));
	} catch {
		return undefined;
	}
}

/**
 * Conn's external-Pi bridge. The factory deliberately performs no I/O,
 * starts no timer, and changes no Pi behavior. Runtime work begins only from
 * Pi's supported session lifecycle.
 */
export default function connPiExtension(pi: ExtensionAPI): void {
	let context: ExtensionContext | undefined;
	let socket: Socket | undefined;
	let watcher: FSWatcher | undefined;
	let reconnectTimer: NodeJS.Timeout | undefined;
	let descriptor: RuntimeDescriptor | undefined;
	let reconnectAttempt = 0;
	let shuttingDown = false;
	let buffer = "";
	let lastEvent = "extension_loaded";
	let activeToolCount = 0;
	let activitySequence = 0;
	let questionToolRegistered = false;
	let detectedPiVersion: string | undefined;
	let versionDetectionAttempted = false;
	const pendingAttention = new Map<string, PendingAttention>();

	const state = () => ({
		sessionId: context?.sessionManager.getSessionId() ?? null,
		sessionName: context?.sessionManager.getSessionName() ?? null,
		cwd: context?.cwd ?? null,
		isIdle: context?.isIdle() ?? true,
		hasPendingMessages: context?.hasPendingMessages() ?? false,
		lastEvent,
		activeToolCount,
		modelProvider: context?.model?.provider ?? null,
		modelId: context?.model?.id ?? null,
		modelName: context?.model?.name ?? null,
		thinking: pi.getThinkingLevel(),
	});

	const send = (value: unknown) => {
		if (!socket?.writable) return;
		const frame = `${JSON.stringify(value)}\n`;
		if (Buffer.byteLength(frame) <= CONN_PI_MAXIMUM_FRAME_BYTES) {
			socket.write(frame);
		}
	};

	const respond = (
		command: Command,
		success: boolean,
		extra: Record<string, unknown> = {},
	) => {
		send({
			type: "response",
			id: command.id ?? null,
			success,
			...extra,
			state: state(),
		});
	};

	const disconnect = (candidate?: Socket) => {
		if (candidate && socket !== candidate) return;
		const active = socket;
		socket = undefined;
		active?.destroy();
		for (const pending of pendingAttention.values()) {
			clearTimeout(pending.timer);
			pending.resolve(
				pending.kind === "approval"
					? "deny"
					: "Conn is unavailable for this question",
			);
		}
		pendingAttention.clear();
	};

	const requestAttention = (
		kind: "question" | "approval",
		request: Record<string, unknown>,
	): Promise<string> => {
		if (
			!attentionMayRoute(
				kind,
				descriptor?.features,
				socket?.writable === true,
			)
		) {
			return Promise.resolve(
				kind === "approval" ? "deny" : "Conn is unavailable for this question",
			);
		}
		const id = `attention-${randomUUID()}`;
		return new Promise((resolve) => {
			const timer = setTimeout(() => {
				pendingAttention.delete(id);
				resolve(
					kind === "approval"
						? "deny"
						: "Conn did not answer before the question expired",
				);
			}, 120_000);
			pendingAttention.set(id, { kind, resolve, timer });
			send({
				type: "attention",
				request: { id, kind, ...request },
				state: state(),
			});
		});
	};

	const resolveAttention = (command: Command) => {
		const pending = command.requestId
			? pendingAttention.get(command.requestId)
			: undefined;
		if (!pending) throw new Error("attention request is not current");
		let value: string;
		if (pending.kind === "question") {
			if (!command.answer) throw new Error("answer is required");
			value = command.answer;
		} else {
			if (!["approve", "deny"].includes(command.decision ?? "")) {
				throw new Error("approve or deny is required");
			}
			value = command.decision!;
		}
		clearTimeout(pending.timer);
		pendingAttention.delete(command.requestId!);
		pending.resolve(value);
		send({
			type: "attention_resolved",
			requestId: command.requestId,
			state: state(),
		});
	};

	const ensureQuestionTool = () => {
		if (questionToolRegistered || !descriptor?.features.questionsEnabled) return;
		questionToolRegistered = true;
		pi.registerTool({
			name: "conn_question",
			label: "Ask through Conn",
			description:
				"Ask the user one bounded, non-secret question through Conn.",
			parameters: Type.Object(
				{
					id: Type.String({ minLength: 1, maxLength: 128 }),
					header: Type.String({ minLength: 1, maxLength: 256 }),
					prompt: Type.String({ minLength: 1, maxLength: 2_048 }),
					choices: Type.Optional(
						Type.Array(Type.String({ minLength: 1, maxLength: 512 }), {
							maxItems: 8,
						}),
					),
					permitsOther: Type.Optional(Type.Boolean()),
				},
				{ additionalProperties: false },
			),
			async execute(_toolCallId, params) {
				const answer = await requestAttention("question", {
					questionId: params.id,
					header: params.header,
					prompt: params.prompt,
					choices: params.choices ?? [],
					permitsOther: params.permitsOther ?? false,
				});
				return {
					content: [{ type: "text", text: answer }],
					details: { answeredThroughConn: socket?.writable === true },
				};
			},
		});
	};

	const scheduleReconnect = () => {
		if (
			shuttingDown ||
			reconnectTimer ||
			reconnectAttempt >= CONN_PI_RECONNECT_LIMIT
		) {
			return;
		}
		const delay = reconnectDelay(reconnectAttempt, Math.random());
		reconnectAttempt += 1;
		reconnectTimer = setTimeout(() => {
			reconnectTimer = undefined;
			void connectBroker();
		}, delay);
	};

	const handle = async (command: Command) => {
		try {
			switch (command.type) {
				case "registered":
					return;
				case "get_state":
					respond(command, true);
					return;
				case "follow_up":
					if (!command.message) throw new Error("message is required");
					pi.sendUserMessage(command.message, { deliverAs: "followUp" });
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
				case "set_model": {
					const model = context?.modelRegistry.find(
						command.provider ?? "",
						command.modelId ?? "",
					);
					if (!model || !(await pi.setModel(model))) {
						throw new Error("model is not authenticated and available");
					}
					respond(command, true);
					return;
				}
				case "set_thinking":
					if (!command.level) throw new Error("thinking level is required");
					pi.setThinkingLevel(command.level);
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

	const connectBroker = async () => {
		if (shuttingDown || socket) return;
		if (!versionDetectionAttempted) {
			versionDetectionAttempted = true;
			detectedPiVersion = await runtimePiVersion();
		}
		if (detectedPiVersion !== CONN_PI_SUPPORTED_VERSION) return;
		descriptor = await loadRuntimeDescriptor();
		if (!descriptor) return;
		const currentDescriptor = descriptor;
		const candidate = connect(currentDescriptor.socketPath);
		socket = candidate;
		candidate.setEncoding("utf8");
		candidate.once("connect", () => {
			reconnectAttempt = 0;
			ensureQuestionTool();
			send({
				type: "register",
				protocol: CONN_PI_EXTENSION_PROTOCOL,
				generation: currentDescriptor.generation,
				secret: currentDescriptor.authenticationSecret,
				extensionVersion: CONN_PI_EXTENSION_VERSION,
				piVersion: detectedPiVersion,
				instanceId,
				pid: process.pid,
				sessionId: context?.sessionManager.getSessionId() ?? "",
				sessionName: context?.sessionManager.getSessionName() ?? null,
				reason: lastEvent.replace("session_start:", ""),
				cwd: context?.cwd ?? "",
				modelProvider: context?.model?.provider ?? "unknown",
				modelId: context?.model?.id ?? "unknown",
				thinking: pi.getThinkingLevel(),
				isIdle: context?.isIdle() ?? true,
			});
		});
		candidate.on("data", (chunk) => {
			buffer += chunk;
			if (Buffer.byteLength(buffer) > CONN_PI_MAXIMUM_FRAME_BYTES) {
				disconnect(candidate);
				return;
			}
			for (;;) {
				const newline = buffer.indexOf("\n");
				if (newline < 0) break;
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				if (!line.trim()) continue;
				try {
					void handle(JSON.parse(line) as Command);
				} catch {
					disconnect(candidate);
					return;
				}
			}
		});
		const disconnected = () => {
			if (socket !== candidate) return;
			disconnect(candidate);
			scheduleReconnect();
		};
		candidate.once("error", disconnected);
		candidate.once("close", disconnected);
	};

	const wakeForDescriptorChange = () => {
		if (shuttingDown) return;
		queueMicrotask(async () => {
			const next = await loadRuntimeDescriptor();
			if (!next) return;
			if (
				descriptor?.generation === next.generation &&
				descriptor.socketPath === next.socketPath &&
				socket?.writable
			) {
				descriptor = next;
				return;
			}
			if (reconnectTimer) clearTimeout(reconnectTimer);
			reconnectTimer = undefined;
			reconnectAttempt = 0;
			disconnect();
			await connectBroker();
		});
	};

	const startWatcher = () => {
		if (watcher) return;
		try {
			watcher = watch(
				applicationSupportPath,
				{ recursive: true, persistent: false },
				(_event, filename) => {
					if (
						filename?.toString().endsWith(
							join("Conn", "pi-runtime", "runtime.json"),
						)
					) {
						wakeForDescriptorChange();
					}
				},
			);
		} catch {
			// Conn absence is an inert state, not a Pi startup failure.
		}
	};

	const observe = (eventName: string) => (
		_event: unknown,
		ctx: ExtensionContext,
	) => {
		context = ctx;
		lastEvent = eventName;
		send({ type: "event", event: eventName, state: state() });
	};

	const messageText = (event: MessageEndEvent): string | undefined => {
		const message = event.message as {
			role?: string;
			content?: unknown;
		};
		if (!["user", "assistant"].includes(message.role ?? "")) return undefined;
		let text: string;
		if (typeof message.content === "string") {
			text = message.content;
		} else if (Array.isArray(message.content)) {
			text = message.content
				.filter(
					(item): item is { type: "text"; text: string } =>
						typeof item === "object" &&
						item !== null &&
						(item as { type?: unknown }).type === "text" &&
						typeof (item as { text?: unknown }).text === "string",
				)
				.map((item) => item.text)
				.join("\n");
		} else {
			return undefined;
		}
		if (!text) return undefined;
		return Buffer.from(text).subarray(0, 32 * 1024).toString("utf8");
	};

	pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
		context = ctx;
		shuttingDown = false;
		reconnectAttempt = 0;
		lastEvent = `session_start:${event.reason}`;
		startWatcher();
		queueMicrotask(() => void connectBroker());
	});
	pi.on("session_info_changed", observe("session_info_changed"));
	pi.on("agent_start", observe("agent_start"));
	pi.on("turn_start", observe("turn_start"));
	pi.on("turn_end", observe("turn_end"));
	pi.on("agent_end", observe("agent_end"));
	pi.on("agent_settled", observe("agent_settled"));
	pi.on("model_select", observe("model_select"));
	pi.on("thinking_level_select", observe("thinking_level_select"));
	pi.on("tool_call", async (event: ToolCallEvent) => {
		const toolName = String(event.toolName).slice(0, 512);
		const disposition = approvalDisposition(
			descriptor?.features.approvalsEnabled === true,
			socket?.writable === true,
			toolName,
		);
		if (disposition === "pass") return;
		if (disposition === "deny") {
			return {
				block: true,
				reason: "Conn approval mediation is enabled but unavailable",
			};
		}
		const decision = await requestAttention("approval", {
			prompt: `Allow Pi tool ${toolName}?`,
			choices: ["approve", "deny"],
			toolName,
		});
		if (decision !== "approve") {
			return { block: true, reason: "Denied through Conn approval mediation" };
		}
	});
	pi.on("message_end", (event, ctx) => {
		context = ctx;
		lastEvent = "message_end";
		const text = messageText(event);
		const role = (event.message as { role?: string }).role;
		send({
			type: "event",
			event: lastEvent,
			state: state(),
			activity: text
				? {
						id: `${instanceId}:${++activitySequence}`,
						kind: role === "user" ? "userMessage" : "agentMessage",
						text,
					}
				: undefined,
		});
	});
	pi.on("tool_execution_start", (event, ctx) => {
		context = ctx;
		activeToolCount += 1;
		lastEvent = "tool_execution_start";
		send({
			type: "event",
			event: lastEvent,
			state: state(),
			activity: {
				id: `${instanceId}:${++activitySequence}`,
				kind: "toolCall",
				text: String(event.toolName).slice(0, 512),
			},
		});
	});
	pi.on("tool_execution_end", (_event, ctx) => {
		context = ctx;
		activeToolCount = Math.max(0, activeToolCount - 1);
		lastEvent = "tool_execution_end";
		send({ type: "event", event: lastEvent, state: state() });
	});
	pi.on("session_shutdown", (_event, ctx) => {
		context = ctx;
		lastEvent = "session_shutdown";
		shuttingDown = true;
		if (reconnectTimer) clearTimeout(reconnectTimer);
		reconnectTimer = undefined;
		watcher?.close();
		watcher = undefined;
		send({ type: "event", event: lastEvent, state: state() });
		disconnect();
	});
}
