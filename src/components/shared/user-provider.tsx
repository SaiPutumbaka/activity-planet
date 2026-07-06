"use client";

import { createContext, useContext } from "react";

export interface SessionUser {
  id: string;
  email: string;
  username: string;
  organization: string;
  selectedHobbies: string[];
}

const UserContext = createContext<SessionUser | null>(null);

/**
 * Holds the authenticated user's profile for the app shell. Populated once
 * per request by the (app) server layout — client components read it instead
 * of re-fetching.
 */
export function UserProvider({
  user,
  children,
}: Readonly<{ user: SessionUser; children: React.ReactNode }>) {
  return <UserContext.Provider value={user}>{children}</UserContext.Provider>;
}

export function useUser(): SessionUser {
  const user = useContext(UserContext);
  if (!user) {
    throw new Error("useUser must be used inside <UserProvider>.");
  }
  return user;
}
