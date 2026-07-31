import type {
	ExtensionAPI,
	ExtensionContext,
	MessageStartEvent,
	SessionStartEvent,
	TurnEndEvent,
} from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { watch, type FSWatcher } from "node:fs";
import { lstat, readFile, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { connect, type Socket } from "node:net";
import { dirname, join } from "node:path";

export const CONN_PI_EXTENSION_PROTOCOL = 1;
export const CONN_PI_EXTENSION_VERSION = "0.2.1";
export const CONN_PI_SUPPORTED_VERSION = "0.83.0";
export const CONN_PI_MAXIMUM_FRAME_BYTES = 64 * 1024;
export const CONN_PI_RECONNECT_LIMIT = 6;

export type RuntimeDescriptor = {
	protocolVersion: number;
	generation: string;
	socketPath: string;
	authenticationSecret: string;
	issuedAt: number;
	expiresAt: number;
};

type Command = {
	id?: string;
	type?: string;
	message?: string;
	provider?: string;
	modelId?: string;
	level?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
};

export type RunOutcome = "completed" | "interrupted" | "failed" | "unknown";

export type RegistrationActivity = {
	id: string;
	kind: "userMessage" | "agentMessage" | "toolCall";
	text: string;
};

type ModelProjectionSource = {
	provider: string;
	id: string;
	name: string;
	reasoning: boolean;
	thinkingLevelMap?: Partial<
		Record<"off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max", string | null>
	>;
};

export type AvailableModelProjection = {
	provider: string;
	id: string;
	name: string;
	thinkingLevels: string[];
};

const thinkingLevels = [
	"off",
	"minimal",
	"low",
	"medium",
	"high",
	"xhigh",
	"max",
] as const;

export function projectAvailableModels(
	scopedModels: readonly { model: ModelProjectionSource }[],
	availableModels: readonly ModelProjectionSource[],
	currentModel?: ModelProjectionSource,
): AvailableModelProjection[] {
	const configured = scopedModels.length > 0
		? scopedModels.map(({ model }) => model)
		: availableModels;
	const candidates = currentModel
		? [currentModel, ...configured]
		: configured;
	const seen = new Set<string>();
	const projected: AvailableModelProjection[] = [];
	let projectedBytes = 0;
	for (const model of candidates) {
		if (
			![model.provider, model.id, model.name].every(
				(value) =>
					value.length > 0 &&
					!value.includes("\n") &&
					Buffer.byteLength(value) <= 512,
			)
		) {
			continue;
		}
		const key = `${model.provider}\u001f${model.id}`;
		if (seen.has(key)) continue;
		seen.add(key);
		const supported = model.reasoning
			? thinkingLevels.filter((level) => {
				const mapped = model.thinkingLevelMap?.[level];
				if (mapped === null) return false;
				return level !== "xhigh" && level !== "max" || mapped !== undefined;
			})
			: ["off"];
		const option = {
			provider: model.provider,
			id: model.id,
			name: model.name,
			thinkingLevels: [...supported],
		};
		const optionBytes = Buffer.byteLength(JSON.stringify(option));
		if (projectedBytes + optionBytes > 24 * 1024) break;
		projected.push(option);
		projectedBytes += optionBytes;
		if (projected.length >= 100) break;
	}
	return projected;
}

export function runOutcomeFromMessages(messages: readonly unknown[]): RunOutcome {
	const assistant = [...messages].reverse().find(
		(message) =>
			typeof message === "object" &&
			message !== null &&
			(message as { role?: unknown }).role === "assistant",
	) as { stopReason?: unknown } | undefined;
	switch (assistant?.stopReason) {
		case "stop":
			return "completed";
		case "aborted":
			return "interrupted";
		case "error":
		case "length":
			return "failed";
		default:
			return "unknown";
	}
}

export function registrationSnapshotFromEntries(
	entries: readonly unknown[],
): { outcome: RunOutcome | undefined; activities: RegistrationActivity[] } {
	const projected: RegistrationActivity[] = [];
	const messages: unknown[] = [];
	for (const entryValue of entries) {
		if (!entryValue || typeof entryValue !== "object") continue;
		const entry = entryValue as { type?: unknown; id?: unknown; message?: unknown };
		if (
			entry.type !== "message" ||
			typeof entry.id !== "string" ||
			!entry.message ||
			typeof entry.message !== "object"
		) {
			continue;
		}
		const message = entry.message as { role?: unknown; content?: unknown };
		messages.push(message);
		if (message.role !== "user" && message.role !== "assistant") continue;
		const kind = message.role === "user" ? "userMessage" : "agentMessage";
		const content = typeof message.content === "string"
			? [{ type: "text", text: message.content }]
			: Array.isArray(message.content) ? message.content : [];
		for (const [index, itemValue] of content.entries()) {
			if (!itemValue || typeof itemValue !== "object") continue;
			const item = itemValue as { type?: unknown; text?: unknown; name?: unknown };
			if (item.type === "text" && typeof item.text === "string" && item.text) {
				projected.push({
					id: `${entry.id}:text:${index}`,
					kind,
					text: Buffer.from(item.text).subarray(0, 32 * 1024).toString("utf8"),
				});
			} else if (
				message.role === "assistant" &&
				item.type === "toolCall" &&
				typeof item.name === "string" &&
				item.name
			) {
				projected.push({
					id: `${entry.id}:tool:${index}`,
					kind: "toolCall",
					text: Buffer.from(item.name).subarray(0, 512).toString("utf8"),
				});
			}
		}
	}

	const activities: RegistrationActivity[] = [];
	let byteCount = 0;
	for (const activity of projected.slice(-200).reverse()) {
		const size = Buffer.byteLength(JSON.stringify(activity));
		if (byteCount + size > 40 * 1024) break;
		activities.unshift(activity);
		byteCount += size;
	}
	return {
		outcome: messages.some(
			(message) =>
				typeof message === "object" &&
				message !== null &&
				(message as { role?: unknown }).role === "assistant",
		)
			? runOutcomeFromMessages(messages)
			: undefined,
		activities,
	};
}

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
		candidate.expiresAt - candidate.issuedAt > 300_000
	) {
		return undefined;
	}
	return candidate as RuntimeDescriptor;
}

