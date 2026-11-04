// robots.txt (RFC 9309). The group for our product token wins over "*"; within a group the
// longest matching Allow or Disallow path wins, Allow on a tie; "*" and "$" are wildcards.
// Crawl-delay is not in the RFC but is honoured when it is longer than our own spacing.
// A 4xx robots.txt means no rules; 5xx or a network failure means everything is disallowed
// until it can be read (RFC 9309 2.3.1.3 and 2.3.1.4).

export const BOT_TOKEN = "activityplanetbot";

interface Rule {
  allow: boolean;
  path: string;
  re: RegExp;
}

interface Group {
  agents: string[];
  rules: Rule[];
  crawlDelaySec: number | null;
}

export interface Robots {
  isAllowed(url: string): boolean;
  /** Seconds, when the matching group sets Crawl-delay. */
  crawlDelaySec: number | null;
  /** robots.txt could not be read (5xx or network): nothing is fetched from the host. */
  unavailable?: boolean;
}

function patternToRegExp(path: string): RegExp {
  let anchored = false;
  let p = path;
  if (p.endsWith("$")) {
    anchored = true;
    p = p.slice(0, -1);
  }
  const body = p
    .split("*")
    .map((part) => part.replace(/[.+?^${}()|[\]\\]/g, "\\$&"))
    .join(".*");
  return new RegExp(`^${body}${anchored ? "$" : ""}`);
}

/** Percent-encoding normalized so "/a%7eb" and "/a~b" compare equal. */
function normPath(path: string): string {
  return path.replace(/%([0-9a-f]{2})/gi, (m, hex: string) => {
    const ch = String.fromCharCode(parseInt(hex, 16));
    return /[A-Za-z0-9\-._~]/.test(ch) ? ch : m.toUpperCase();
  });
}

export function parseRobots(text: string, token: string = BOT_TOKEN): Robots {
  const groups: Group[] = [];
  let current: Group | null = null;
  let lastWasAgent = false;
  for (const rawLine of text.split(/\r\n|\r|\n/)) {
    const line = rawLine.replace(/#.*$/, "").trim();
    if (!line) continue;
    const m = /^([A-Za-z-]+)\s*:\s*(.*)$/.exec(line);
    if (!m) continue;
    const key = (m[1] ?? "").toLowerCase();
    const value = (m[2] ?? "").trim();
    if (key === "user-agent") {
      if (!current || !lastWasAgent) {
        current = { agents: [], rules: [], crawlDelaySec: null };
        groups.push(current);
      }
      current.agents.push(value.toLowerCase());
      lastWasAgent = true;
      continue;
    }
    lastWasAgent = false;
    if (!current) continue;
    if (key === "allow" || key === "disallow") {
      if (value === "") continue; // "Disallow:" with no path allows everything
      const path = normPath(value);
      current.rules.push({ allow: key === "allow", path, re: patternToRegExp(path) });
    } else if (key === "crawl-delay") {
      const n = Number(value);
      if (Number.isFinite(n) && n >= 0) current.crawlDelaySec = n;
    }
  }

  const tok = token.toLowerCase();
  const own = groups.filter((g) => g.agents.some((a) => a.split("/")[0]?.trim() === tok));
  const chosen = own.length > 0 ? own : groups.filter((g) => g.agents.includes("*"));
  const rules = chosen.flatMap((g) => g.rules);
  const delays = chosen.map((g) => g.crawlDelaySec).filter((d): d is number => d !== null);

  return {
    crawlDelaySec: delays.length ? Math.max(...delays) : null,
    isAllowed(url: string): boolean {
      let target: string;
      try {
        const u = new URL(url);
        target = normPath(u.pathname + u.search);
      } catch {
        return false;
      }
      if (target === "/robots.txt") return true;
      let best: Rule | null = null;
      for (const r of rules) {
        if (!r.re.test(target)) continue;
        if (
          !best ||
          r.path.length > best.path.length ||
          (r.path.length === best.path.length && r.allow && !best.allow)
        ) {
          best = r;
        }
      }
      return best ? best.allow : true;
    },
  };
}

export const ALLOW_ALL: Robots = { isAllowed: () => true, crawlDelaySec: null };
export const DISALLOW_ALL: Robots = {
  isAllowed: () => false,
  crawlDelaySec: null,
  unavailable: true,
};

/** The rules to use for a robots.txt response status. */
export function robotsForStatus(status: number, body: string): Robots {
  if (status >= 200 && status < 300) return parseRobots(body);
  if (status >= 400 && status < 500) return ALLOW_ALL;
  return DISALLOW_ALL;
}
