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
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { toast } from 'sonner'

import { api } from '@/lib/api'
import { handleServerError } from '@/lib/handle-server-error'
import { ROLE } from '@/lib/roles'
import { requireServerSuccess } from '@/lib/server-error-message'
import { STATUS_QUERY_KEY } from '@/lib/status-query'
import { useAuthStore } from '@/stores/auth-store'

export type SystemUpgradePhase =
  | 'queued'
  | 'pulling'
  | 'recreating'
  | 'health_check'
  | 'rolling_back'
  | 'succeeded'
  | 'failed'

export type SystemUpgradeStatus = {
  id: string
  tag: string
  phase: SystemUpgradePhase
  message: string
  from_version: string
  updated_at: string
}

export type SystemUpgradeState = {
  enabled: boolean
  agent_online: boolean
  status: SystemUpgradeStatus | null
}

const SYSTEM_UPGRADE_QUERY_KEY = ['system-upgrade'] as const
export const SYSTEM_UPGRADE_POLL_INTERVAL = 2_000

function isUpgradeRunning(status: SystemUpgradeStatus | null): boolean {
  return Boolean(
    status && status.phase !== 'succeeded' && status.phase !== 'failed'
  )
}

async function fetchSystemUpgrade(): Promise<SystemUpgradeState> {
  const res = await api.get('/api/system/upgrade', { disableDuplicate: true })
  return requireServerSuccess(res.data).data as SystemUpgradeState
}

/**
 * Web upgrades for root users. The server hands the request to a host agent
 * and the container is replaced, so requests fail for a few seconds while the
 * new version starts; polling simply continues until the agent reports back.
 */
export function useSystemUpgrade() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const isRoot = useAuthStore(
    (state) => (state.auth.user?.role ?? 0) >= ROLE.SUPER_ADMIN
  )
  const query = useQuery({
    queryKey: SYSTEM_UPGRADE_QUERY_KEY,
    queryFn: fetchSystemUpgrade,
    enabled: isRoot,
    retry: false,
    meta: { errorToast: false },
    refetchInterval: (current) =>
      isUpgradeRunning(current.state.data?.status ?? null)
        ? SYSTEM_UPGRADE_POLL_INTERVAL
        : false,
  })
  const status = query.data?.status ?? null
  const running = isUpgradeRunning(status)

  // Only an upgrade started from this tab announces its outcome; it also
  // refreshes the running server version shown everywhere.
  const startedId = useRef<string | null>(null)
  useEffect(() => {
    if (!status || running || startedId.current !== status.id) return
    startedId.current = null
    void queryClient.invalidateQueries({ queryKey: STATUS_QUERY_KEY })
    if (status.phase === 'succeeded') {
      toast.success(t('Upgraded to {{version}}', { version: status.tag }))
    } else {
      toast.error(t('Upgrade to {{version}} failed', { version: status.tag }))
    }
  }, [queryClient, running, status, t])

  const mutation = useMutation({
    mutationFn: async (tag: string) => {
      const res = await api.post('/api/system/upgrade', { tag })
      return requireServerSuccess(res.data).data as SystemUpgradeStatus
    },
    onSuccess: (queued) => {
      startedId.current = queued.id
      queryClient.setQueryData<SystemUpgradeState>(
        SYSTEM_UPGRADE_QUERY_KEY,
        (previous) => ({
          enabled: previous?.enabled ?? true,
          agent_online: previous?.agent_online ?? true,
          status: queued,
        })
      )
    },
    onError: (error: Error) => {
      handleServerError(error, t('Failed to start the upgrade'))
    },
  })

  return {
    available: Boolean(
      isRoot && query.data?.enabled && query.data.agent_online
    ),
    status,
    running: running || mutation.isPending,
    start: (tag: string) => mutation.mutateAsync(tag),
  }
}
