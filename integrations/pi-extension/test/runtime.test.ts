import assert from "node:assert/strict";
import test from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import connPiExtension, {
	CONN_PI_EXTENSION_PROTOCOL,
	parsePiPackageVersion,
	parseRuntimeDescriptor,
	reconnectDelay,
} from "../../../Sources/ConnPiAdapter/Resources/PiExtension/index.ts";

const now = 2_000_000_000_000;
const valid = {
	protocolVersion: CONN_PI_EXTENSION_PROTOCOL,
	generation: "a1000000-0000-4000-8000-000000000001",
	socketPath: "/private/tmp/conn-pi-501/broker.sock",
	authenticationSecret: "a".repeat(64),
	issuedAt: now,
	expiresAt: now + 30_000,
};

test("accepts only a fresh compatible bounded runtime descriptor", () => {
	assert.deepEqual(parseRuntimeDescriptor(valid, now), valid);
	assert.equal(
		parseRuntimeDescriptor({ ...valid, protocolVersion: 999 }, now),
		undefined,
	);
	assert.equal(parseRuntimeDescriptor(valid, now + 30_001), undefined);
	assert.equal(
		parseRuntimeDescriptor({ ...valid, socketPath: "relative.sock" }, now),
		undefined,
	);
	assert.equal(
		parseRuntimeDescriptor(
			{ ...valid, authenticationSecret: "too-short" },
			now,
		),
		undefined,
	);
});

test("accepts only the pinned Pi package identity for runtime qualification", () => {
	assert.equal(
		parsePiPackageVersion({
			name: "@earendil-works/pi-coding-agent",
			version: "0.82.1",
		}),
		"0.82.1",
	);
	assert.equal(
		parsePiPackageVersion({ name: "lookalike", version: "0.82.1" }),
		undefined,
	);
});

test("reconnect backoff is bounded and jittered deterministically", () => {
	assert.equal(reconnectDelay(0, 0), 150);
	assert.equal(reconnectDelay(0, 1), 250);
	assert.equal(reconnectDelay(20, 0), 1_500);
	assert.equal(reconnectDelay(20, 1), 2_500);
});

test("the extension registers no custom tools or tool-call interception", () => {
	const events: string[] = [];
	let registeredTools = 0;
	const pi = {
		on(event: string) {
			events.push(event);
		},
		registerTool() {
			registeredTools += 1;
		},
	} as unknown as ExtensionAPI;

	connPiExtension(pi);

	assert.equal(registeredTools, 0);
	assert.equal(events.includes("tool_call"), false);
});
