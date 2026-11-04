// Browser tabs share one session cookie, so a sign-in or sign-out in one tab changes
// who every other tab is talking to. Tabs tell each other so that none keeps showing
// one account's data while its requests authenticate as another.
const channelName = 'mta-session-sync'

type ChannelFactory = (name: string) => Pick<BroadcastChannel, 'postMessage' | 'close' | 'addEventListener' | 'removeEventListener'>

function defaultFactory(): ChannelFactory | null {
  return typeof BroadcastChannel === 'undefined' ? null : (name) => new BroadcastChannel(name)
}

export function announceSessionChange(factory: ChannelFactory | null = defaultFactory()): void {
  if (!factory) return
  const channel = factory(channelName)
  channel.postMessage('changed')
  channel.close()
}

export function subscribeSessionChanges(listener: () => void, factory: ChannelFactory | null = defaultFactory()): () => void {
  if (!factory) return () => {}
  const channel = factory(channelName)
  const onMessage = () => listener()
  channel.addEventListener('message', onMessage)
  return () => {
    channel.removeEventListener('message', onMessage)
    channel.close()
  }
}

/** True when the session now belongs to someone other than the account on screen. */
export function sessionAccountChanged(loadedUserID: string | null | undefined, sessionUserID: string): boolean {
  return Boolean(loadedUserID) && loadedUserID !== sessionUserID
}
