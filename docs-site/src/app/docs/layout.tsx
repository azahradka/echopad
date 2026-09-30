import { DocsLayout } from "fumadocs-ui/layouts/notebook";
import { baseOptions } from "@/lib/layout.shared";
import { authorUrl } from "@/lib/shared";
import { source } from "@/lib/source";

export default function Layout({ children }: LayoutProps<"/docs">) {
  const base = baseOptions();
  return (
    <DocsLayout
      tree={source.getPageTree()}
      {...base}
      nav={{ ...base.nav, mode: "top" }}
      sidebar={{
        footer: (
          <p className="echo-credit text-xs text-fd-muted-foreground">
            Made by{" "}
            <a
              className="font-medium underline underline-offset-2"
              href={authorUrl}
            >
              Lucas Piera
            </a>
          </p>
        ),
      }}
    >
      {children}
    </DocsLayout>
  );
}
