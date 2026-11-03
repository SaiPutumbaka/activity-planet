import { z } from "zod";

export const emailSchema = z
  .string()
  .trim()
  .toLowerCase()
  .min(3, "Enter your email.")
  .max(254, "That email is too long.")
  .email("Enter a valid email.");

export const passwordSchema = z
  .string()
  .min(8, "Use at least 8 characters.")
  .max(72, "Use at most 72 characters.");

export const loginSchema = z.object({
  email: emailSchema,
  password: z.string().min(1, "Enter your password."),
});
export type LoginInput = z.infer<typeof loginSchema>;

export const signupSchema = z
  .object({
    email: emailSchema,
    password: passwordSchema,
    confirmPassword: z.string(),
  })
  .refine((v) => v.password === v.confirmPassword, {
    message: "Passwords don't match.",
    path: ["confirmPassword"],
  });
export type SignupInput = z.infer<typeof signupSchema>;

/**
 * Only allow redirects to same-origin relative paths: a single leading "/", never "//" or "/\",
 * no backslashes, whitespace or control characters anywhere (browsers drop tabs and newlines
 * and read "\" as "/", so "/\t/evil.example" would become "//evil.example"), and it must still
 * resolve to the same origin. Returns the normalized path, query and hash. Prevents
 * open-redirect abuse of a `next` parameter.
 */
export function safeInternalPath(value: string | null | undefined, fallback = "/"): string {
  if (!value || value.length > 2048) return fallback;
  if (!value.startsWith("/") || value.startsWith("//")) return fallback;
  // eslint-disable-next-line no-control-regex
  if (/[\\\s\u0000-\u001F\u007F]/.test(value)) return fallback;
  const base = "https://internal.invalid";
  let url: URL;
  try {
    url = new URL(value, base);
  } catch {
    return fallback;
  }
  if (url.origin !== base) return fallback;
  return `${url.pathname}${url.search}${url.hash}`;
}
