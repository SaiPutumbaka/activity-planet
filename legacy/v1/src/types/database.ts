/**
 * Hand-authored database types matching supabase/migrations/*.sql.
 * If the schema changes, update both files together (or switch to
 * `supabase gen types typescript` once the CLI is part of the workflow).
 */

// The full interest catalog. This must stay a superset of the original 8
// hubs (backward compatibility with rows already written to the database)
// and a mirror of src/lib/hub-catalog.ts's content, one name per entry —
// verified by scripts/verify-hub-catalog.mjs.
export const HUBS = [
  // Team Sports
  "Soccer", "Basketball", "Volleyball", "Beach Volleyball", "Baseball",
  "Softball", "American Football", "Flag Football", "Rugby Union",
  "Rugby League", "Cricket", "Ice Hockey", "Field Hockey", "Handball",
  "Water Polo", "Lacrosse", "Ultimate Frisbee", "Dodgeball", "Netball",
  "Kickball", "Curling", "Kabaddi", "Sepak Takraw", "Tug Of War", "Futsal",
  "Gaelic Football", "Hurling", "Korfball", "Floorball",
  "Dragon Boat Racing", "Rowing", "Paintball", "Capture The Flag",
  "Roller Hockey", "Polo", "Bocce Ball", "Spikeball", "Airsoft",
  "Cheerleading", "Laser Tag", "Roller Derby",
  // Individual & Racquet Sports
  "Tennis", "Badminton", "Table Tennis", "Squash", "Racquetball", "Padel",
  "Pickleball", "Platform Tennis", "Golf", "Bowling", "Archery", "Fencing",
  "Darts", "Pool", "Snooker", "Disc Golf", "Gymnastics", "Skateboarding",
  "Horseback Riding", "Running", "Roller Skating", "Swimming", "Cycling",
  "Boxing", "Wrestling", "Martial Arts", "Rock Climbing", "Weightlifting",
  "Yoga", "Skiing", "Snowboarding", "Surfing", "Ice Skating", "Ping Pong",
  "Parkour", "Trampolining", "Foosball", "Air Hockey", "Beach Tennis",
  // Combat Sports & Martial Arts
  "Kickboxing", "Muay Thai", "Brazilian Jiu-Jitsu", "Judo", "Karate",
  "Taekwondo", "Mixed Martial Arts", "Krav Maga", "Aikido", "Capoeira",
  "Kung Fu", "Sambo", "Wing Chun", "Sumo", "Hapkido", "Tai Chi", "Kendo",
  "Silat", "Savate", "Sanda", "Ninjutsu", "Systema", "Catch Wrestling",
  "Luta Livre", "Kalaripayattu", "Arm Wrestling", "Eskrima",
  "Jeet Kune Do", "Bare Knuckle Boxing",
  // Running, Cycling & Endurance
  "Road Running", "Trail Running", "Marathon Running", "Ultramarathon",
  "Cross Country Running", "Sprinting", "Race Walking", "Road Cycling",
  "Mountain Biking", "Track Cycling", "Gravel Cycling", "Cyclocross",
  "BMX Racing", "Bikepacking", "Indoor Cycling", "Triathlon", "Duathlon",
  "Adventure Racing", "Obstacle Course Racing", "Orienteering",
  "Downhill Mountain Biking", "Enduro Mountain Biking",
  "Electric Mountain Biking", "BMX Freestyle", "Swimrun", "Nordic Walking",
  "Fell Running", "Skyrunning", "Tower Running", "Handcycling",
  "Randonneuring", "Snowshoe Racing",
  // Fitness, Gym & Wellness
  "Powerlifting", "Bodybuilding", "CrossFit", "Hot Yoga", "Pilates",
  "Barre", "Zumba", "Spin Class", "HIIT Training", "Calisthenics",
  "Meditation", "Aerobics", "TRX Training", "Mobility & Stretching",
  "Sauna & Spa", "Breathwork", "Kettlebell Training", "Boot Camp Training",
  "Functional Training", "Personal Training", "Massage Therapy",
  "Cold Plunge & Ice Bath", "Sound Bath", "Water Aerobics",
  // Outdoors & Adventure
  "Hiking", "Backpacking", "Camping", "Bouldering", "Mountaineering",
  "Whitewater Rafting", "Kayaking", "Fishing", "Hunting", "Birdwatching",
  "Geocaching", "Off-Roading", "Paragliding", "Skydiving",
  "Bungee Jumping", "Caving", "Zip-Lining", "Bushcraft", "Scuba Diving",
  "Snorkeling", "Stand-Up Paddleboarding", "Canoeing", "Sailing",
  "Snowshoeing", "Ice Climbing", "Canyoning", "Gardening",
  "Stargazing & Astronomy", "Beekeeping", "Dog Walking",
  // Water Sports
  "Bodyboarding", "Windsurfing", "Kitesurfing", "Free Diving",
  "Synchronized Swimming", "Water Skiing", "Wakeboarding", "Jet Skiing",
  "Underwater Hockey", "Cliff Diving", "Platform Diving", "Parasailing",
  "Flyboarding", "Wakesurfing", "Bodysurfing", "Spearfishing",
  "Kneeboarding", "Outrigger Canoeing", "Coasteering", "Water Tubing",
  "Wing Foiling",
  // Winter Sports
  "Alpine Skiing", "Cross-Country Skiing", "Ski Jumping",
  "Freestyle Skiing", "Figure Skating", "Speed Skating", "Bobsled",
  "Luge", "Skeleton", "Snowmobiling", "Biathlon", "Ice Fishing",
  "Snow Tubing", "Tobogganing", "Ice Sailing", "Dog Sledding", "Bandy",
  "Broomball", "Backcountry Skiing", "Snow Kiting", "Nordic Combined",
  "Ice Diving", "Winter Camping", "Telemark Skiing", "Ringette",
  "Ice Sculpting",
  // Golf, Precision & Target Sports
  "Mini Golf", "Crossbow Shooting", "Horseshoes", "Bocce", "Petanque",
  "Lawn Bowls", "Shuffleboard", "Skeet Shooting", "Trap Shooting",
  "Rifle Shooting", "Pistol Shooting", "Axe Throwing", "Knife Throwing",
  "Cornhole", "Kubb", "Croquet", "Carom Billiards", "Sporting Clays",
  "Ring Toss", "Ladder Toss", "Washer Toss", "Mölkky", "Boccia",
  "Skittles",
  // Tabletop, Card & Board Games
  "Chess", "Checkers", "Go", "Xiangqi", "Shogi", "Backgammon", "Mahjong",
  "Dominoes", "Reversi", "Poker", "Bridge", "Rummy", "Blackjack",
  "Solitaire", "Cribbage", "Euchre", "Hearts", "Spades", "Canasta",
  "Pinochle", "Tabletop Role-Playing Games", "Trading Card Games",
  "Trivia Games", "Jigsaw Puzzles", "Scrabble", "Monopoly", "Risk",
  "Catan", "Uno", "Yahtzee", "Ludo", "Chinese Checkers", "Carrom",
  "Whist", "Miniature Wargaming", "Bingo", "Jenga", "Pictionary",
  "Codenames",
  // Video Gaming & Esports
  "PC Gaming", "Console Gaming", "Mobile Gaming", "Esports", "FPS Gaming",
  "MOBA Gaming", "Battle Royale", "Fighting Games", "Sim Racing",
  "Sports Video Games", "RPG Gaming", "MMORPG", "Real-Time Strategy",
  "Rhythm Games", "Retro Gaming", "Speedrunning", "Game Streaming",
  "VR Gaming", "Puzzle Games", "Sandbox Gaming", "Survival Games",
  "Roguelike Games", "Platformer Games", "Horror Games", "Party Games",
  "Life Simulation Games", "Visual Novels", "Tower Defense Games",
  "Stealth Games", "Turn-Based Strategy", "Collectible Card Games",
  "LAN Parties", "Arcade Gaming", "Action-Adventure Games",
  // Arts, Crafts & Making
  "Painting", "Drawing", "Sculpting", "Pottery", "Calligraphy",
  "Knitting", "Crocheting", "Sewing", "Embroidery", "Quilting",
  "Woodworking", "Origami", "Scrapbooking", "Jewelry Making",
  "Candle Making", "Soap Making", "Photography", "Glassblowing",
  "Leatherworking", "Macrame", "Weaving", "Beading", "Blacksmithing",
  "Stained Glass", "Cross-Stitch", "Bookbinding", "Mosaic Art",
  "Printmaking", "Basket Weaving", "Resin Art", "Felting", "Metalworking",
  "Card Making", "Digital Art", "Tie-Dye", "Flower Arranging",
  "Filmmaking", "DIY & Home Improvement", "Animation",
  // Music & Performance
  "Singing", "Guitar", "Piano", "Drums", "Violin", "DJing",
  "Music Production", "Songwriting", "Choir Singing", "A Cappella",
  "Rapping", "Beatboxing", "Karaoke", "Orchestra", "Marching Band",
  "Stand-Up Comedy", "Improv Comedy", "Acting", "Musical Theater",
  "Public Speaking", "Magic Tricks", "Circus Arts", "Ukulele",
  "Saxophone", "Trumpet", "Flute", "Cello", "Bass Guitar", "Harmonica",
  "Accordion", "Music Theory", "Voice Acting", "Ventriloquism",
  "Audio Engineering", "Ballroom Dancing", "Hip Hop Dance", "Ballet",
  "Breakdancing",
  // Food & Drink
  "Cooking", "Baking", "Bread Making", "Wine Tasting", "Wine Making",
  "Beer Tasting", "Home Brewing", "Mixology", "Coffee Brewing",
  "Latte Art", "Tea Tasting", "Barbecue", "Cheese Tasting",
  "Whiskey Tasting", "Sushi Making", "Pizza Making", "Cake Decorating",
  "Chocolate Making", "Fermenting", "Foraging", "Food Photography",
  "Restaurant Hopping", "Cheese Making", "Pasta Making",
  "Ice Cream Making", "Canning & Preserving", "Charcuterie",
  "Candy Making", "Distilling", "Kombucha Brewing", "Dumpling Making",
  "Donut Making", "Honey Tasting",
  // Movies, TV & Fandom
  "Cosplay", "Anime Fandom", "Manga Reading", "K-Drama Watching",
  "Fan Fiction Writing", "Fan Art", "Movie Trivia",
  "Movie Discussion Club", "Comic Conventions", "Anime Conventions",
  "LARPing", "Prop & Costume Making", "Fan Filmmaking", "Film Podcasting",
  "Documentary Watching", "Movie Marathons", "Memorabilia Collecting",
  "Script Table Reads", "Bollywood Fandom", "TV Show Watching",
  "Sci-Fi & Fantasy Fandom", "Superhero Fandom", "Star Wars Fandom",
  "Star Trek Fandom", "Harry Potter Fandom", "Disney Fandom",
  "Webtoon Reading", "Light Novel Reading", "Screenwriting",
  "Film Festival Attending", "Film Location Tourism", "Anime",
  "TV Shows", "Movies",
  // Books, Writing & Learning
  "Book Club", "Reading", "Creative Writing", "Poetry", "Journaling",
  "Language Learning", "Blogging", "Storytelling", "Debate",
  "Book Collecting", "Crossword Puzzles", "Trivia",
  "Philosophy Discussion", "Genealogy Research", "Memoir Writing",
  "Spelling Bee", "Letter Writing", "Playwriting", "Journalism",
  "Copywriting", "Book Reviewing", "Proofreading & Editing",
  "Speed Reading", "Etymology", "History Discussion", "Zine Making",
  "Translation", "Memory Training", "Sudoku", "Podcasting",
  // Collecting, Tech & Automotive
  "Coin Collecting", "Stamp Collecting", "Vinyl Record Collecting",
  "Sneaker Collecting", "Trading Card Collecting", "Comic Book Collecting",
  "Watch Collecting", "Antique Collecting", "Model Building",
  "Rockhounding", "Metal Detecting", "Ham Radio", "Drone Flying",
  "3D Printing", "PC Building", "Robotics", "Car Restoration",
  "Car Detailing", "Drifting", "Go-Karting", "RC Car Racing",
  "Motorcycle Riding", "Drag Racing", "Overlanding", "Slot Car Racing",
  "Model Railroading", "RC Plane Flying", "Video Game Collecting",
  "Action Figure Collecting", "Sports Memorabilia Collecting",
  "Knife Collecting", "Vintage Computer Collecting",
  "Coding & Programming",
  // Social, Lifestyle & Community
  "Trivia Night", "Board Game Night", "Poker Night", "Speed Dating",
  "Language Exchange", "Potluck Dinner", "Supper Club",
  "Networking Mixer", "Debate Club", "Volunteering", "Coffee Meetup",
  "Tarot Reading", "Astrology", "Escape Room", "Murder Mystery Dinner",
  "Pub Crawl", "Comedy Night", "Paint and Sip", "Salsa Dancing",
  "Bingo Night", "Chess Club", "Tabletop RPG", "Open Mic Night",
  "Cooking Class", "Craft Beer Tasting", "Knitting Circle", "Movie Night",
  "Flea Market", "College Campus Life", "Fantasy Sports", "Silent Disco",
] as const;

