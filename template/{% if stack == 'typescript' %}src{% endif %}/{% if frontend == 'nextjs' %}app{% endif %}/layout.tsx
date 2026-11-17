// Root layout (server component). Rendering is dynamic so every response gets its own CSP nonce (src/proxy.ts).
import type { Metadata } from "next";
import { connection } from "next/server.js";
import type { JSX, ReactNode } from "react";

export const metadata: Metadata = { title: "Exports" };

export default async function RootLayout({ children }: { readonly children: ReactNode }): Promise<JSX.Element> {
  await connection();
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
