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
import {
  focusManager,
  onlineManager,
  QueryClientProvider,
  type QueryClient,
} from '@tanstack/react-query'
import {
  cleanup,
  render,
  screen,
  waitFor,
  within,
} from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import i18n from 'i18next'
import type { ReactNode } from 'react'
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'

import { api } from '@/lib/api'
import { createAppQueryClient } from '@/lib/query-client'
import { ROLE } from '@/lib/roles'
import { STATUS_QUERY_KEY } from '@/lib/status-query'
import { useAuthStore } from '@/stores/auth-store'

import { useSystemUpdatePreferencesStore, useSystemUpdateStore } from '../store'
import { SystemUpdateAction } from '../system-update-action'
import {
  SYSTEM_UPGRADE_POLL_INTERVAL,
  type SystemUpgradeState,
  type SystemUpgradeStatus,
} from '../use-system-upgrade'

const LATEST = 'v1.0.0-rc.44-ace.3'
const fetchMock = vi.fn<typeof fetch>()
let client: QueryClient
let serverVersion: string
let upgradeState: SystemUpgradeState | Error

function Wrapper(props: { children: ReactNode }) {
  return (
    <QueryClientProvider client={client}>{props.children}</QueryClientProvider>
  )
}

function upgradeStatus(
  phase: SystemUpgradeStatus['phase'],
  message = ''
): SystemUpgradeStatus {
  return {
    id: 'req-1',
    tag: LATEST,
    phase,
    message,
    from_version: 'v1.0.0-rc.44-ace.2',
    updated_at: '2026-10-22T10:00:00Z',
  }
}

async function openDialog() {
  const user = userEvent.setup()
  render(<SystemUpdateAction compact={false} />, { wrapper: Wrapper })
  await waitFor(() => expect(fetchMock).toHaveBeenCalled())
  await user.click(
    await screen.findByRole('button', {
      name: `New version available: ${LATEST}`,
    })
  )
  const dialog = await screen.findByRole('dialog', { name: 'System updates' })
  return { user, dialog }
}

beforeEach(() => {
  localStorage.clear()
  useSystemUpdateStore.setState({ snapshot: null })
  useSystemUpdatePreferencesStore.setState({ ignoredVersionsByUserId: {} })
  useAuthStore
    .getState()
    .auth.setUser({ id: 1, username: 'root', role: ROLE.SUPER_ADMIN })
  focusManager.setFocused(true)
  onlineManager.setOnline(true)
  fetchMock.mockReset()
  fetchMock.mockImplementation(
    async () =>
      new Response(
        JSON.stringify([
          { tag_name: LATEST, draft: false, prerelease: false, body: '' },
        ]),
        { headers: { 'Content-Type': 'application/json' } }
      )
  )
  vi.stubGlobal('fetch', fetchMock)
  client = createAppQueryClient()
  serverVersion = 'v1.0.0-rc.44-ace.2'
  upgradeState = { enabled: true, agent_online: true, status: null }
  client.setQueryData(STATUS_QUERY_KEY, { version: serverVersion })
  vi.spyOn(api, 'get').mockImplementation(async (url: string) => {
    if (url === '/api/system/upgrade') {
      if (upgradeState instanceof Error) throw upgradeState
      return { data: { success: true, data: upgradeState } }
    }
    return { data: { success: true, data: { version: serverVersion } } }
  })
  vi.spyOn(api, 'post').mockImplementation(async () => {
    const queued = upgradeStatus('queued')
    upgradeState = { enabled: true, agent_online: true, status: queued }
    return { data: { success: true, data: queued } }
  })
})

