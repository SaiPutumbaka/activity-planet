import Link from "next/link";

import { ThemeToggle } from "@/components/shared/theme-toggle";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";

export default function LandingPage() {
  return (
    <main className="flex min-h-dvh flex-col items-center justify-center gap-6 px-6 text-center">
      <div className="absolute right-4 top-4">
        <ThemeToggle />
      </div>
      <Badge variant="secondary">Campus rollout · Now live</Badge>
      <h1 className="max-w-2xl text-4xl font-bold tracking-tight sm:text-6xl">
        Activity Planet
      </h1>
      <p className="max-w-md text-balance text-muted-foreground">
        Discover campus events, join activity hubs, and meet people who share
        your interests.
      </p>
      <div className="flex flex-col gap-3 sm:flex-row">
        <Button asChild size="lg">
          <Link href="/signup">Get started</Link>
        </Button>
        <Button asChild size="lg" variant="outline">
          <Link href="/login">Log in</Link>
        </Button>
      </div>
    </main>
  );
}
