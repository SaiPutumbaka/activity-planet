/**
 * Imported listings (D-014, D-022, D-037): the words an imported card or event page shows,
 * pure so they can be tested without a browser.
 *
 *   importChips(label)            // ["Georgia State student org event"] or ["Open to the public"]
 *   listedByLine("PIN, ...", "Chess Club")   // "Listed by PIN, ... · Hosted by Chess Club"
 *   notAffiliatedLine(label)      // "Not affiliated with or endorsed by Georgia State University."
 *   removalMailto({ id, title, externalUrl, appUrl })  // mailto: link for the organizer
 */

/** Where removal requests go until the claim and takedown UI ships in week 7 (D-037). */
export const SUPPORT_EMAIL = "support@activityplanet.app";

/** The fields of imported_event_labels() these helpers read. */
export interface ImportLabelLike {
  item_label: string | null;
  open_to_public: boolean | null;
  affiliated_org_name: string | null;
}

/**
 * Chips for an imported item: the source's own label (PIN items: "Georgia State student org
 * event", since many need a PantherCard), then "Open to the public" only where the source says
 * so. Nothing is inferred when the source is silent.
 */
export function importChips(label: ImportLabelLike | null | undefined): string[] {
  if (!label) return [];
  const chips: string[] = [];
  const own = label.item_label?.trim();
  if (own) chips.push(own);
  if (label.open_to_public === true) chips.push("Open to the public");
  return chips;
}

/** "Listed by <source>", plus the hosting organization when the source names one. */
export function listedByLine(
  sourceName: string | null | undefined,
  hostOrg?: string | null,
): string {
  const source = sourceName?.trim() || "a public calendar";
  const host = hostOrg?.trim();
  return host && host.toLowerCase() !== source.toLowerCase()
    ? `Listed by ${source} · Hosted by ${host}`
    : `Listed by ${source}`;
}

/**
 * The D-022 line, only for items from a source that belongs to an organization (today: the
 * Georgia State sources). Other sources get nothing.
 */
export function notAffiliatedLine(label: ImportLabelLike | null | undefined): string | null {
  const org = label?.affiliated_org_name?.trim();
  return org ? `Not affiliated with or endorsed by ${org}.` : null;
}

/** A prefilled email asking support to take a listing down. */
export function removalMailto(e: {
  id: string;
  title: string;
  externalUrl?: string | null;
  appUrl?: string | null;
}): string {
  const lines = [
    "Please remove this listing from Activity Planet.",
    "",
    `Listing: ${e.title}`,
    e.appUrl ? `On Activity Planet: ${e.appUrl}` : `Listing id: ${e.id}`,
    e.externalUrl ? `Original: ${e.externalUrl}` : null,
    "",
    "I am (the organizer / with the organizer / other):",
  ].filter((l): l is string => l !== null);
  const subject = `Removal request: ${e.title}`;
  return `mailto:${SUPPORT_EMAIL}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(lines.join("\n"))}`;
}

/** What a ticketing source's listings show (D-042 slice 10): the seller's link and credit. */
export interface TicketSeller {
  name: string;
  /** The seller's homepage, where the credit links. */
  homeUrl: string;
  /** The link-out button: tickets and details are on the seller's own event page. */
  linkLabel: string;
  /** The credit shown wherever the seller's data appears. */
  credit: string;
}

const SELLERS: Record<string, TicketSeller> = {
  // Ticketmaster's Discovery API terms: link to the Ticketmaster event page to buy.
  ticketmaster: {
    name: "Ticketmaster",
    homeUrl: "https://www.ticketmaster.com/",
    linkLabel: "Tickets on Ticketmaster",
    credit: "Event data from Ticketmaster",
  },
  // SeatGeek's Platform terms: SeatGeek's mark wherever its data appears, linking to its
  // homepage; a "powered by" form is allowed.
  seatgeek: {
    name: "SeatGeek",
    homeUrl: "https://seatgeek.com/",
    linkLabel: "Tickets on SeatGeek",
    credit: "Powered by SeatGeek",
  },
};

/**
 * The ticket seller behind an imported listing, from its source kind (imported_event_labels
 * source_kind), or null for every other source.
 */
export function ticketSeller(sourceKind: string | null | undefined): TicketSeller | null {
  return sourceKind && Object.hasOwn(SELLERS, sourceKind) ? SELLERS[sourceKind]! : null;
}
