/**
 * Messaging (D-043, docs/design/messaging/MESSAGING_DESIGN.md section 14.3): typed RPC calls,
 * result schemas, Realtime topics and subscriptions, the link rules that mirror the server, the
 * optimistic outbox and the error copy. The app's query hooks live in apps/app/src/lib/messaging.ts.
 */
export * from "./api";
export * from "./display";
export * from "./errors";
export * from "./images";
export * from "./outbox";
export * from "./realtime";
export * from "./schemas";
export * from "./text";
