import { describe, expect, it, vi } from 'vitest'
import { announceSessionChange, sessionAccountChanged, subscribeSessionChanges } from './sessionSync'

function fakeBus() {
  const listeners = new Set<() => void>()
  return (name: string) => {
    expect(name).toBe('mta-session-sync')
    return {
      postMessage: () => listeners.forEach((listener) => listener()),
      close: vi.fn(),
      addEventListener: (_: string, listener: () => void) => { listeners.add(listener) },
      removeEventListener: (_: string, listener: () => void) => { listeners.delete(listener) },
    } as unknown as BroadcastChannel
  }
}

describe('session sync', () => {
  it('tells other tabs and stops after unsubscribing', () => {
    const bus = fakeBus()
    const listener = vi.fn()
    const unsubscribe = subscribeSessionChanges(listener, bus)
    announceSessionChange(bus)
    expect(listener).toHaveBeenCalledTimes(1)
    unsubscribe()
    announceSessionChange(bus)
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('does nothing where BroadcastChannel is unavailable', () => {
    const listener = vi.fn()
    expect(() => announceSessionChange(null)).not.toThrow()
    subscribeSessionChanges(listener, null)()
    expect(listener).not.toHaveBeenCalled()
  })

  it('only reports a different account as a change', () => {
    expect(sessionAccountChanged('a', 'b')).toBe(true)
    expect(sessionAccountChanged('a', 'a')).toBe(false)
    expect(sessionAccountChanged(null, 'b')).toBe(false)
  })
})
