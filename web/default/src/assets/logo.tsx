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
import { type SVGProps } from 'react'

import { cn } from '@/lib/utils'

/**
 * AceHub "aperture" mark — three swirling blades around a center port.
 * Uses currentColor so it inherits text color in monochrome UI slots.
 */
export function Logo({ className, ...props }: SVGProps<SVGSVGElement>) {
  return (
    <svg
      id='acehub-logo'
      viewBox='0 0 24 24'
      xmlns='http://www.w3.org/2000/svg'
      height='24'
      width='24'
      fill='none'
      stroke='currentColor'
      strokeWidth='2.25'
      strokeLinecap='round'
      strokeLinejoin='round'
      className={cn('size-6', className)}
      {...props}
    >
      <title>AceHub</title>
      {/* blades: outer arc → inner tip, rotated 120° */}
      <path d='M12 3.5c3.8 0 5.8 6.9 3 9.7' />
      <path d='M20.4 16.75c-1.9 3.3-8.7 3.3-10.6 0' />
      <path d='M3.6 16.75c-1.9-3.3 1.4-9.7 5.2-9.7' />
      {/* center port */}
      <circle cx='12' cy='12' r='1.7' fill='currentColor' stroke='none' />
      <circle cx='12' cy='12' r='0.7' fill='none' stroke='currentColor' strokeWidth='1.2' />
    </svg>
  )
}
