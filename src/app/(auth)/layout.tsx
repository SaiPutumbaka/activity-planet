import Link from "next/link";

import { ThemeToggle } from "@/components/shared/theme-toggle";

export default function AuthLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <div className="relative flex min-h-dvh flex-col items-center justify-center gap-6 px-4 py-10">
      <div className="absolute right-4 top-4">
        <ThemeToggle />
      </div>
      <Link href="/" className="text-xl font-bold tracking-tight">
        Activity Planet
      </Link>
      {children}
    </div>
  );
}