afterEach(() => {
  cleanup()
  client.clear()
  useSystemUpdateStore.setState({ snapshot: null })
  useSystemUpdatePreferencesStore.setState({ ignoredVersionsByUserId: {} })
  useAuthStore.getState().auth.reset()
  localStorage.clear()
  focusManager.setFocused(undefined)
  onlineManager.setOnline(true)
  vi.useRealTimers()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('web upgrade', () => {
  test.each([
    [
      'the agent is offline',
      { enabled: true, agent_online: false, status: null },
      ROLE.SUPER_ADMIN,
    ],
    [
      'web upgrades are disabled',
      { enabled: false, agent_online: false, status: null },
      ROLE.SUPER_ADMIN,
    ],
    [
      'the user is only an administrator',
      { enabled: true, agent_online: true, status: null },
      ROLE.ADMIN,
    ],
  ])('hides the upgrade button when %s', async (_reason, state, role) => {
    upgradeState = state
    useAuthStore.getState().auth.setUser({ id: 1, username: 'admin', role })
    const { dialog } = await openDialog()
    expect(
      within(dialog).queryByRole('button', { name: `Upgrade to ${LATEST}` })
    ).not.toBeInTheDocument()
  })

  test('hides the upgrade button when the server already runs the latest release', async () => {
    serverVersion = LATEST
    client.setQueryData(STATUS_QUERY_KEY, { version: LATEST })
    const user = userEvent.setup()
    render(<SystemUpdateAction compact={false} />, { wrapper: Wrapper })
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    await user.click(
      await screen.findByRole('button', { name: 'Check for updates' })
    )
    const dialog = await screen.findByRole('dialog', { name: 'System updates' })
    expect(
      await within(dialog).findByText('No newer version available.')
    ).toBeInTheDocument()
    expect(
      within(dialog).queryByRole('button', { name: /^Upgrade to/ })
    ).not.toBeInTheDocument()
  })

  test('sends nothing when the confirmation is cancelled', async () => {
    const { user, dialog } = await openDialog()
    await user.click(
      await within(dialog).findByRole('button', {
        name: `Upgrade to ${LATEST}`,
      })
    )
    const confirm = await screen.findByRole('alertdialog')
    await user.click(within(confirm).getByRole('button', { name: 'Cancel' }))
    await waitFor(() =>
      expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()
    )
    expect(api.post).not.toHaveBeenCalled()
  })

  test('requests the latest release after confirmation and shows its progress', async () => {
    const { user, dialog } = await openDialog()
    await user.click(
      await within(dialog).findByRole('button', {
        name: `Upgrade to ${LATEST}`,
      })
    )
    const confirm = await screen.findByRole('alertdialog')
    expect(
      within(confirm).getByText(
        /switches back to v1\.0\.0-rc\.44-ace\.2 automatically/
      )
    ).toBeInTheDocument()
    await user.click(within(confirm).getByRole('button', { name: 'Upgrade' }))

    expect(api.post).toHaveBeenCalledWith('/api/system/upgrade', {
      tag: LATEST,
    })
    expect(
      await within(dialog).findByText(`Upgrading to ${LATEST}`)
    ).toBeInTheDocument()
    expect(within(dialog).getByText('Waiting for the server')).toHaveAttribute(
      'aria-current',
      'step'
    )
    expect(
      within(dialog).getByRole('button', { name: `Upgrade to ${LATEST}` })
    ).toBeDisabled()
  })

  test('keeps polling while the service restarts and reports success with the new version', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const { user, dialog } = await openDialog()
    await user.click(
      await within(dialog).findByRole('button', {
        name: `Upgrade to ${LATEST}`,
      })
    )
    await user.click(
      within(await screen.findByRole('alertdialog')).getByRole('button', {
        name: 'Upgrade',
      })
    )
    await within(dialog).findByText(`Upgrading to ${LATEST}`)
    const statusCalls = () =>
      vi
        .mocked(api.get)
        .mock.calls.filter(([url]) => url === '/api/system/upgrade').length

    // The container is being replaced: status requests fail, polling goes on.
    upgradeState = new Error('Network Error')
    const callsBeforeOutage = statusCalls()
    await vi.advanceTimersByTimeAsync(SYSTEM_UPGRADE_POLL_INTERVAL)
    await vi.advanceTimersByTimeAsync(SYSTEM_UPGRADE_POLL_INTERVAL)
    expect(statusCalls()).toBeGreaterThan(callsBeforeOutage + 1)
    expect(
      within(dialog).getByText(`Upgrading to ${LATEST}`)
    ).toBeInTheDocument()

    serverVersion = LATEST
    upgradeState = {
      enabled: true,
      agent_online: true,
      status: upgradeStatus('succeeded'),
    }
    await vi.advanceTimersByTimeAsync(SYSTEM_UPGRADE_POLL_INTERVAL)
    expect(
      await within(dialog).findByText(`Upgraded to ${LATEST}`)
    ).toBeInTheDocument()
    await waitFor(() =>
      expect(client.getQueryData(STATUS_QUERY_KEY)).toEqual({ version: LATEST })
    )
  })

  test('hides a finished result once the server runs a different version', async () => {
    serverVersion = 'v1.0.0-rc.44-ace.2'
    upgradeState = {
      enabled: true,
      agent_online: true,
      status: upgradeStatus('succeeded'),
    }
    const { dialog } = await openDialog()
    await within(dialog).findByRole('button', { name: `Upgrade to ${LATEST}` })
    expect(
      within(dialog).queryByText(`Upgraded to ${LATEST}`)
    ).not.toBeInTheDocument()
  })

  test('translates a fixed message from the upgrade agent', async () => {
    i18n.addResource(
      'zh',
      'translation',
      'pull failed; nothing was changed',
      '拉取镜像失败，未做任何改动'
    )
    await i18n.changeLanguage('zh')
    upgradeState = {
      enabled: true,
      agent_online: true,
      status: upgradeStatus('failed', 'pull failed; nothing was changed'),
    }
    try {
      const { dialog } = await openDialog()
      expect(
        await within(dialog).findByText('拉取镜像失败，未做任何改动')
      ).toBeInTheDocument()
    } finally {
      await i18n.changeLanguage('en')
    }
  })

  test('shows the failure reason and the version that is still running', async () => {
    upgradeState = {
      enabled: true,
      agent_online: true,
      status: upgradeStatus(
        'failed',
        'upgrade to ghcr.io/simooonn/new-api:v1.0.0-rc.44-ace.3 failed and was rolled back'
      ),
    }
    const { dialog } = await openDialog()
    expect(
      await within(dialog).findByText(`Upgrade to ${LATEST} failed`)
    ).toBeInTheDocument()
    expect(
      within(dialog).getByText(
        'upgrade to ghcr.io/simooonn/new-api:v1.0.0-rc.44-ace.3 failed and was rolled back'
      )
    ).toBeInTheDocument()
    expect(
      within(dialog).getByText(
        'The server is still running v1.0.0-rc.44-ace.2.'
      )
    ).toBeInTheDocument()
    expect(
      within(dialog).getByRole('button', { name: `Upgrade to ${LATEST}` })
    ).toBeEnabled()
  })

  test('shows a rollback in progress instead of the normal steps', async () => {
    upgradeState = {
      enabled: true,
      agent_online: true,
      status: upgradeStatus('rolling_back'),
    }
    const { dialog } = await openDialog()
    expect(
      await within(dialog).findByText('Switching back to the previous version')
    ).toHaveAttribute('aria-current', 'step')
    expect(
      within(dialog).queryByText('Waiting for the server')
    ).not.toBeInTheDocument()
  })
})
