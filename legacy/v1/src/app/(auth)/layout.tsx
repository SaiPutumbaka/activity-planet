import Link from "next/link";

import { LogoWordmark } from "@/components/shared/logo";
import { ThemeToggle } from "@/components/shared/theme-toggle";

export default function AuthLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <div className="relative flex min-h-dvh flex-col items-center justify-center gap-6 overflow-x-clip px-4 py-10">
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
