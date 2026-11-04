// tz-lookup 6.1.25 ships no types: one function from a point to an IANA zone name.
declare module "tz-lookup" {
  export default function tzlookup(lat: number, lng: number): string;
}