export function parsePiPackageVersion(value: unknown): string | undefined {
	if (!value || typeof value !== "object") return undefined;
	const packageMetadata = value as { name?: unknown; version?: unknown };
	return packageMetadata.name === "@earendil-works/pi-coding-agent" &&
		typeof packageMetadata.version === "string"
		? packageMetadata.version
		: undefined;
}

export function isSupportedPiVersion(value: string | undefined): boolean {
	return value === CONN_PI_SUPPORTED_VERSION;
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
	let detectedPiVersion: string | undefined;
	let versionDetectionAttempted = false;
	let pendingRunOutcome: RunOutcome | undefined;
	let lastSettledOutcome: RunOutcome | undefined;

	const availableModels = () => projectAvailableModels(
		context?.scopedModels ?? [],
		context?.modelRegistry.getAvailable() ?? [],
		context?.model,
	);

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
		availableModels: availableModels(),
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
		if (!isSupportedPiVersion(detectedPiVersion)) return;
		descriptor = await loadRuntimeDescriptor();
		if (!descriptor) return;
		const currentDescriptor = descriptor;
		const candidate = connect(currentDescriptor.socketPath);
		socket = candidate;
		candidate.setEncoding("utf8");
		candidate.once("connect", () => {
			reconnectAttempt = 0;
			const snapshot = registrationSnapshotFromEntries(
				context?.sessionManager.getBranch() ?? [],
			);
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
				outcome: lastSettledOutcome ?? snapshot.outcome,
				activities: snapshot.activities,
				availableModels: availableModels(),
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

	const messageText = (messageValue: unknown): string | undefined => {
		const message = messageValue as {
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
		pendingRunOutcome = undefined;
		lastSettledOutcome = undefined;
		lastEvent = `session_start:${event.reason}`;
		startWatcher();
		queueMicrotask(() => void connectBroker());
	});
	pi.on("session_info_changed", observe("session_info_changed"));
	pi.on("agent_start", (_event, ctx) => {
		pendingRunOutcome = undefined;
		lastSettledOutcome = undefined;
		context = ctx;
		lastEvent = "agent_start";
		send({ type: "event", event: lastEvent, state: state() });
	});
	pi.on("turn_start", observe("turn_start"));
	pi.on("agent_end", (event, ctx) => {
		pendingRunOutcome = runOutcomeFromMessages(event.messages);
		context = ctx;
		lastEvent = "agent_end";
		send({ type: "event", event: lastEvent, state: state() });
	});
	pi.on("agent_settled", (_event, ctx) => {
		context = ctx;
		lastEvent = "agent_settled";
		lastSettledOutcome = pendingRunOutcome ?? "unknown";
		send({
			type: "event",
			event: lastEvent,
			state: state(),
			outcome: lastSettledOutcome,
		});
		pendingRunOutcome = undefined;
	});
	pi.on("model_select", observe("model_select"));
	pi.on("thinking_level_select", observe("thinking_level_select"));
	pi.on("message_start", (event: MessageStartEvent, ctx) => {
		context = ctx;
		lastEvent = "message_start";
		const role = (event.message as { role?: string }).role;
		const text = role === "user" ? messageText(event.message) : undefined;
		send({
			type: "event",
			event: lastEvent,
			state: state(),
			activity: text
				? {
						id: `${instanceId}:${++activitySequence}`,
						kind: "userMessage",
						text,
					}
				: undefined,
		});
	});
	pi.on("turn_end", (event: TurnEndEvent, ctx) => {
		context = ctx;
		lastEvent = "turn_end";
		const text = messageText(event.message);
		send({
			type: "event",
			event: lastEvent,
			state: state(),
			activity: text
				? {
						id: `${instanceId}:${++activitySequence}`,
						kind: "agentMessage",
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
