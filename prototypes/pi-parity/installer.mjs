#!/usr/bin/env node

/**
 * PROTOTYPE — isolated install/update/remove contract for the Pi extension.
 *
 * It operates only beneath PI_CODING_AGENT_DIR and refuses to replace
 * anything not carrying Conn's exact ownership manifest.
 */

import { randomUUID } from "node:crypto";
import {
	chmod,
	copyFile,
	lstat,
	mkdir,
	readFile,
	rename,
	rm,
	writeFile,
} from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

const owner = "com.conn.pi-bridge";
const agentDirectory = process.env.PI_CODING_AGENT_DIR;
if (!agentDirectory) throw new Error("PI_CODING_AGENT_DIR is required");

const [action, source, version = "prototype"] = process.argv.slice(2);
const extensionsDirectory = join(resolve(agentDirectory), "extensions");
const destination = join(extensionsDirectory, "conn");
const manifestPath = join(destination, ".conn-install.json");

async function ownership() {
	let stat;
	try {
		stat = await lstat(destination);
	} catch (error) {
		if (error?.code === "ENOENT") return null;
		throw error;
	}

	if (!stat.isDirectory() || stat.isSymbolicLink()) return "foreign";

	try {
		const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
		return manifest.owner === owner ? manifest : "foreign";
	} catch (error) {
		if (error?.code === "ENOENT" || error instanceof SyntaxError) return "foreign";
		throw error;
	}
}

if (action === "status") {
	console.log(JSON.stringify({ destination, ownership: await ownership() }, null, 2));
	process.exit(0);
}

if (action === "install") {
	if (!source) throw new Error("source extension path is required");
	const existing = await ownership();
	if (existing === "foreign") throw new Error("destination is not Conn-owned");

	await mkdir(extensionsDirectory, { recursive: true, mode: 0o700 });
	const temporary = join(
		extensionsDirectory,
		`.conn-install-${process.pid}-${randomUUID()}`,
	);
	await mkdir(temporary, { mode: 0o700 });
	await copyFile(resolve(source), join(temporary, "index.ts"));
	await writeFile(
		join(temporary, ".conn-install.json"),
		`${JSON.stringify({ owner, version }, null, 2)}\n`,
		{ mode: 0o600 },
	);
	await chmod(join(temporary, "index.ts"), 0o600);

	if (existing) {
		const previous = `${destination}.previous-${randomUUID()}`;
		await rename(destination, previous);
		try {
			await rename(temporary, destination);
			await rm(previous, { recursive: true });
		} catch (error) {
			await rename(previous, destination).catch(() => undefined);
			throw error;
		}
	} else {
		await rename(temporary, destination);
	}
	console.log(JSON.stringify({ outcome: existing ? "updated" : "installed", version }));
	process.exit(0);
}

if (action === "remove") {
	const existing = await ownership();
	if (!existing) {
		console.log(JSON.stringify({ outcome: "already-absent" }));
		process.exit(0);
	}
	if (existing === "foreign") throw new Error("destination is not Conn-owned");
	await rm(destination, { recursive: true });
	console.log(JSON.stringify({ outcome: "removed", version: existing.version }));
	process.exit(0);
}

throw new Error(`unsupported action: ${action ?? "<missing>"}`);
