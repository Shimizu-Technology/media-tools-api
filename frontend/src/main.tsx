import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import { JoinTransferFailure } from './components/JoinTransferFailure.tsx'
import { transferJoinFragmentBeforeApp } from './lib/onboarding.ts'

const storedTheme = localStorage.getItem('mta_theme')
const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches
document.documentElement.classList.toggle('dark', storedTheme ? storedTheme === 'dark' : prefersDark)

const root = createRoot(document.getElementById('root')!)

async function start() {
  const transfer = await transferJoinFragmentBeforeApp()
  if (transfer.state === 'failed') {
    root.render(<JoinTransferFailure initial={transfer} />)
    return
  }
  loadAppFonts()
  const { default: App } = await import('./App.tsx')
  root.render(<StrictMode><App /></StrictMode>)
}

function loadAppFonts() {
  for (const href of [
    'https://api.fontshare.com/v2/css?f[]=satoshi@400,500,600,700&display=swap',
    'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap',
  ]) {
    const link = document.createElement('link')
    link.rel = 'stylesheet'
    link.href = href
    document.head.appendChild(link)
  }
}

void start()
