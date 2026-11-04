// The EU gate for automatic discovery (D-042, design 9 item F): until the attorney has read the
// EU database right (Directive 96/9/EC Art. 7), regions in the EU, the EEA and the UK get no
// automatic candidates (OSM, Wikidata) and no probes. A region's country is read offline from its
// IANA time zone: every zone used in those countries (and their outermost regions) is listed
// below. A zone under Europe/ that is not listed counts as gated (fail closed), so a renamed or
// new European zone never opens the gate by accident.

/** IANA zones used in the EU, the EEA and the UK, with their country (tzdata zone1970/zone.tab). */
const ZONE_COUNTRY: Record<string, string> = {
  "Europe/Vienna": "AT",
  "Europe/Brussels": "BE",
  "Europe/Sofia": "BG",
  "Europe/Zagreb": "HR",
  "Asia/Nicosia": "CY",
  "Asia/Famagusta": "CY",
  "Europe/Nicosia": "CY",
  "Europe/Prague": "CZ",
  "Europe/Copenhagen": "DK",
  "Europe/Tallinn": "EE",
  "Europe/Helsinki": "FI",
  "Europe/Mariehamn": "FI",
  "Europe/Paris": "FR",
  "America/Cayenne": "FR",
  "America/Guadeloupe": "FR",
  "America/Martinique": "FR",
  "America/Marigot": "FR",
  "Indian/Reunion": "FR",
  "Indian/Mayotte": "FR",
  "Europe/Berlin": "DE",
  "Europe/Busingen": "DE",
  "Europe/Athens": "GR",
  "Europe/Budapest": "HU",
  "Europe/Dublin": "IE",
  "Europe/Rome": "IT",
  "Europe/Riga": "LV",
  "Europe/Vilnius": "LT",
  "Europe/Luxembourg": "LU",
  "Europe/Malta": "MT",
  "Europe/Amsterdam": "NL",
  "Europe/Warsaw": "PL",
  "Europe/Lisbon": "PT",
  "Atlantic/Madeira": "PT",
  "Atlantic/Azores": "PT",
  "Europe/Bucharest": "RO",
  "Europe/Bratislava": "SK",
  "Europe/Ljubljana": "SI",
  "Europe/Madrid": "ES",
  "Africa/Ceuta": "ES",
  "Atlantic/Canary": "ES",
  "Europe/Stockholm": "SE",
  "Atlantic/Reykjavik": "IS",
  "Europe/Vaduz": "LI",
  "Europe/Oslo": "NO",
  "Arctic/Longyearbyen": "NO",
  "Atlantic/Jan_Mayen": "NO",
  "Europe/London": "GB",
  "Europe/Belfast": "GB",
  "Europe/Guernsey": "GB",
  "Europe/Jersey": "GB",
  "Europe/Isle_of_Man": "GB",
  "Europe/Gibraltar": "GB",
};

/**
 * European zones outside the EU, the EEA and the UK. Anything else under Europe/ that is not in
 * ZONE_COUNTRY is treated as gated.
 */
const EUROPE_OPEN: Record<string, string> = {
  "Europe/Zurich": "CH",
  "Europe/Monaco": "MC",
  "Europe/San_Marino": "SM",
  "Europe/Vatican": "VA",
  "Europe/Andorra": "AD",
  "Europe/Belgrade": "RS",
  "Europe/Sarajevo": "BA",
  "Europe/Podgorica": "ME",
  "Europe/Skopje": "MK",
  "Europe/Tirane": "AL",
  "Europe/Chisinau": "MD",
  "Europe/Kyiv": "UA",
  "Europe/Kiev": "UA",
  "Europe/Simferopol": "UA",
  "Europe/Uzhgorod": "UA",
  "Europe/Zaporozhye": "UA",
  "Europe/Minsk": "BY",
  "Europe/Istanbul": "TR",
  "Europe/Moscow": "RU",
  "Europe/Kaliningrad": "RU",
  "Europe/Samara": "RU",
  "Europe/Volgograd": "RU",
  "Europe/Saratov": "RU",
  "Europe/Ulyanovsk": "RU",
  "Europe/Astrakhan": "RU",
  "Europe/Kirov": "RU",
};

/** The country of a zone when it is one of the listed European zones, else null. */
export function zoneCountry(zone: string | null | undefined): string | null {
  if (!zone) return null;
  return ZONE_COUNTRY[zone] ?? EUROPE_OPEN[zone] ?? null;
}

/**
 * Whether automatic discovery is off for a region in this zone: its country is on the gate's
 * list, or it is an unlisted European zone, or the zone is unknown (no zone: we cannot tell, so
 * it waits until the nightly run has stored one).
 */
export function euGated(
  zone: string | null | undefined,
  gate: { enabled: boolean; countries: string[] },
): boolean {
  if (!gate.enabled) return false;
  if (!zone) return true;
  const cc = zoneCountry(zone);
  if (cc) return gate.countries.includes(cc);
  return zone.startsWith("Europe/");
}

/** Every zone this table assigns to a country, for tests. */
export function listedZones(): Record<string, string> {
  return { ...ZONE_COUNTRY, ...EUROPE_OPEN };
}
