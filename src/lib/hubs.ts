import type { Hub } from "@/types/database";

export const HUB_EMOJI: Record<Hub, string> = {
  "College Campus Life": "🎓",
  Basketball: "🏀",
  Pickleball: "🥎",
  Anime: "🎌",
  "TV Shows": "📺",
  Movies: "🎬",
  "Ping Pong": "🏓",
  Pool: "🎱",
};

export function hubEmoji(category: string): string {
  return category in HUB_EMOJI ? HUB_EMOJI[category as Hub] : "📌";
}
