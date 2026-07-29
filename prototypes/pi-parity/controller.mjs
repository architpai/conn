#!/usr/bin/env node

/**
 * PROTOTYPE — command client for broker-backed external Pi sessions.
 *
 * Usage:
 *   node controller.mjs list
 *   node controller.mjs <pid> state
 *   node controller.mjs <pid> models
 *   node controller.mjs <pid> set-model <provider> <model-id>
 *   node controller.mjs <pid> set-thinking <level>
 *   node controller.mjs <pid> follow-up <message>
 *   node controller.mjs <pid> steer <message>
 *   node controller.mjs <pid> interrupt
 *   node controller.mjs <pid> answer <request-id> <answer>
 *   node controller.mjs <pid> decide <request-id> <approve|deny>
 */

import { randomUUID } from "node:crypto";
import { connect } from "node:net";

const socketPath = process.env.CONN_PI_BROKER_SOCKET;
if (!socketPath) throw new Error("CONN_PI_BROKER_SOCKET is required");

function request(command) {
	return new Promise((resolve, reject) => {
		const socket = connect(socketPath);
		let buffer = "";
		const timeout = setTimeout(() => {
			socket.destroy();
			reject(new Error("broker response timed out"));
		}, 10000);

		socket.setEncoding("utf8");
		socket.on("error", reject);
		socket.on("connect", () => write(socket, command));
		socket.on("data", (chunk) => {
			buffer += chunk;
			for (;;) {
				const newline = buffer.indexOf("\n");
				if (newline < 0) break;
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				if (!line.trim()) continue;
				const message = JSON.parse(line);
				if (message.type === "response" && message.id === command.id) {
					clearTimeout(timeout);
					socket.end();
					resolve(message);
					return;
				}
			}
		});
	});
}

function write(socket, value) {
	socket.write(`${JSON.stringify(value)}\n`);
}

const [, , target, action, ...args] = process.argv;
const id = `controller-${randomUUID()}`;

let command;
if (!target || target === "list") {
	command = { id, type: "list" };
} else {
	const pid = Number(target);
	if (!Number.isInteger(pid)) throw new Error("target must be a Pi pid");
	command = {
		id,
		pid,
		type:
			action === "state"
				? "get_state"
				: action === "models"
					? "list_models"
					: action === "set-model"
						? "set_model"
						: action === "set-thinking"
							? "set_thinking"
							: action === "follow-up"
								? "follow_up"
								: action,
	};
	if (command.type === "set_model") {
		[command.provider, command.modelId] = args;
	} else if (command.type === "set_thinking") {
		[command.level] = args;
	} else if (command.type === "answer") {
		[command.requestId, command.answer] = args;
	} else if (command.type === "decide") {
		[command.requestId, command.decision] = args;
	} else if (args.length) {
		command.message = args.join(" ");
	}
}

console.log(JSON.stringify(await request(command), null, 2));
