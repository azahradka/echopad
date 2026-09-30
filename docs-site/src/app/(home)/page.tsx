import {
  ArrowUpRight,
  AudioLines,
  Bell,
  Cpu,
  FileText,
  FolderOpen,
  Heart,
  Lock,
  Package,
  Users,
} from "lucide-react";
import Link from "next/link";
import type { ReactNode } from "react";
import { LivePill } from "@/components/live-pill";
import { Screenshot } from "@/components/screenshot";
import { asset, authorUrl, repoUrl } from "@/lib/shared";

const steps = [
  {
    icon: Bell,
    title: "Join a call",
    text: "EchoPad notices Zoom, Meet, Teams and friends using the microphone and offers to record.",
  },
  {
    icon: AudioLines,
    title: "Talk as usual",
    text: "Your microphone and the other side are recorded as two tracks. A glass pill shows the timer.",
  },
  {
    icon: FileText,
    title: "Get a transcript",
    text: "Stop, and a transcript with speakers lands in your folder, in the formats you chose.",
  },
];

const features = [
  {
    icon: Cpu,
    title: "Parakeet v3, on-device",
    text: "NVIDIA’s TDT model runs on Apple’s Neural Engine through FluidAudio. 25 European languages, fully offline after one download.",
  },
  {
    icon: Users,
    title: "Knows who said what",
    text: "Your side comes from the microphone, so it is always you. The other side is split into speakers you can rename.",
  },
  {
    icon: FolderOpen,
    title: "Saves where you work",
    text: "An Obsidian vault, a client folder, iCloud Drive. Each save location has its own folder, file name and formats.",
  },
  {
    icon: FileText,
    title: "Markdown, text, subtitles",
    text: "Markdown with front matter, plain text, SRT, WebVTT and JSON. Audio as AAC or WAV, next to the note or on its own.",
  },
  {
    icon: Bell,
    title: "Never miss a meeting",
    text: "A notification with a Record button appears when a call starts. Or press ⇧⌘E, or click the menu bar icon.",
  },
  {
    icon: Heart,
    title: "Free, for real",
    text: "No account, no subscription, no minute limit. MIT licensed, like the two Swift packages it is built on.",
  },
];

const privacyFacts = [
  "Audio is recorded only while you record, into a folder on your Mac.",
  "Transcription and speaker detection run locally on the Neural Engine.",
  "The only network requests download the models from Hugging Face, once.",
  "No analytics, no crash reporting, no account. Check the source to be sure.",
];

const packages = [
  {
    name: "ScribeKit",
    url: "https://scribekit.lucaspiera.com",
    text: "Parakeet v3 transcription with speakers in a few lines of Swift, plus Markdown, SRT, WebVTT and JSON output.",
  },
  {
    name: "SystemAudioKit",
    url: "https://systemaudiokit.lucaspiera.com",
    text: "Record the microphone and what the Mac plays, as two aligned tracks, through Core Audio process taps.",
  },
];

const comparison = [
  ["Price", "Free forever", "Monthly subscription"],
  ["Where audio is processed", "On your Mac", "Remote servers"],
  ["Bot joins the call", "No", "Often"],
  ["Where transcripts go", "Any folder you pick", "Their web app"],
  ["Source code", "Open, MIT", "Closed"],
];

