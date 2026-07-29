import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
} from "@earendil-works/pi-coding-agent";

export const CONN_PI_EXTENSION_PROTOCOL = 1;
export const CONN_PI_EXTENSION_VERSION = "0.2.1";

/**
 * Conn's external-Pi bridge. The factory deliberately performs no I/O,
 * starts no timer, and changes no Pi behavior.
 */
export default function connPiExtension(pi: ExtensionAPI): void {
	let context: ExtensionContext | undefined;

	pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
		context = ctx;
		queueMicrotask(() => {
			void context;
			void event;
		});
	});

	pi.on("session_shutdown", () => {
		context = undefined;
	});
}
