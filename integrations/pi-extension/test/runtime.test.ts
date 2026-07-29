import assert from "node:assert/strict";
import test from "node:test";
import {
	approvalDisposition,
	attentionMayRoute,
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
	features: {
		questionsEnabled: false,
		approvalsEnabled: false,
	},
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

test("attention routing follows the live feature gate", () => {
	const disabled = { questionsEnabled: false, approvalsEnabled: false };
	const questions = { questionsEnabled: true, approvalsEnabled: false };
	assert.equal(attentionMayRoute("question", disabled, true), false);
	assert.equal(attentionMayRoute("question", questions, false), false);
	assert.equal(attentionMayRoute("question", questions, true), true);
	assert.equal(attentionMayRoute("approval", questions, true), false);
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

test("approval mediation is default-pass, read-only-pass, and loss-deny", () => {
	assert.equal(approvalDisposition(false, false, "bash"), "pass");
	assert.equal(approvalDisposition(true, false, "read"), "pass");
	assert.equal(approvalDisposition(true, false, "bash"), "deny");
	assert.equal(approvalDisposition(true, true, "bash"), "ask");
	assert.equal(approvalDisposition(true, false, "unknown-tool"), "deny");
});

test("reconnect backoff is bounded and jittered deterministically", () => {
	assert.equal(reconnectDelay(0, 0), 150);
	assert.equal(reconnectDelay(0, 1), 250);
	assert.equal(reconnectDelay(20, 0), 1_500);
	assert.equal(reconnectDelay(20, 1), 2_500);
});
