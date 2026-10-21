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
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import { ConfirmDialog } from '@/components/confirm-dialog'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'

import type {
  SystemUpgradePhase,
  SystemUpgradeStatus,
  useSystemUpgrade,
} from './use-system-upgrade'

const RUNNING_PHASES: SystemUpgradePhase[] = [
  'queued',
  'pulling',
  'recreating',
  'health_check',
]

const PHASE_LABELS: Record<SystemUpgradePhase, string> = {
  queued: 'Waiting for the server',
  pulling: 'Downloading the new version',
  recreating: 'Restarting the service',
  health_check: 'Checking that the new version is healthy',
  rolling_back: 'Switching back to the previous version',
  succeeded: 'Upgrade finished',
  failed: 'Upgrade failed',
}

type UpgradeButtonProps = {
  upgrade: ReturnType<typeof useSystemUpgrade>
  targetVersion: string
  currentVersion?: string
}

/** Starts a web upgrade after confirmation; shown only when the server can upgrade. */
export function SystemUpgradeButton(props: UpgradeButtonProps) {
  const { t } = useTranslation()
  const [confirming, setConfirming] = useState(false)
  if (!props.upgrade.available) return null

  const confirm = async () => {
    try {
      await props.upgrade.start(props.targetVersion)
    } finally {
      setConfirming(false)
    }
  }

  return (
    <>
      <Button
        type='button'
        disabled={props.upgrade.running}
        onClick={() => setConfirming(true)}
      >
        {t('Upgrade to {{version}}', { version: props.targetVersion })}
      </Button>
      <ConfirmDialog
        open={confirming}
        onOpenChange={setConfirming}
        title={t('Upgrade to {{version}}?', { version: props.targetVersion })}
        desc={t(
          'The service restarts during the upgrade and is unavailable for a few seconds. If the new version fails its health check, the server switches back to {{current}} automatically.',
          { current: props.currentVersion || t('Unknown version') }
        )}
        confirmText={t('Upgrade')}
        isLoading={props.upgrade.running}
        handleConfirm={() => void confirm()}
      />
    </>
  )
}

/** Progress and result of the latest web upgrade. */
export function SystemUpgradeProgress(props: {
  status: SystemUpgradeStatus | null
}) {
  const { t } = useTranslation()
  const status = props.status
  if (!status) return null

  if (status.phase === 'failed') {
    return (
      <Alert variant='destructive'>
        <AlertDescription>
          <p className='font-medium'>
            {t('Upgrade to {{version}} failed', { version: status.tag })}
          </p>
          {status.message && <p>{status.message}</p>}
          {status.from_version && (
            <p>
              {t('The server is still running {{version}}.', {
                version: status.from_version,
              })}
            </p>
          )}
        </AlertDescription>
      </Alert>
    )
  }
  if (status.phase === 'succeeded') {
    return (
      <p role='status' className='text-sm'>
        {t('Upgraded to {{version}}', { version: status.tag })}
      </p>
    )
  }

  const current = RUNNING_PHASES.indexOf(status.phase)
  return (
    <div role='status' aria-live='polite' className='space-y-2 text-sm'>
      <p className='font-medium'>
        {t('Upgrading to {{version}}', { version: status.tag })}
      </p>
      <ol className='space-y-1'>
        {status.phase === 'rolling_back' ? (
          <li aria-current='step'>{t(PHASE_LABELS.rolling_back)}</li>
        ) : (
          RUNNING_PHASES.map((phase, index) => (
            <li
              key={phase}
              aria-current={index === current ? 'step' : undefined}
              className={
                index > current ? 'text-muted-foreground' : 'font-medium'
              }
            >
              {t(PHASE_LABELS[phase])}
            </li>
          ))
        )}
      </ol>
    </div>
  )
}
