/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { Dialog } from '@/components/dialog'
import { Spinner } from '@/components/ui/spinner'

type TelegramLoginDialogProps = {
  open: boolean
  botName: string
  pending: boolean
  onOpenChange: (open: boolean) => void
  onAuthorization: (authorization: unknown) => void
}

let telegramCallbackSequence = 0

function normalizeTelegramBotName(value: string) {
  return value.trim().replace(/^@+/, '')
}

export function TelegramLoginDialog(props: TelegramLoginDialogProps) {
  const { t } = useTranslation()
  const widgetContainer = useRef<HTMLDivElement | null>(null)
  const authorizationHandler = useRef(props.onAuthorization)
  const [callbackName] = useState(
    () => `newApiTelegramLogin${++telegramCallbackSequence}`
  )
  const [widgetState, setWidgetState] = useState<
    'idle' | 'loading' | 'ready' | 'empty' | 'failed'
  >('idle')

  useEffect(() => {
    authorizationHandler.current = props.onAuthorization
  }, [props.onAuthorization])

  useEffect(() => {
    const container = widgetContainer.current
    const botName = normalizeTelegramBotName(props.botName)
    if (!props.open || !container || !botName) return

    let cancelled = false
    let emptyCheckTimer: number | undefined
    setWidgetState('loading')

    const callback = (authorization: unknown) => {
      authorizationHandler.current(authorization)
    }
    const browserWindow = window as unknown as Record<string, unknown>
    browserWindow[callbackName] = callback

    // Telegram Login Widget must mount into a visible container. A display:none
    // parent often leaves the dialog empty after the script "loads" successfully.
    const script = document.createElement('script')
    script.async = true
    script.src = 'https://telegram.org/js/telegram-widget.js?22'
    script.setAttribute('data-telegram-login', botName)
    script.setAttribute('data-size', 'large')
    script.setAttribute('data-radius', '8')
    script.setAttribute('data-onauth', `${callbackName}(user)`)
    script.setAttribute('data-request-access', 'write')

    const markReadyOrEmpty = () => {
      if (cancelled) return
      const hasWidget =
        container.querySelector('iframe') !== null ||
        container.querySelector('button') !== null ||
        container.querySelector('a') !== null
      setWidgetState(hasWidget ? 'ready' : 'empty')
    }

    const handleLoad = () => {
      if (cancelled) return
      // Widget injects the iframe asynchronously after the script load event.
      emptyCheckTimer = window.setTimeout(markReadyOrEmpty, 800)
    }
    const handleError = () => {
      if (!cancelled) setWidgetState('failed')
    }

    script.addEventListener('load', handleLoad)
    script.addEventListener('error', handleError)
    container.replaceChildren(script)

    return () => {
      cancelled = true
      if (emptyCheckTimer !== undefined) window.clearTimeout(emptyCheckTimer)
      script.removeEventListener('load', handleLoad)
      script.removeEventListener('error', handleError)
      container.replaceChildren()
      delete browserWindow[callbackName]
    }
  }, [callbackName, props.botName, props.open])

  const showSpinner = widgetState === 'loading' || props.pending
  const showHint = widgetState === 'empty' && !props.pending
  const showFailed = widgetState === 'failed' && !props.pending

  return (
    <Dialog
      open={props.open}
      onOpenChange={props.onOpenChange}
      title={t('Telegram Login Widget')}
      description={t('Continue with Telegram')}
      contentClassName='max-w-sm'
      contentHeight='auto'
      bodyClassName='space-y-4'
    >
      <div
        className='relative flex min-h-14 flex-col items-center justify-center gap-3'
        aria-busy={showSpinner}
      >
        {showSpinner && (
          <div className='absolute inset-0 z-10 flex items-center justify-center'>
            <Spinner />
          </div>
        )}
        {showFailed && (
          <p className='text-destructive text-center text-sm'>
            {t('Login failed')}
          </p>
        )}
        {showHint && (
          <p className='text-muted-foreground text-center text-sm'>
            {t(
              'Telegram button did not load. Check bot username (no @), BotFather /setdomain for this site host, then retry.'
            )}
          </p>
        )}
        {/* Keep mounted and visible so Telegram can inject the login control */}
        <div
          ref={widgetContainer}
          className={
            showSpinner || showFailed || showHint
              ? 'pointer-events-none opacity-0'
              : 'flex justify-center'
          }
        />
      </div>
    </Dialog>
  )
}
