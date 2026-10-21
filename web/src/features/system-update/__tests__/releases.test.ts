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
import { afterEach, describe, expect, test, vi } from 'vitest'

import {
  compareSystemVersions,
  isSystemPrerelease,
  selectLatestRelease,
} from '../releases'

async function loadWithRepositoryEnv(value: string | undefined) {
  vi.stubEnv('VITE_UPDATE_REPOSITORY', value)
  vi.resetModules()
  const [releases, api] = await Promise.all([
    import('../releases'),
    import('../api'),
  ])
  return { releases, api }
}

afterEach(() => {
  vi.unstubAllEnvs()
  vi.unstubAllGlobals()
  vi.resetModules()
})

describe('release repository', () => {
  test.each([
    [undefined, 'QuantumNous/new-api'],
    ['', 'QuantumNous/new-api'],
    ['  Simooonn/new-api  ', 'Simooonn/new-api'],
  ])(
    'with VITE_UPDATE_REPOSITORY=%j checks and links releases of %s',
    async (value, repository) => {
      const fetchMock = vi.fn<typeof fetch>(
        async () =>
          new Response('[]', {
            headers: { 'Content-Type': 'application/json' },
          })
      )
      vi.stubGlobal('fetch', fetchMock)
      const { releases, api } = await loadWithRepositoryEnv(value)

      await api.fetchLatestSystemRelease(new AbortController().signal)

      expect(String(fetchMock.mock.calls[0][0])).toBe(
        `https://api.github.com/repos/${repository}/releases?per_page=100`
      )
      expect(
        releases.getSystemReleaseUrl({
          tag_name: 'v1.0.0-rc.44-ace.1',
          prerelease: false,
        })
      ).toBe(`https://github.com/${repository}/releases/tag/v1.0.0-rc.44-ace.1`)
    }
  )
})

describe('system release ordering', () => {
  test.each([
    ['v0.13.2', 'v1.0.0-alpha.1', -1],
    ['v1.0.0-alpha.2', 'v1.0.0-beta.1', -1],
    ['v1.0.0-beta.1', 'v1.0.0-rc.1', -1],
    ['v1.0.0-rc.9', 'v1.0.0-rc.10', -1],
    ['v1.0.0-rc.19', 'v1.0.0-rc.19-i18nfix.1', -1],
    ['v1.0.0-rc.19-i18nfix.2', 'v1.0.0-rc.20', -1],
    ['v1.0.0-rc.36', 'v1.0.0', -1],
    ['v0.13.1', 'v0.13.1-patch.1', -1],
    ['v0.13.1-patch.9', 'v0.13.1-patch.10', -1],
    ['v0.13.1-patch.10', 'v0.13.2', -1],
    ['v0.8.8.3.2', 'v0.8.8.3.3', -1],
    ['v0.9.3.0', 'v0.9.3', 0],
    ['v1.0.0+build.1', '1.0.0+build.2', 0],
    ['v1.0.0-rc.37', 'v1.0.0-rc.36', 1],
    ['v1.0.0', 'v1.0.0', 0],
    ['v0.0.0', 'v1.0.0', null],
    ['dev', 'v1.0.0', null],
    ['', 'v1.0.0', null],
    ['v1.0.0-custom.1', 'v1.0.0', null],
    ['v1.0.0-rc.36-2-gabcdef', 'v1.0.0', null],
    ['v1.0.0-rc.44', 'v1.0.0-rc.44-ace.1', -1],
    ['v1.0.0-rc.44-ace.1', 'v1.0.0-rc.44-ace.2', -1],
    ['v1.0.0-rc.44-ace.9', 'v1.0.0-rc.44-ace.10', -1],
    ['v1.0.0-rc.44-ace.2', 'v1.0.0-rc.45', -1],
    ['v1.0.0-rc.45', 'v1.0.0-rc.45-ace.1', -1],
    ['v1.0.0', 'v1.0.0-ace.1', -1],
    ['v1.0.0-ace.3', 'v1.0.1', -1],
    ['v1.0.0-rc.19-i18nfix.1-ace.1', 'v1.0.0-rc.19-i18nfix.2', -1],
    ['v0.13.1-patch.1-ace.1', 'v0.13.1-patch.2', -1],
    ['v1.0.0-rc.44-ace.2', 'v1.0.0-rc.44-ace.1', 1],
    ['v1.0.0-rc.44-ace.1', 'v1.0.0-rc.44-ace.1+build.7', 0],
    ['v1.0.0-rc.44-ace.0', 'v1.0.0-rc.44', null],
    ['v1.0.0-rc.44-ace', 'v1.0.0-rc.44', null],
    ['v1.0.0-ace.1-rc.44', 'v1.0.0', null],
  ])('compares %s against %s as %s', (current, latest, expected) => {
    expect(compareSystemVersions(current, latest)).toBe(expected)
  })

  test('selects the highest published version including pre-releases, regardless of order', () => {
    const releases = [
      { tag_name: 'v1.0.0-rc.19-i18nfix.2', draft: false, prerelease: true },
      { tag_name: 'v0.13.2', draft: false, prerelease: false },
      { tag_name: 'v2.0.0', draft: true, prerelease: false },
      { tag_name: 'v1.0.0-rc.36', draft: false, prerelease: true },
      { tag_name: 'nightly', draft: false, prerelease: true },
    ]
    expect(selectLatestRelease(releases)?.tag_name).toBe('v1.0.0-rc.36')
  })

  test('selects the newest fork build when fork tags extend the same upstream release', () => {
    const releases = [
      { tag_name: 'v1.0.0-rc.44-ace.1', draft: false, prerelease: false },
      { tag_name: 'v1.0.0-rc.44-ace.2', draft: false, prerelease: false },
      { tag_name: 'v1.0.0-rc.43-ace.7', draft: false, prerelease: false },
    ]
    expect(selectLatestRelease(releases)?.tag_name).toBe('v1.0.0-rc.44-ace.2')
  })

  test('returns no release for an empty list or a list containing only drafts', () => {
    expect(selectLatestRelease([])).toBeNull()
    expect(
      selectLatestRelease([
        { tag_name: 'v2.0.0', draft: true, prerelease: false },
      ])
    ).toBeNull()
  })

  test('rejects malformed payloads instead of reporting that the system is current', () => {
    expect(() => selectLatestRelease({ message: 'bad response' })).toThrow()
    expect(() => selectLatestRelease([{ tag_name: 42 }])).toThrow()
  })
})

describe('pre-release detection', () => {
  test.each([
    ['v1.0.0-rc.44-ace.2', false, false],
    ['v1.0.0-rc.44-ace.2', true, true],
    ['v1.0.0-ace.1', false, false],
    ['v1.0.0-rc.45', false, true],
    ['v1.0.0-beta.1', false, true],
    ['v1.0.0', false, false],
    ['v0.13.1-patch.1', false, false],
    ['v1.0.0', true, true],
  ])(
    'treats %s with GitHub prerelease=%s as pre-release: %s',
    (tag, prerelease, expected) => {
      expect(isSystemPrerelease({ tag_name: tag, prerelease })).toBe(expected)
    }
  )
})
