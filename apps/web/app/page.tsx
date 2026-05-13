import UploadZone from "@/components/UploadZone";

export default function Home() {
  return (
    <main className="min-h-screen flex flex-col items-center justify-center px-4 py-16">
      <h1 className="text-4xl font-bold mb-2 tracking-tight">SlowReverb</h1>
      <p className="text-zinc-400 mb-12 text-sm">
        Upload an audio file. Preview it slowed + reverbed. Export.
      </p>
      <UploadZone />
    </main>
  );
}
