#!/usr/bin/env node

/**
 * PROTOTYPE — Conn-owned broker for Pi parity testing.
 *
 * Pi extensions connect outbound. Controllers connect separately. The broker
 * correlates commands and responses without reading Pi session files.
 */

import { chmod, mkdir, unlink } from "node:fs/promises";
import { createServer } from "node:net";
import { dirname } from "node:path";

const socketPath = process.env.CONN_PI_BROKER_SOCKET;
if (!socketPath) throw new Error("CONN_PI_BROKER_SOCKET is required");

await mkdir(dirname(socketPath), { recursive: true, mode: 0o700 });
await chmod(dirname(socketPath), 0o700);
await unlink(socketPath).catch(() => undefined);

const bridges = new Map();
const pendingControllers = new Map();
let sequence = 0;

function write(socket, value) {
	socket.write(`${JSON.stringify(value)}\n`);
}

function publicSession(bridge) {
	return {
		pid: bridge.pid,
		instanceId: bridge.instanceId,
		connectedSequence: bridge.connectedSequence,
		state: bridge.state,
		pendingAttention: [...bridge.attention.values()],
	};
}

function sendSessions(socket, id) {
	write(socket, {
		type: "response",
		id,
		success: true,
		sessions: [...bridges.values()].map(publicSession),
	});
}

function handleBridge(socket, message) {
	if (message.type === "register") {
		const pid = Number(message.pid);
		if (!Number.isInteger(pid) || pid <= 0) throw new Error("invalid bridge pid");
		const prior = bridges.get(pid);
		if (prior && prior.socket !== socket) prior.socket.destroy();
		const bridge = {
			socket,
			pid,
			instanceId: message.instanceId,
			connectedSequence: ++sequence,
			state: message.state,
			attention: new Map(),
		};
		bridges.set(pid, bridge);
		socket.bridgePID = pid;
		write(socket, { type: "registered", protocol: 1, connectedSequence: sequence });
		return;
	}

	const bridge = bridges.get(socket.bridgePID);
	if (!bridge || bridge.socket !== socket) throw new Error("bridge is not registered");

	if (message.state) bridge.state = message.state;
	if (message.type === "attention") {
		bridge.attention.set(message.request.id, message.request);
	}
	if (message.type === "attention_resolved") {
		bridge.attention.delete(message.requestId);
	}
	if (message.type === "response") {
		const controller = pendingControllers.get(message.id);
		if (controller) {
			pendingControllers.delete(message.id);
			write(controller, message);
		}
	}
}

function handleController(socket, message) {
	if (message.type === "list") {
		sendSessions(socket, message.id);
		return;
	}

	const pid = Number(message.pid);
	const bridge = bridges.get(pid);
	if (!bridge) {
		write(socket, {
			type: "response",
			id: message.id,
			success: false,
			error: `no connected bridge for pid ${message.pid}`,
		});
		return;
	}

	pendingControllers.set(message.id, socket);
	write(bridge.socket, message);
}

const server = createServer((socket) => {
	socket.setEncoding("utf8");
	let buffer = "";
	socket.on("data", (chunk) => {
		buffer += chunk;
		for (;;) {
			const newline = buffer.indexOf("\n");
			if (newline < 0) break;
			const line = buffer.slice(0, newline);
			buffer = buffer.slice(newline + 1);
			if (!line.trim()) continue;
			try {
				const message = JSON.parse(line);
				if (message.role === "bridge" || socket.bridgePID) {
					handleBridge(socket, message);
				} else {
					handleController(socket, message);
				}
			} catch (error) {
				write(socket, {
					type: "protocol_error",
					error: error instanceof Error ? error.message : String(error),
				});
			}
		}
	});
	socket.on("close", () => {
		const bridge = bridges.get(socket.bridgePID);
		if (bridge?.socket === socket) bridges.delete(socket.bridgePID);
		for (const [id, controller] of pendingControllers) {
			if (controller === socket) pendingControllers.delete(id);
		}
	});
});

server.listen(socketPath, async () => {
	await chmod(socketPath, 0o600);
	console.log(JSON.stringify({ type: "ready", socketPath, pid: process.pid }));
});

async function shutdown() {
	for (const bridge of bridges.values()) bridge.socket.destroy();
	for (const controller of pendingControllers.values()) controller.destroy();
	await new Promise((resolve) => server.close(resolve));
	await unlink(socketPath).catch(() => undefined);
	process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
