// Where the bot may connect: public internet hosts only. Seed pages, discovered links,
// <base href> and redirects can all name a host, so a hostile or careless page could point the
// runner at its own network (loopback, a cloud metadata service, a private LAN). Two checks:
//   - before a request, the URL's host and port (publicHostProblem),
//   - when a connection opens, every address the name resolves to (safeLookup), which also
//     covers each redirect hop and DNS rebinding.

import { lookup as dnsLookup, type LookupAddress, type LookupOptions } from "node:dns";
import { isIP } from "node:net";

/** IPv4 ranges that are not the public internet (RFC 6890 and friends). */
const V4_BLOCKED: [number, number][] = [
  ["0.0.0.0", 8], // "this network", unspecified
  ["10.0.0.0", 8], // private
  ["100.64.0.0", 10], // CGNAT
  ["127.0.0.0", 8], // loopback
  ["169.254.0.0", 16], // link-local, cloud metadata
  ["172.16.0.0", 12], // private
  ["192.0.0.0", 24], // IETF protocol assignments
  ["192.0.2.0", 24], // documentation
  ["192.88.99.0", 24], // 6to4 relay anycast
  ["192.168.0.0", 16], // private
  ["198.18.0.0", 15], // benchmarking
  ["198.51.100.0", 24], // documentation
  ["203.0.113.0", 24], // documentation
  ["224.0.0.0", 4], // multicast
  ["240.0.0.0", 4], // reserved, broadcast
].map(([a, bits]) => [v4ToInt(a as string), bits as number]);

function v4ToInt(ip: string): number {
  return ip.split(".").reduce((acc, part) => acc * 256 + Number(part), 0);
}

function v4Blocked(ip: string): boolean {
  const n = v4ToInt(ip);
  return V4_BLOCKED.some(([base, bits]) => {
    const size = 2 ** (32 - bits);
    return n >= base && n < base + size;
  });
}

/** The 16 bytes of an IPv6 address (with or without a trailing dotted quad), or null. */
function v6Bytes(ip: string): number[] | null {
  let s = ip.toLowerCase();
  const zone = s.indexOf("%");
  if (zone >= 0) s = s.slice(0, zone);
  let tail: number[] = [];
  const dotted = /(\d+\.\d+\.\d+\.\d+)$/.exec(s);
  if (dotted?.[1]) {
    if (isIP(dotted[1]) !== 4) return null;
    tail = dotted[1].split(".").map(Number);
    s = s.slice(0, s.length - dotted[1].length) + "0:0";
  }
  const halves = s.split("::");
  if (halves.length > 2) return null;
  const parse = (h: string) => (h === "" ? [] : h.split(":"));
  const head = parse(halves[0] ?? "");
  const rest = halves.length === 2 ? parse(halves[1] ?? "") : [];
  const fill = 8 - head.length - rest.length;
  if (fill < 0 || (halves.length === 1 && fill !== 0)) return null;
  const groups = [...head, ...Array<string>(halves.length === 2 ? fill : 0).fill("0"), ...rest];
  const bytes: number[] = [];
  for (const g of groups) {
    if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
    const v = parseInt(g, 16);
    bytes.push(v >> 8, v & 0xff);
  }
  if (tail.length === 4) bytes.splice(12, 4, ...tail);
  return bytes.length === 16 ? bytes : null;
}

function v6Blocked(ip: string): boolean {
  const b = v6Bytes(ip);
  if (!b) return true;
  const zeros = (from: number, to: number) => b.slice(from, to).every((x) => x === 0);
  const embeddedV4 = () => b.slice(12, 16).join(".");
  if (zeros(0, 16)) return true; // ::
  if (zeros(0, 15) && b[15] === 1) return true; // ::1
  // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d): judge the IPv4 address.
  if (zeros(0, 10) && b[10] === 0xff && b[11] === 0xff) return v4Blocked(embeddedV4());
  if (zeros(0, 12)) return v4Blocked(embeddedV4());
  // NAT64 well-known prefix 64:ff9b::/96.
  if (b[0] === 0x00 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b && zeros(4, 12))
    return v4Blocked(embeddedV4());
  const first = b[0] ?? 0;
  const second = b[1] ?? 0;
  if ((first & 0xfe) === 0xfc) return true; // fc00::/7 unique local
  if (first === 0xfe && (second & 0xc0) === 0x80) return true; // fe80::/10 link-local
  if (first === 0xfe && (second & 0xc0) === 0xc0) return true; // fec0::/10 site-local (old)
  if (first === 0xff) return true; // multicast
  if (first === 0x20 && second === 0x01 && b[2] === 0x0d && b[3] === 0xb8) return true; // 2001:db8::/32
  if (first === 0x20 && second === 0x02) {
    // 6to4 (2002::/16) carries an IPv4 address in bytes 2-5.
    return v4Blocked(b.slice(2, 6).join("."));
  }
  return false;
}

/** True when an IP literal is outside the public internet. Non-IPs return false. */
export function isBlockedIp(ip: string): boolean {
  const bare = ip.replace(/^\[|\]$/g, "");
  const kind = isIP(bare);
  if (kind === 4) return v4Blocked(bare);
  if (kind === 6) return v6Blocked(bare);
  return false;
}

/** Name suffixes that never resolve to a public site. */
const PRIVATE_SUFFIX =
  /(^|\.)(localhost|local|internal|intranet|lan|home|corp|home\.arpa|test|invalid|example)$/i;

/**
 * Why a URL's host or port is not a public https endpoint, or null when it is. Covers IP
 * literals in blocked ranges, localhost and private-use names, single-label hosts and any port
 * but 443.
 */
export function publicHostProblem(u: URL): string | null {
  if (u.port !== "" && u.port !== "443") return "port";
  if (u.username || u.password) return "credentials";
  const host = u.hostname.toLowerCase().replace(/\.$/, "");
  if (host === "") return "empty_host";
  const bare = host.replace(/^\[|\]$/g, "");
  if (isIP(bare)) return isBlockedIp(bare) ? "private_ip" : null;
  if (!host.includes(".")) return "single_label";
  // A dotted all-numeric name that is not a valid IPv4 literal is junk, not a site.
  if (/^[\d.]+$/.test(host)) return "private_ip";
  if (PRIVATE_SUFFIX.test(host)) return "private_name";
  return null;
}

type LookupCallback = (
  err: NodeJS.ErrnoException | null,
  address: string | LookupAddress[],
  family?: number,
) => void;

/**
 * A dns.lookup drop-in for socket connects that fails when the name resolves to any blocked
 * address. Every address is checked, not just the first, so a name cannot mix a public and a
 * private answer and hope the private one is picked.
 */
export function safeLookup(
  hostname: string,
  options: LookupOptions | number | LookupCallback,
  callback?: LookupCallback,
): void {
  const cb = (typeof options === "function" ? options : callback) as LookupCallback;
  const opts: LookupOptions =
    typeof options === "object" ? options : typeof options === "number" ? { family: options } : {};
  dnsLookup(hostname, { ...opts, all: true }, (err, addresses) => {
    if (err) return cb(err, []);
    const list = addresses as LookupAddress[];
    const bad = list.find((a) => isBlockedIp(a.address));
    if (bad || list.length === 0) {
      const e: NodeJS.ErrnoException = new Error(
        `refusing to connect to ${hostname}: resolves to a non-public address`,
      );
      e.code = "EBLOCKEDADDRESS";
      return cb(e, []);
    }
    if (opts.all) return cb(null, list);
    const firstAddr = list[0] as LookupAddress;
    cb(null, firstAddr.address, firstAddr.family);
  });
}
