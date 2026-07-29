#!/usr/bin/env node

/**
 * PROTOTYPE — small controller for the external Pi TUI bridge.
 *
 * Usage:
 *   node controller.mjs list
 *   node controller.mjs <pid> state
 *   node controller.mjs <pid> follow-up "message"
 *   node controller.mjs <pid> steer "message"
 *   node controller.mjs <pid> interrupt
 */

import { readdir } from "node:fs/promises";
import { connect } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

const directory =
	process.env.CONN_PI_BRIDGE_DIR ??
	join(homedir(), "Library", "Application Support", "Conn", "PiBridge", "v1");

async function socketPaths() {
	return (await readdir(directory).catch(() => []))
		.filter((name) => name.endsWith(".sock"))
		.map((name) => join(directory, name));
}

function request(socketPath, command, waitForResponse = true) {
	return new Promise((resolve, reject) => {
		const socket = connect(socketPath);
		let buffer = "";
		const messages = [];

		socket.setEncoding("utf8");
		socket.on("error", reject);
		socket.on("data", (chunk) => {
			buffer += chunk;
			for (;;) {
				const newline = buffer.indexOf("\n");
				if (newline < 0) break;
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				if (!line.trim()) continue;
				const message = JSON.parse(line);
				messages.push(message);
				if (!waitForResponse || message.type === "response") {
					socket.end();
					resolve(waitForResponse ? message : messages);
					return;
				}
			}
		});
		socket.on("connect", () => {
			if (command) socket.write(`${JSON.stringify(command)}\n`);
		});
	});
}

async function list() {
	const rows = [];
	for (const socketPath of await socketPaths()) {
		try {
			const [hello] = await request(socketPath, null, false);
			rows.push({ socketPath, ...hello.state });
		} catch {
			rows.push({ socketPath, stale: true });
		}
	}
	console.log(JSON.stringify(rows, null, 2));
}

const [, , target, action, ...rest] = process.argv;

if (!target || target === "list") {
	await list();
	process.exit(0);
}

const socketPath = join(directory, `${target}.sock`);
const type =
	action === "state"
		? "get_state"
		: action === "follow-up"
			? "follow_up"
			: action;

const response = await request(socketPath, {
	id: `prototype-${Date.now()}`,
	type,
	...(rest.length ? { message: rest.join(" ") } : {}),
});
console.log(JSON.stringify(response, null, 2));
