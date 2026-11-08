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

/**
 * Where "Request removal" goes (collector completion Slice 2): the site's removal form with the
 * event id filled in, or the support email when no site URL is configured.
 */
export function removalHref(e: {
  id: string;
  title: string;
  externalUrl?: string | null;
  appUrl?: string | null;
  siteUrl?: string | null;
}): string {
  const site = e.siteUrl?.trim().replace(/\/+$/, "");
  if (site && /^https?:\/\//i.test(site)) {
    return `${site}/bot/remove?event=${encodeURIComponent(e.id)}`;
  }
  return removalMailto(e);
}

/** The credit a geocoded imported item carries (imported_event_labels geocode_provider). */
export interface LocationCredit {
  text: string;
  href: string;
}

const OSM_CREDIT: LocationCredit = {
  text: "Location © OpenStreetMap contributors",
  href: "https://www.openstreetmap.org/copyright",
};

/**
 * "Location © OpenStreetMap contributors" for points found in our OpenStreetMap places, by
 * Nominatim or by Photon (ODbL attribution), "Powered by Geoapify" for Geoapify points, else null.
 */
export function locationCredit(provider: string | null | undefined): LocationCredit | null {
  switch (provider) {
    case "place":
    case "nominatim":
    case "photon":
      return OSM_CREDIT;
    case "geoapify":
      return { text: "Powered by Geoapify", href: "https://www.geoapify.com/" };
    default:
      return null;
  }
}

/** The line under the source block: who listed it ("Listed by the organizer" once claimed). */
export function sourceLine(label: {
  organizer_listed?: boolean | null;
  attribution?: string | null;
  source_name?: string | null;
}): string {
  if (label.organizer_listed) return "Listed by the organizer.";
  const own = label.attribution?.trim();
  if (own) return own;
  return `Listed from ${label.source_name?.trim() || "a public calendar"}.`;
}

/** An open-data dataset the collector lists events from, and the credit its licence asks for. */
export interface OpenDataCredit {
  /** The dataset id in packages/collector/data/opendata (also the feed_sources slug). */
  id: string;
  name: string;
  /** Shown word for word wherever the dataset's items appear (the source's attribution). */
  attribution: string;
  licence: { name: string; url: string };
  portal: string;
}

/**
 * The open-data datasets that are switched on, for the public /bot page. Kept in step with the
 * collector's registry (packages/collector/data/opendata/datasets.json) by a test.
 */
export const OPEN_DATA_CREDITS: readonly OpenDataCredit[] = [
  {
    id: "calgary-city-events",
    name: "City of Calgary Events",
    attribution:
      "Contains information licensed under the Open Government Licence – City of Calgary.",
    licence: {
      name: "Open Government Licence – City of Calgary",
      url: "https://www.calgary.ca/research/open-data.html",
    },
    portal: "https://data.calgary.ca/",
  },
];
