import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import { JoinTransferFailure } from './components/JoinTransferFailure.tsx'
import { transferJoinFragmentBeforeApp } from './lib/onboarding.ts'
import { startThemeSync } from './lib/theme.ts'

startThemeSync()

// A bearer token left by the retired JWT sign-in must not linger in storage.
try { localStorage.removeItem('mta_jwt_token') } catch { /* storage can be blocked */ }

const root = createRoot(document.getElementById('root')!)

async function start() {
  const transfer = await transferJoinFragmentBeforeApp()
  if (transfer.state === 'failed') {
    root.render(<JoinTransferFailure initial={transfer} />)
    return
  }
  const { default: App } = await import('./App.tsx')
  root.render(<StrictMode><App /></StrictMode>)
}

void start()
