import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { supabase } from "@/lib/supabase";

export const Route = createFileRoute("/")({
  component: HomePage,
});

function HomePage() {
  const health = useQuery({
    queryKey: ["health"],
    queryFn: async () => {
      // Same probe as apps/web /api/health: PostgREST validates the column before RLS filters rows.
      const { error } = await supabase.from("profiles").select("id").limit(1);
      if (error) throw new Error(`${error.code ?? "db_error"}: ${error.message}`);
      return { ok: true as const };
    },
  });

  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 px-4 pb-[env(safe-area-inset-bottom)]">
      <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
      <h1 className="text-3xl font-semibold tracking-tight">v2 scaffold</h1>
      <p className="text-text-2">
        This is the product app, rebuilt from scratch. Design system, auth and the show-up loop land
        over the next two weeks.
      </p>
      <p className="text-sm">
        Database:{" "}
        {health.isPending
          ? "checking..."
          : health.isError
            ? `error (${health.error.message})`
            : "connected"}
      </p>
    </main>
  );
}
