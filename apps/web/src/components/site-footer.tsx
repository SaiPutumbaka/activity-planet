import Link from "next/link";

/** Every page's way out (launch audit L20): home, help and the legal pages, on one line. */
const LINKS = [
  ["/", "Activity Planet"],
  ["/support", "Help and contact"],
  ["/safety", "Safety"],
  ["/guidelines", "Community Guidelines"],
  ["/terms", "Terms"],
  ["/privacy", "Privacy"],
] as const;

export function SiteFooter() {
  return (
    <footer className="border-t border-border px-4 py-6">
      <nav
        aria-label="Site"
        className="mx-auto flex max-w-2xl flex-wrap gap-x-5 gap-y-2 text-sm text-text-2"
      >
        {LINKS.map(([href, label]) => (
          <Link
            key={href}
            href={href}
            className="inline-flex min-h-11 items-center hover:text-text hover:underline"
          >
            {label}
          </Link>
        ))}
      </nav>
    </footer>
  );
}
