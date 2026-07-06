/** Serializable event shape passed from server pages to client components. */
export interface FeedEvent {
  id: string;
  title: string;
  description: string;
  category: string;
  location: string;
  eventTimestamp: string;
  creatorUsername: string;
  attendeeCount: number;
  joined: boolean;
  isMine: boolean;
}
