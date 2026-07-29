/**
 * PROTOTYPE — external Pi TUI control bridge.
 *
 * Question: can Conn follow up, steer, and interrupt a Pi TUI that the user
 * launched independently? This extension runs inside that original Pi process
 * and exposes only those supported ExtensionAPI controls over a user-local
 * Unix socket.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { mkdir, chmod, unlink } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

type Command = {
	id?: string;
	type?: string;
	message?: string;
};

type BridgeState = {
	sessionId: string | null;
	sessionFile: string | null;
	sessionName: string | null;
	cwd: string | null;
	isIdle: boolean;
	hasPendingMessages: boolean;
	lastEvent: string;
	activeToolCount: number;
	pid: number;
};

const bridgeDirectory =
	process.env.CONN_PI_BRIDGE_DIR ??
	join(homedir(), "Library", "Application Support", "Conn", "PiBridge", "v1");
const socketPath = join(bridgeDirectory, `${process.pid}.sock`);

export default async function connBridge(pi: ExtensionAPI) {
	await mkdir(bridgeDirectory, { recursive: true, mode: 0o700 });
	await chmod(bridgeDirectory, 0o700);
	await unlink(socketPath).catch(() => undefined);

	let context: ExtensionContext | undefined;
	let lastEvent = "extension_loaded";
	let activeToolCount = 0;
	const clients = new Set<Socket>();

	const state = (): BridgeState => ({
		sessionId: context?.sessionManager.getSessionId() ?? null,
		sessionFile: context?.sessionManager.getSessionFile() ?? null,
		sessionName: context?.sessionManager.getSessionName() ?? null,
		cwd: context?.cwd ?? null,
		isIdle: context?.isIdle() ?? true,
		hasPendingMessages: context?.hasPendingMessages() ?? false,
		lastEvent,
		activeToolCount,
		pid: process.pid,
	});

	const write = (socket: Socket, value: unknown) => {
		socket.write(`${JSON.stringify(value)}\n`);
	};

	const broadcast = (value: unknown) => {
		for (const client of clients) write(client, value);
	};

	const respond = (socket: Socket, command: Command, success: boolean, error?: string) => {
		write(socket, {
			type: "response",
			id: command.id ?? null,
			command: command.type ?? null,
			success,
			...(error ? { error } : {}),
			state: state(),
		});
	};

	const handle = (socket: Socket, command: Command) => {
		try {
			switch (command.type) {
				case "get_state":
					respond(socket, command, true);
					return;
				case "follow_up":
					if (!command.message) throw new Error("message is required");
					if (context?.isIdle() ?? true) {
						pi.sendUserMessage(command.message);
					} else {
						pi.sendUserMessage(command.message, { deliverAs: "followUp" });
					}
					respond(socket, command, true);
					return;
				case "steer":
					if (!command.message) throw new Error("message is required");
					if (!context || context.isIdle()) throw new Error("session is idle");
					pi.sendUserMessage(command.message, { deliverAs: "steer" });
					respond(socket, command, true);
					return;
				case "interrupt":
					if (!context || context.isIdle()) throw new Error("session is idle");
					context.abort();
					respond(socket, command, true);
					return;
				default:
					throw new Error(`unsupported command: ${command.type ?? "<missing>"}`);
			}
		} catch (error) {
			respond(socket, command, false, error instanceof Error ? error.message : String(error));
		}
	};

	const server = createServer((socket) => {
		clients.add(socket);
		write(socket, { type: "hello", state: state() });

		let buffer = "";
		socket.setEncoding("utf8");
		socket.on("data", (chunk) => {
			buffer += chunk;
			for (;;) {
				const newline = buffer.indexOf("\n");
				if (newline < 0) break;
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				if (!line.trim()) continue;
				try {
					handle(socket, JSON.parse(line) as Command);
				} catch (error) {
					write(socket, {
						type: "protocol_error",
						error: error instanceof Error ? error.message : String(error),
					});
				}
			}
		});
		socket.on("close", () => clients.delete(socket));
		socket.on("error", () => clients.delete(socket));
	});

	await new Promise<void>((resolve, reject) => {
		server.once("error", reject);
		server.listen(socketPath, () => resolve());
	});
	await chmod(socketPath, 0o600);

	const observe = (eventName: string) => (_event: unknown, ctx: ExtensionContext) => {
		context = ctx;
		lastEvent = eventName;
		broadcast({ type: "event", event: eventName, state: state() });
	};

	const toolStarted = (_event: unknown, ctx: ExtensionContext) => {
		context = ctx;
		lastEvent = "tool_execution_start";
		activeToolCount += 1;
		broadcast({ type: "event", event: lastEvent, state: state() });
	};

	const toolEnded = (_event: unknown, ctx: ExtensionContext) => {
		context = ctx;
		lastEvent = "tool_execution_end";
		activeToolCount = Math.max(0, activeToolCount - 1);
		broadcast({ type: "event", event: lastEvent, state: state() });
	};

	pi.on("session_start", observe("session_start"));
	pi.on("agent_start", observe("agent_start"));
	pi.on("turn_start", observe("turn_start"));
	pi.on("turn_end", observe("turn_end"));
	pi.on("agent_end", observe("agent_end"));
	pi.on("agent_settled", observe("agent_settled"));
	pi.on("tool_execution_start", toolStarted);
	pi.on("tool_execution_end", toolEnded);
	pi.on("model_select", observe("model_select"));
	pi.on("thinking_level_select", observe("thinking_level_select"));

	pi.on("session_shutdown", async (_event, ctx) => {
		context = ctx;
		broadcast({ type: "event", event: "session_shutdown", state: state() });
		for (const client of clients) client.destroy();
		await new Promise<void>((resolve) => server.close(() => resolve()));
		await unlink(socketPath).catch(() => undefined);
	});
}