export type Hub = (typeof HUBS)[number];

export function isHub(value: string): value is Hub {
  return (HUBS as readonly string[]).includes(value);
}

// These are `type` aliases, not `interface`s, on purpose: interfaces lack
// implicit index signatures, so they fail supabase-js's
// `Row extends Record<string, unknown>` constraint and every query would
// silently type as `never`.
export type ProfileRow = {
  id: string;
  email: string;
  username: string;
  full_name: string;
  organization: string;
  bio: string;
  selected_hobbies: string[];
  avatar_url: string | null;
  birthday: string | null;
  location_text: string;
  latitude: number | null;
  longitude: number | null;
  created_at: string;
};

export type EventRow = {
  id: string;
  creator_id: string;
  title: string;
  description: string;
  category: string;
  location: string;
  latitude: number | null;
  longitude: number | null;
  event_timestamp: string;
  created_at: string;
};

export type RsvpRow = {
  event_id: string;
  user_id: string;
  created_at: string;
};

export type HubMessageRow = {
  id: string;
  hub: string;
  sender_id: string;
  body: string;
  created_at: string;
};

export type Database = {
  public: {
    Tables: {
      profiles: {
        Row: ProfileRow;
        Insert: {
          id: string;
          email: string;
          username: string;
          full_name?: string;
          organization?: string;
          bio?: string;
          selected_hobbies?: string[];
          avatar_url?: string | null;
          birthday?: string | null;
          location_text?: string;
          latitude?: number | null;
          longitude?: number | null;
          created_at?: string;
        };
        Update: {
          username?: string;
          full_name?: string;
          organization?: string;
          bio?: string;
          selected_hobbies?: string[];
          avatar_url?: string | null;
          birthday?: string | null;
          location_text?: string;
          latitude?: number | null;
          longitude?: number | null;
        };
        Relationships: [];
      };
      events: {
        Row: EventRow;
        Insert: {
          id?: string;
          creator_id: string;
          title: string;
          description?: string;
          category: string;
          location: string;
          latitude?: number | null;
          longitude?: number | null;
          event_timestamp: string;
          created_at?: string;
        };
        Update: {
          title?: string;
          description?: string;
          category?: string;
          location?: string;
          latitude?: number | null;
          longitude?: number | null;
          event_timestamp?: string;
        };
        Relationships: [
          {
            foreignKeyName: "events_creator_id_fkey";
            columns: ["creator_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      rsvps: {
        Row: RsvpRow;
        Insert: {
          event_id: string;
          user_id: string;
          created_at?: string;
        };
        // RLS has no update policy for rsvps; kept as an object type because
        // supabase-js requires it structurally.
        Update: {
          event_id?: string;
          user_id?: string;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "rsvps_event_id_fkey";
            columns: ["event_id"];
            isOneToOne: false;
            referencedRelation: "events";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "rsvps_user_id_fkey";
            columns: ["user_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
      hub_messages: {
        Row: HubMessageRow;
        Insert: {
          id?: string;
          hub: string;
          sender_id: string;
          body: string;
          created_at?: string;
        };
        // No update policy: messages are permanent once posted.
        Update: {
          hub?: string;
          sender_id?: string;
          body?: string;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "hub_messages_sender_id_fkey";
            columns: ["sender_id"];
            isOneToOne: false;
            referencedRelation: "profiles";
            referencedColumns: ["id"];
          },
        ];
      };
    };
    Views: Record<string, never>;
    Functions: Record<string, never>;
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
};
