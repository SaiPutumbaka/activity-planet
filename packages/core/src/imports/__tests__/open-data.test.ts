import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { OPEN_DATA_CREDITS, sourceLine } from "../index";

const registry = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("../../../../collector/data/opendata/datasets.json", import.meta.url)),
    "utf8",
  ),
) as { datasets: { id: string; name: string; attribution: string; enabled?: boolean }[] };

describe("open-data credits", () => {
  it("list every switched-on dataset with the registry's attribution, word for word", () => {
    const on = registry.datasets.filter((d) => d.enabled === true);
    expect(OPEN_DATA_CREDITS.map((c) => c.id).sort()).toEqual(on.map((d) => d.id).sort());
    for (const d of on) {
      const c = OPEN_DATA_CREDITS.find((x) => x.id === d.id)!;
      expect(c.attribution).toBe(d.attribution);
      expect(c.name).toBe(d.name);
    }
  });

  it("the event page's source line is the Calgary licence line", () => {
    expect(
      sourceLine({
        attribution:
          "Contains information licensed under the Open Government Licence – City of Calgary.",
        source_name: "City of Calgary Events",
      }),
    ).toBe("Contains information licensed under the Open Government Licence – City of Calgary.");
  });
});
