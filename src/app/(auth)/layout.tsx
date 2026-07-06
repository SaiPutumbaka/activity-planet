import Link from "next/link";

import { LogoWordmark } from "@/components/shared/logo";
import { ThemeToggle } from "@/components/shared/theme-toggle";

export default function AuthLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <div className="relative flex min-h-dvh flex-col items-center justify-center gap-6 overflow-x-clip px-4 py-10">
      <div className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-full bg-grid bg-grid-fade" />
      <div className="pointer-events-none absolute -top-32 left-1/2 -z-10 h-96 w-[36rem] -translate-x-1/2 rounded-full bg-violet-600/25 blur-[110px]" />
      <div className="pointer-events-none absolute bottom-0 right-[-8rem] -z-10 h-72 w-72 rounded-full bg-fuchsia-600/15 blur-[100px]" />
      <div className="absolute right-4 top-4">
        <ThemeToggle />
      </div>
      <Link href="/" aria-label="Activity Planet home">
        <LogoWordmark className="text-xl" />
      </Link>
      {children}
    </div>
  );
}
