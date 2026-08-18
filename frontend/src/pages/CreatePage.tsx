import { motion } from 'framer-motion';
import { ArrowRight, BookOpen, CheckCircle2, FileText, Library, Mic, Plus } from 'lucide-react';
import { Link } from 'react-router-dom';

const options = [
  {
    to: '/app/audio',
    title: 'Record or upload audio',
    description: 'Capture a voice note now or upload meetings, calls, lectures, and Zoom recordings.',
    detail: 'Transcription, speaker-ready text, summaries, and chat',
    icon: Mic,
    featured: true,
  },
  {
    to: '/app/video',
    title: 'Import a video',
    description: 'Paste a YouTube, Vimeo, or other supported video link and extract its transcript.',
    detail: 'Transcript, summary, key points, and chat',
    icon: FileText,
  },
  {
    to: '/app/pdf',
    title: 'Upload a PDF',
    description: 'Extract searchable text from a document while preserving its page structure.',
    detail: 'Page-aware text, export, and chat',
    icon: BookOpen,
  },
];

export function CreatePage() {
  return (
    <div className="mx-auto max-w-6xl space-y-8">
      <header className="max-w-3xl">
        <div className="inline-flex items-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.18em]" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-600)' }}>
          <Plus className="h-3.5 w-3.5" /> Add to your workspace
        </div>
        <h1 className="mt-4 text-3xl font-semibold tracking-tight sm:text-5xl">What are you working with?</h1>
        <p className="mt-3 max-w-2xl text-base leading-7" style={{ color: 'var(--color-text-secondary)' }}>Choose the source you have now. Media Tools handles the processing and keeps the result organized in one library.</p>
      </header>

      <section className="grid gap-4 lg:grid-cols-3" aria-label="Media source">
        {options.map((option, index) => {
          const Icon = option.icon;
          return (
            <motion.div key={option.to} initial={{ opacity: 0, y: 14 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: index * 0.06 }}>
              <Link to={option.to} className="group flex h-full min-h-64 flex-col rounded-[1.75rem] border p-6 transition duration-200 hover:-translate-y-1 hover:shadow-xl hover:shadow-black/5 sm:p-7" style={{ backgroundColor: option.featured ? 'var(--color-create-featured)' : 'var(--color-surface-elevated)', borderColor: option.featured ? 'var(--color-brand-500)' : 'var(--color-border)' }}>
                <div className="flex items-start justify-between gap-4">
                  <div className="flex h-13 w-13 items-center justify-center rounded-2xl" style={{ backgroundColor: option.featured ? 'var(--color-brand-500)' : 'var(--color-brand-50)', color: option.featured ? '#fff' : 'var(--color-brand-600)' }}><Icon className="h-6 w-6" /></div>
                  {option.featured && <span className="rounded-full px-2.5 py-1 text-xs font-semibold" style={{ backgroundColor: 'var(--color-brand-50)', color: 'var(--color-brand-600)' }}>Most flexible</span>}
                </div>
                <h2 className="mt-6 text-xl font-semibold tracking-tight">{option.title}</h2>
                <p className="mt-2 text-sm leading-6" style={{ color: 'var(--color-text-secondary)' }}>{option.description}</p>
                <div className="mt-auto flex items-end justify-between gap-4 pt-6">
                  <p className="flex items-start gap-2 text-xs leading-5" style={{ color: 'var(--color-text-muted)' }}><CheckCircle2 className="mt-0.5 h-3.5 w-3.5 shrink-0" style={{ color: 'var(--color-success)' }} />{option.detail}</p>
                  <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl transition group-hover:translate-x-1" style={{ backgroundColor: 'var(--color-surface-overlay)', color: 'var(--color-brand-600)' }}><ArrowRight className="h-4 w-4" /></span>
                </div>
              </Link>
            </motion.div>
          );
        })}
      </section>

      <section className="flex flex-col justify-between gap-4 rounded-[1.75rem] border p-5 sm:flex-row sm:items-center sm:p-6" style={{ backgroundColor: 'var(--color-surface-elevated)', borderColor: 'var(--color-border)' }}>
        <div className="flex items-start gap-4">
          <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl" style={{ backgroundColor: 'var(--color-surface-subtle)', color: 'var(--color-brand-600)' }}><Library className="h-5 w-5" /></div>
          <div><h2 className="font-semibold">Already processed something?</h2><p className="mt-1 text-sm" style={{ color: 'var(--color-text-secondary)' }}>Search, filter, organize, and reopen every result from your library.</p></div>
        </div>
        <Link to="/app/library" className="inline-flex min-h-11 shrink-0 items-center justify-center gap-2 rounded-xl border px-4 text-sm font-semibold" style={{ borderColor: 'var(--color-border)' }}>Open library <ArrowRight className="h-4 w-4" /></Link>
      </section>
    </div>
  );
}
