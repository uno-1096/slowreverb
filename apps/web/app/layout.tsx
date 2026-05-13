import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "SlowReverb",
  description: "Slow down and reverb your audio files",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
