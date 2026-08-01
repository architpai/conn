import assert from "node:assert/strict";
import test from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import connPiExtension, {
	CONN_PI_EXTENSION_PROTOCOL,
	isSupportedPiVersion,
	parsePiPackageVersion,
	parseRuntimeDescriptor,
	projectAvailableModels,
	registrationSnapshotFromEntries,
	reconnectDelay,
	runOutcomeFromMessages,
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

test("accepts only Pi 0.83.0 for runtime qualification", () => {
	assert.equal(
		parsePiPackageVersion({
			name: "@earendil-works/pi-coding-agent",
			version: "0.83.0",
		}),
		"0.83.0",
	);
	assert.equal(isSupportedPiVersion("0.83.0"), true);
	assert.equal(isSupportedPiVersion("0.82.1"), false);
	assert.equal(
		parsePiPackageVersion({ name: "lookalike", version: "0.83.0" }),
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
	assert.equal(events.includes("message_start"), true);
	assert.equal(events.includes("turn_end"), true);
	assert.equal(events.includes("message_end"), false);
});

test("projects the authenticated Pi model scope with model-specific thinking levels", () => {
	assert.deepEqual(
		projectAvailableModels(
			[
				{
					model: {
						provider: "openai-codex",
						id: "gpt-5.4-mini",
						name: "GPT-5.4 mini",
						reasoning: true,
						thinkingLevelMap: { xhigh: null, max: "max" },
					},
				},
				{
					model: {
						provider: "anthropic",
						id: "claude-haiku",
						name: "Claude Haiku",
						reasoning: false,
					},
				},
			],
			[],
		),
		[
			{
				provider: "openai-codex",
				id: "gpt-5.4-mini",
				name: "GPT-5.4 mini",
				thinkingLevels: ["off", "minimal", "low", "medium", "high", "max"],
			},
			{
				provider: "anthropic",
				id: "claude-haiku",
				name: "Claude Haiku",
				thinkingLevels: ["off"],
			},
		],
	);
});

test("keeps the current model visible when it is outside the configured scope", () => {
	assert.deepEqual(
		projectAvailableModels(
			[{
				model: {
					provider: "anthropic",
					id: "claude-opus",
					name: "Claude Opus",
					reasoning: true,
				},
			}],
			[],
			{
				provider: "openai-codex",
				id: "gpt-current",
				name: "GPT Current",
				reasoning: false,
			},
		).map(({ provider, id }) => `${provider}/${id}`),
		["openai-codex/gpt-current", "anthropic/claude-opus"],
	);
});

test("projects only bounded terminal outcomes from Pi assistant messages", () => {
	assert.equal(
		runOutcomeFromMessages([{ role: "assistant", stopReason: "stop" }]),
		"completed",
	);
	assert.equal(
		runOutcomeFromMessages([{ role: "assistant", stopReason: "aborted" }]),
		"interrupted",
	);
	assert.equal(
		runOutcomeFromMessages([{ role: "assistant", stopReason: "error" }]),
		"failed",
	);
	assert.equal(
		runOutcomeFromMessages([{ role: "assistant", stopReason: "length" }]),
		"failed",
	);
	assert.equal(
		runOutcomeFromMessages([{ role: "assistant", stopReason: "toolUse" }]),
		"unknown",
	);
});

test("rehydrates a bounded stable transcript and outcome from the active Pi branch", () => {
	assert.deepEqual(
		registrationSnapshotFromEntries([
			{
				type: "message",
				id: "entry-user",
				message: { role: "user", content: "continue" },
			},
			{
				type: "message",
				id: "entry-agent",
				message: {
					role: "assistant",
					stopReason: "stop",
					content: [
						{ type: "text", text: "done" },
						{ type: "toolCall", name: "custom_tool" },
					],
				},
			},
			{
				type: "message",
				id: "entry-tool-result",
				message: { role: "toolResult", content: [{ type: "text", text: "noise" }] },
			},
		]),
		{
			outcome: "completed",
			activities: [
				{ id: "entry-user:text:0", kind: "userMessage", text: "continue" },
				{ id: "entry-agent:text:0", kind: "agentMessage", text: "done" },
				{ id: "entry-agent:tool:1", kind: "toolCall", text: "custom_tool" },
			],
		},
	);
});