export default function HomePage() {
  return (
    <main className="flex flex-col">
      <Hero />
      <div className="mx-auto w-full max-w-6xl px-6 pt-12 pb-4">
        <Screenshot
          name="conversations"
          alt="EchoPad main window with a transcript split by speaker"
          className="my-0"
        />
      </div>

      <Section eyebrow="How it works" title="From call to notes without typing">
        <ol className="divide-y border-y">
          {steps.map((step, index) => (
            <li key={step.title} className="flex gap-5 py-5">
              <span className="w-8 shrink-0 pt-0.5 font-mono text-sm text-fd-primary">
                {String(index + 1).padStart(2, "0")}
              </span>
              <div>
                <h3 className="flex items-center gap-2 font-semibold">
                  <step.icon className="size-4 text-fd-muted-foreground" />
                  {step.title}
                </h3>
                <p className="mt-1 text-fd-muted-foreground">{step.text}</p>
              </div>
            </li>
          ))}
        </ol>
      </Section>

      <Section
        eyebrow="Features"
        title="A meeting recorder that stays out of the way"
      >
        <div className="grid gap-x-10 border-b sm:grid-cols-2">
          {features.map((feature) => (
            <div key={feature.title} className="flex gap-4 border-t py-5">
              <feature.icon className="mt-0.5 size-5 shrink-0 text-fd-primary" />
              <div>
                <h3 className="font-semibold">{feature.title}</h3>
                <p className="mt-1 text-sm text-fd-muted-foreground">
                  {feature.text}
                </p>
              </div>
            </div>
          ))}
        </div>
      </Section>

      <Section
        eyebrow="A look inside"
        title="Conversations, save locations and settings in one window"
      >
        <div className="grid gap-6 md:grid-cols-2">
          <Screenshot
            name="destinations"
            alt="Save location editor with folder, file name, formats and audio options"
            caption="Save locations with a live preview of the path"
            className="my-0"
          />
          <Screenshot
            name="settings-recording"
            alt="Recording settings: microphone, system audio, meeting detection"
            caption="What to record, and when to ask"
            className="my-0"
          />
        </div>
      </Section>

      <Section eyebrow="Privacy" title="What leaves your Mac? Nothing.">
        <ul className="divide-y border-y">
          {privacyFacts.map((line) => (
            <li key={line} className="flex gap-3 py-3.5">
              <Lock className="mt-0.5 size-4 shrink-0 text-fd-primary" />
              <span>{line}</span>
            </li>
          ))}
        </ul>
        <table className="mt-10 w-full table-fixed border-y text-sm">
          <thead>
            <tr>
              <th className="w-[38%] py-3 pr-4 text-left font-medium" />
              <th className="py-3 pr-4 text-left font-semibold text-fd-primary">
                EchoPad
              </th>
              <th className="py-3 text-left font-medium text-fd-muted-foreground">
                Typical meeting note-taker
              </th>
            </tr>
          </thead>
          <tbody>
            {comparison.map(([label, ours, cloud]) => (
              <tr key={label} className="border-t">
                <td className="py-3 pr-4 text-fd-muted-foreground">{label}</td>
                <td className="py-3 pr-4 font-medium">{ours}</td>
                <td className="py-3 text-fd-muted-foreground">{cloud}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>

      <Section eyebrow="Open source" title="Two Swift packages you can use too">
        <div className="divide-y border-y">
          {packages.map((item) => (
            <a
              key={item.name}
              href={item.url}
              className="group flex gap-4 py-5"
            >
              <Package className="mt-0.5 size-5 shrink-0 text-fd-primary" />
              <div className="min-w-0 flex-1">
                <h3 className="font-semibold group-hover:text-fd-primary">
                  {item.name}
                </h3>
                <p className="mt-1 text-sm text-fd-muted-foreground">
                  {item.text}
                </p>
              </div>
              <ArrowUpRight className="mt-0.5 size-4 shrink-0 text-fd-muted-foreground group-hover:text-fd-primary" />
            </a>
          ))}
        </div>
      </Section>

      <section className="mt-8 border-y bg-fd-muted">
        <div className="mx-auto flex max-w-6xl flex-col gap-6 px-6 py-12 md:flex-row md:items-center md:justify-between">
          <div>
            <h2 className="text-2xl font-semibold tracking-tight">
              Keep every conversation
            </h2>
            <p className="mt-2 max-w-xl text-fd-muted-foreground">
              Build it from source in one command. Setup walks you through
              permissions, the model download and where to save.
            </p>
          </div>
          <CallToAction className="shrink-0" />
        </div>
      </section>

      <footer className="py-10 text-sm text-fd-muted-foreground">
        <div className="mx-auto max-w-6xl px-6">
          <p>
            Made by{" "}
            <a
              className="font-medium text-fd-foreground underline underline-offset-4"
              href={authorUrl}
            >
              Lucas Piera
            </a>
            .
          </p>
          <p className="mt-2">
            MIT licensed. Built on{" "}
            <a
              className="underline"
              href="https://github.com/FluidInference/FluidAudio"
            >
              FluidAudio
            </a>{" "}
            and NVIDIA Parakeet, through{" "}
            <Link className="underline" href="/docs/packages">
              ScribeKit and SystemAudioKit
            </Link>
            .
          </p>
        </div>
      </footer>
    </main>
  );
}

function Hero() {
  return (
    <section className="border-b">
      <div className="mx-auto grid max-w-6xl items-center gap-12 px-6 pt-16 pb-14 lg:grid-cols-[1.1fr_1fr] lg:pt-24 lg:pb-20">
        <div>
          <div className="mb-6 flex items-center gap-3">
            {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
            <img
              src={asset("/icon-256.png")}
              alt="EchoPad icon"
              width={48}
              height={48}
              className="drop-shadow-md"
            />
            <span className="text-sm font-medium text-fd-muted-foreground">
              Free · Open source · Runs on your Mac
            </span>
          </div>
          <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
            Every call, <span className="text-fd-primary">on paper.</span>
          </h1>
          <p className="mt-5 max-w-xl text-lg text-fd-muted-foreground">
            EchoPad records your calls and meetings, tells the speakers apart
            and saves the transcript where you keep your notes. No bot in the
            call, no cloud, no subscription.
          </p>
          <CallToAction className="mt-8" />
        </div>
        <div className="overflow-hidden rounded-lg border bg-fd-muted">
          <div className="flex h-8 items-center gap-1.5 border-b bg-fd-background px-3">
            <span className="size-2.5 rounded-full bg-fd-border" />
            <span className="size-2.5 rounded-full bg-fd-border" />
            <span className="size-2.5 rounded-full bg-fd-border" />
          </div>
          <div className="flex h-64 items-end justify-center px-4 pb-8 sm:h-72">
            <LivePill bars={20} />
          </div>
        </div>
      </div>
    </section>
  );
}

function CallToAction({ className }: { className?: string }) {
  return (
    <div className={`flex flex-wrap gap-3 ${className ?? ""}`}>
      <Link
        href="/docs/installation"
        className="rounded-md bg-fd-primary px-5 py-2.5 font-medium text-fd-primary-foreground transition hover:opacity-90"
      >
        Install EchoPad
      </Link>
      <a
        href={repoUrl}
        className="inline-flex items-center gap-2 rounded-md border bg-fd-background px-5 py-2.5 font-medium transition hover:bg-fd-accent"
      >
        <GitHubMark /> View on GitHub
      </a>
    </div>
  );
}

function Section({
  eyebrow,
  title,
  children,
}: {
  eyebrow: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="mx-auto grid w-full max-w-6xl gap-6 px-6 py-14 lg:grid-cols-[16rem_1fr] lg:gap-12">
      <div>
        <p className="font-mono text-xs uppercase tracking-wider text-fd-primary">
          {eyebrow}
        </p>
        <h2 className="mt-2 text-2xl font-semibold tracking-tight">{title}</h2>
      </div>
      <div className="min-w-0">{children}</div>
    </section>
  );
}

function GitHubMark() {
  return (
    <svg
      viewBox="0 0 16 16"
      className="size-4"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}
