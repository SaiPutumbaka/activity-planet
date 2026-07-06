import { z } from "zod";

/**
 * Shared between the client forms (react-hook-form resolver) and the Server
 * Actions, so validation can never drift between the two layers.
 */
export const loginSchema = z.object({
  email: z.email("Enter a valid email address."),
  password: z.string().min(1, "Password is required."),
});

export const signupSchema = z
  .object({
    email: z.email("Enter a valid email address."),
    password: z
      .string()
      .min(8, "Password must be at least 8 characters.")
      .max(72, "Password must be at most 72 characters."),
    confirmPassword: z.string(),
  })
  .refine((data) => data.password === data.confirmPassword, {
    message: "Passwords do not match.",
    path: ["confirmPassword"],
  });

export type LoginInput = z.infer<typeof loginSchema>;
export type SignupInput = z.infer<typeof signupSchema>;

/**
 * Only ever redirect to a path inside this app. Blocks open redirects like
 * `?next=https://evil.com` or protocol-relative `//evil.com`.
 */
export function safeInternalPath(path: string | null | undefined): string {
  if (path && path.startsWith("/") && !path.startsWith("//")) {
    return path;
  }
  return "/home";
}
