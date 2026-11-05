/**
 * Recommendations (D-045, docs/design/recommendations/RECS_DESIGN.md slice 2): result schemas for
 * the recs_* RPCs, reason chip copy and the landing page's week cards. The app's query options
 * live in apps/app/src/lib/recs.ts; the landing page uses landing.ts from apps/web.
 */
export * from "./landing";
export * from "./reasons";
export * from "./schemas";
