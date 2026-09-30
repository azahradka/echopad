import type { Metadata } from "next";
import { IBM_Plex_Sans } from "next/font/google";
import { Provider } from "@/components/provider";
import { appName, tagline } from "@/lib/shared";
import "./global.css";

const plex = IBM_Plex_Sans({
  subsets: ["latin", "latin-ext"],
});

/** DOCS_SITE_URL wins; on Vercel the production domain is set automatically. */
function siteUrl() {
  if (process.env.DOCS_SITE_URL) return process.env.DOCS_SITE_URL;
  const vercelHost = process.env.VERCEL_PROJECT_PRODUCTION_URL;
  return vercelHost ? `https://${vercelHost}` : "http://localhost:3000";
}

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl()),
  title: {
    default: `${appName}: ${tagline}`,
    template: `%s · ${appName}`,
  },
  description:
    "EchoPad records calls and meetings on your Mac, tells the speakers apart and saves the transcript where you keep your notes. NVIDIA Parakeet, fully on-device. Free and open source.",
};

export default function Layout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={plex.className} suppressHydrationWarning>
      <body className="flex flex-col min-h-screen">
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
