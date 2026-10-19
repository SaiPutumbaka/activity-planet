import { z } from "zod";

import { stripControlChars } from "@/lib/validation/sanitize";
import { HUBS } from "@/types/database";

export const hubMessageSchema = z.object({
  hub: z.enum(HUBS, "Invalid hub."),
  body: z
    .string()
    .trim()
    .min(1, "Message can't be empty.")
    .max(1000, "Message must be at most 1,000 characters.")
    .transform(stripControlChars),
});

export type HubMessageInput = z.infer<typeof hubMessageSchema>;
